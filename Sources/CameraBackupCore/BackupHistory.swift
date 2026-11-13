import Foundation

public enum BackupHistory {
    public static func save(_ report: BackupReport, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: directory.appendingPathComponent(report.id.uuidString + ".json"), options: .atomic)
    }

    public static func load(from directory: URL, recoverInterrupted: Bool = false) throws -> [BackupReport] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        var reports: [BackupReport] = []
        for file in files where file.pathExtension == "json" {
            var report = try decoder.decode(BackupReport.self, from: Data(contentsOf: file))
            if recoverInterrupted && ["scanning", "copying", "verified", "cleaning"].contains(report.status) {
                report.status = "interrupted"
                report.error = "上次任务意外中断；进度为最后保存的记录。"
                // The actual stop time is unknown; do not invent a completion timestamp.
                try save(report, to: directory)
            }
            reports.append(report)
        }
        return reports.sorted { $0.started > $1.started }
    }
}
