import XCTest
@testable import CameraBackupCore

final class BackupEngineTests: XCTestCase {
    var root: URL!
    var source: URL!
    var destination: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        source = root.appendingPathComponent("Camera")
        destination = root.appendingPathComponent("Backup")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("DCIM/100MEDIA"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    @discardableResult func put(_ name: String = "DJI_0001.MP4", content: String = "camera video") throws -> URL {
        let url = source.appendingPathComponent("DCIM/100MEDIA/" + name)
        try Data(content.utf8).write(to: url)
        return url
    }
    func backup(delete: Bool = false) throws -> BackupReport {
        try BackupEngine.run(source: source, destination: destination, deleteOriginals: delete) { _ in }
    }
    func testCopyAndRepeatUsesVerifiedBackup() throws {
        let original = try put()
        let first = try backup()
        XCTAssertEqual(first.entries.count, 1)
        XCTAssertFalse(first.entries[0].reused)
        XCTAssertEqual(try Data(contentsOf: original), try Data(contentsOf: destination.appendingPathComponent(first.entries[0].destination)))
        let second = try backup()
        XCTAssertTrue(second.entries[0].reused)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    }
    func testReusedFilenamePreservesBothVersions() throws {
        try put(content: "first")
        let first = try backup()
        try put(content: "second")
        let second = try backup()
        XCTAssertNotEqual(first.entries[0].destination, second.entries[0].destination)
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent(first.entries[0].destination)), "first")
    }
    func testVerifiedDeleteAndJournal() throws {
        let original = try put()
        let result = try backup(delete: true)
        XCTAssertEqual(result.status, "completed")
        XCTAssertTrue(result.entries[0].deleted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent(result.entries[0].destination).path))
        let journal = destination.appendingPathComponent("ActionVault/Reports/\(result.id.uuidString).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path))
    }
    func testCorruptBackupPreventsAllDeletion() throws {
        let a = try put("A.MP4")
        let b = try put("B.MP4")
        let first = try backup()
        try Data("corruption".utf8).write(to: destination.appendingPathComponent(first.entries[1].destination))
        XCTAssertThrowsError(try backup(delete: true))
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.path))
    }
    func testRejectsNestedDestination() throws {
        try put()
        XCTAssertThrowsError(try BackupEngine.run(source: source, destination: source.appendingPathComponent("Backup"), deleteOriginals: true) { _ in })
    }
    func testSkipsSourceSymlinks() throws {
        try put()
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("DCIM/secret"), withDestinationURL: destination)
        XCTAssertEqual(try BackupEngine.mediaFiles(at: source).count, 1)
    }
    func testRejectsDestinationSymlinkEscape() throws {
        let original = try put()
        let outside = root.appendingPathComponent("Outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: destination.appendingPathComponent("ActionVault"), withDestinationURL: outside)
        XCTAssertThrowsError(try backup(delete: true))
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    }
    func testSourceChangedBeforeCleanupIsRetained() throws {
        let original = try put()
        XCTAssertThrowsError(try BackupEngine.run(source: source, destination: destination, deleteOriginals: true) { progress in
            if progress.phase == "复核并清理原文件" { try? Data("changed".utf8).write(to: original) }
        })
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    }
    func testCancellationRetainsSource() async throws {
        let original = try put()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try self.backup(delete: true)
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("\(error)") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    }
}
