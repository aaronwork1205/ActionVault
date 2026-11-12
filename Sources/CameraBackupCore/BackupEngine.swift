import Foundation
import CryptoKit

public struct BackupProgress: Sendable {
    public let phase: String
    public let file: String
    public let completed: Int
    public let total: Int
    public let bytes: Int64
    public let totalBytes: Int64
}
public struct BackupEntry: Codable, Sendable {
    public let source: String
    public let destination: String
    public let sha256: String
    public let bytes: Int64
    public let reused: Bool
    public var deleted: Bool = false
}
public struct BackupReport: Codable, Sendable {
    public let id: UUID
    public let started: Date
    public var finished: Date?
    public let source: String
    public let destination: String
    public var status: String
    public var entries: [BackupEntry]
    public var error: String?
}
public enum BackupError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

public enum BackupEngine {
    private static let fm = FileManager.default
    private static func contained(_ child: URL, in parent: URL) -> Bool {
        let p = parent.standardizedFileURL.resolvingSymlinksInPath().path
        let c = child.standardizedFileURL.resolvingSymlinksInPath().path
        return c == p || c.hasPrefix(p + "/")
    }
    public static func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while true {
            try Task.checkCancellation()
            let data = try handle.read(upToCount: 4 * 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    public static func mediaFiles(at source: URL) throws -> [URL] {
        let dcim = source.appendingPathComponent("DCIM", isDirectory: true)
        guard fm.fileExists(atPath: dcim.path), contained(dcim, in: source),
              (try dcim.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else {
            throw BackupError.invalid("所选设备中没有可读取的 DCIM 文件夹。请在相机上选择「文件传输」。")
        }
        var scanError: Error?
        guard let enumerator = fm.enumerator(at: dcim, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles], errorHandler: { _, error in scanError = error; return false }) else {
            throw BackupError.invalid("无法读取相机文件列表。")
        }
        var files: [URL] = []
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if info.isSymbolicLink == true { continue }
            if info.isRegularFile == true { files.append(url.standardizedFileURL.resolvingSymlinksInPath()) }
        }
        if let scanError { throw scanError }
        return files.sorted { $0.path < $1.path }
    }
    private static func size(_ url: URL) throws -> Int64 {
        Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
    }
    private static func safeTarget(_ url: URL, root: URL) throws {
        guard contained(url, in: root) else { throw BackupError.invalid("备份路径包含指向目标文件夹之外的链接，已停止。") }
        let boundary = root.standardizedFileURL.path
        var current = url.standardizedFileURL.path
        while current != boundary {
            guard current.hasPrefix(boundary + "/") else {
                throw BackupError.invalid("备份路径不在目标文件夹内。")
            }
            if (try? URL(fileURLWithPath: current).resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw BackupError.invalid("备份路径包含符号链接，已停止：\(current)")
            }
            let parent = (current as NSString).deletingLastPathComponent
            guard parent != current else { throw BackupError.invalid("无法解析备份路径。") }
            current = parent
        }
    }
    public static func run(source: URL, destination: URL, deleteOriginals: Bool,
                           progress: @escaping @Sendable (BackupProgress) -> Void) throws -> BackupReport {
        let source = source.standardizedFileURL.resolvingSymlinksInPath()
        let destination = destination.standardizedFileURL.resolvingSymlinksInPath()
        guard !contained(destination, in: source), !contained(source, in: destination) else {
            throw BackupError.invalid("备份位置与相机目录不能互相包含。")
        }
        let sourceVolume = try source.resourceValues(forKeys: [.volumeURLKey]).volume
        let destinationVolume = try destination.resourceValues(forKeys: [.volumeURLKey]).volume
        if sourceVolume == destinationVolume && sourceVolume?.path != "/" {
            throw BackupError.invalid("备份位置不能位于相机所在的同一个磁盘。")
        }
        guard fm.fileExists(atPath: destination.path), fm.isWritableFile(atPath: destination.path) else {
            throw BackupError.invalid("备份位置不可写或已断开。请重新连接网络磁盘并选择位置。")
        }
        progress(.init(phase: "扫描文件", file: "读取 DCIM", completed: 0, total: 0, bytes: 0, totalBytes: 0))
        let files = try mediaFiles(at: source)
        guard !files.isEmpty else { throw BackupError.invalid("相机 DCIM 中没有需要备份的文件。") }
        let totalBytes = try files.reduce(Int64(0)) { try $0 + size($1) }
        let root = destination.appendingPathComponent("ActionVault", isDirectory: true)
        try safeTarget(root, root: destination)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        // Content suffixes keep reused camera filenames and different cameras from overwriting each other.
        let mediaRoot = root.appendingPathComponent("Media", isDirectory: true)
        let reports = root.appendingPathComponent("Reports", isDirectory: true)
        try safeTarget(reports, root: destination)
        try fm.createDirectory(at: reports, withIntermediateDirectories: true)
        var report = BackupReport(id: UUID(), started: Date(), source: source.path, destination: destination.path, status: "copying", entries: [])
        let reportURL = reports.appendingPathComponent("\(report.id.uuidString).json")
        func save() throws {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(report).write(to: reportURL, options: .atomic)
        }
        try save()
        var bytes: Int64 = 0
        do {
            for (index, file) in files.enumerated() {
                try Task.checkCancellation()
                guard contained(file, in: source) else { throw BackupError.invalid("相机路径发生变化，已停止。") }
                let relative = String(file.path.dropFirst(source.path.count + 1))
                progress(.init(phase: "计算指纹", file: relative, completed: index, total: files.count, bytes: bytes, totalBytes: totalBytes))
                let hash = try digest(file)
                let fileSize = try size(file)
                let directory = mediaRoot.appendingPathComponent((relative as NSString).deletingLastPathComponent)
                try safeTarget(directory, root: destination)
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
                let name = file.deletingPathExtension().lastPathComponent + "_" + hash
                let target = directory.appendingPathComponent(name).appendingPathExtension(file.pathExtension)
                try safeTarget(target, root: destination)
                let reused = fm.fileExists(atPath: target.path)
                if reused {
                    guard try digest(target) == hash else { throw BackupError.invalid("已有备份校验失败，原文件已保留：\(relative)") }
                } else {
                    let partial = directory.appendingPathComponent(".\(UUID().uuidString).partial")
                    defer { try? fm.removeItem(at: partial) }
                    guard fm.createFile(atPath: partial.path, contents: nil) else { throw BackupError.invalid("无法创建备份文件。") }
                    let input = try FileHandle(forReadingFrom: file)
                    let output = try FileHandle(forWritingTo: partial)
                    defer { try? input.close(); try? output.close() }
                    var copied: Int64 = 0
                    while true {
                        try Task.checkCancellation()
                        let data = try input.read(upToCount: 4 * 1024 * 1024) ?? Data()
                        if data.isEmpty { break }
                        try output.write(contentsOf: data)
                        copied += Int64(data.count)
                        progress(.init(phase: "复制文件", file: relative, completed: index, total: files.count, bytes: bytes + copied, totalBytes: totalBytes))
                    }
                    try output.synchronize()
                    try output.close(); try input.close()
                    progress(.init(phase: "校验备份", file: relative, completed: index, total: files.count, bytes: bytes + fileSize, totalBytes: totalBytes))
                    guard try digest(partial) == hash, try size(partial) == fileSize else {
                        throw BackupError.invalid("文件校验失败，原文件已保留：\(relative)")
                    }
                    try fm.moveItem(at: partial, to: target)
                }
                report.entries.append(.init(source: relative, destination: String(target.path.dropFirst(destination.path.count + 1)), sha256: hash, bytes: fileSize, reused: reused))
                bytes += fileSize
                try save()
                progress(.init(phase: "已验证", file: relative, completed: index + 1, total: files.count, bytes: bytes, totalBytes: totalBytes))
            }
            // No deletion is attempted unless every file has a verified, journaled backup.
            report.status = "verified"; try save()
            if deleteOriginals {
                for index in report.entries.indices {
                    try Task.checkCancellation()
                    let entry = report.entries[index]
                    let original = source.appendingPathComponent(entry.source)
                    let backup = destination.appendingPathComponent(entry.destination)
                    progress(.init(phase: "复核并清理原文件", file: entry.source, completed: index, total: files.count, bytes: bytes, totalBytes: totalBytes))
                    try safeTarget(backup, root: destination)
                    guard contained(original, in: source), try digest(original) == entry.sha256,
                          try digest(backup) == entry.sha256 else {
                        throw BackupError.invalid("清理前复核失败，已停止删除：\(entry.source)")
                    }
                    try Task.checkCancellation()
                    try fm.removeItem(at: original)
                    report.entries[index].deleted = true
                    try save()
                }
            }
            report.status = "completed"; report.finished = Date(); try save()
            return report
        } catch {
            report.status = error is CancellationError ? "cancelled" : "failed"
            report.error = error.localizedDescription; report.finished = Date()
            try? save()
            throw error
        }
    }
}
