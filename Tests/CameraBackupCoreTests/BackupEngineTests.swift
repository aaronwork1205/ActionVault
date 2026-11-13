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
    func testLocalHistoryPersistsTransferAndReuse() throws {
        try put(content: "12345678")
        let logs = root.appendingPathComponent("Logs")
        let first = try BackupEngine.run(source: source, destination: destination, deleteOriginals: false,
                                         localLogDirectory: logs) { _ in }
        XCTAssertEqual(first.transferredBytes, 8)
        XCTAssertEqual(first.totalBytes, 8)
        XCTAssertEqual(first.completion, 1)
        XCTAssertNotNil(first.entries.first?.completedAt)
        XCTAssertEqual(first.events?.last?.phase, "completed")
        let second = try BackupEngine.run(source: source, destination: destination, deleteOriginals: false,
                                          localLogDirectory: logs) { _ in }
        XCTAssertEqual(second.transferredBytes, 0)
        XCTAssertEqual(second.verifiedBytes, 8)
        try FileManager.default.removeItem(at: destination)
        let loaded = try BackupHistory.load(from: logs)
        XCTAssertEqual(loaded.count, 2)
        XCTAssertTrue(loaded.allSatisfy { $0.finished != nil })
    }
    func testEarlyFailureIsLogged() throws {
        let logs = root.appendingPathComponent("Logs")
        XCTAssertThrowsError(try BackupEngine.run(source: source, destination: source, deleteOriginals: false,
                                                  localLogDirectory: logs) { _ in })
        let report = try XCTUnwrap(BackupHistory.load(from: logs).first)
        XCTAssertEqual(report.status, "failed")
        XCTAssertEqual(report.source, source.path)
        XCTAssertNotNil(report.finished)
        XCTAssertNil(report.completion)
    }
    func testPartialFailureRecordsVerifiedPercentage() throws {
        try put("A.MP4", content: "1234")
        try put("B.MP4", content: "5678")
        let first = try backup()
        try Data("bad".utf8).write(to: destination.appendingPathComponent(first.entries[1].destination))
        let logs = root.appendingPathComponent("Logs")
        XCTAssertThrowsError(try BackupEngine.run(source: source, destination: destination, deleteOriginals: false,
                                                  localLogDirectory: logs) { _ in })
        let report = try XCTUnwrap(BackupHistory.load(from: logs).first)
        XCTAssertEqual(report.status, "failed")
        XCTAssertEqual(report.completion, 0.5)
        XCTAssertEqual(report.entries.map(\.source), ["DCIM/100MEDIA/A.MP4"])
        XCTAssertEqual(report.transferredBytes, 0)
    }
    func testInterruptedHistoryAndLegacyDecoding() throws {
        try put()
        var report = try backup()
        report.status = "copying"; report.finished = nil
        let logs = root.appendingPathComponent("Logs")
        try BackupHistory.save(report, to: logs)
        let recovered = try XCTUnwrap(BackupHistory.load(from: logs, recoverInterrupted: true).first)
        XCTAssertEqual(recovered.status, "interrupted")
        XCTAssertNil(recovered.finished)
        let url = logs.appendingPathComponent(report.id.uuidString + ".json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        for key in ["events", "totalFiles", "totalBytes", "transferredBytes"] { json.removeValue(forKey: key) }
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        let legacy = try XCTUnwrap(BackupHistory.load(from: logs).first)
        XCTAssertNil(legacy.totalFiles)
        XCTAssertEqual(legacy.entries.count, 1)
    }

    func testCancellationPersistsPartialHistory() async throws {
        try put("A.MP4", content: "1234")
        try put("B.MP4", content: "5678")
        let logs = root.appendingPathComponent("Logs")
        let task = Task {
            try BackupEngine.run(source: self.source, destination: self.destination, deleteOriginals: false,
                                 localLogDirectory: logs) { update in
                if update.phase == "已验证" { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("\(error)") }
        let report = try XCTUnwrap(BackupHistory.load(from: logs).first)
        XCTAssertEqual(report.status, "cancelled")
        XCTAssertEqual(report.completion, 0.5)
        XCTAssertEqual(report.transferredBytes, 4)
        XCTAssertNotNil(report.finished)
    }

}
