import SwiftUI
import CameraBackupCore

struct HistoryView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selected: UUID?
    @State private var query = ""
    private var report: BackupReport? {
        model.history.first { $0.id == selected } ?? model.history.first
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("备份记录").font(.title2.bold())
                Spacer()
                Button("日志文件夹") { model.openHistoryFolder() }
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()
            if let error = model.historyError { Text(error).foregroundStyle(.orange).padding() }
            if model.history.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "clock.arrow.circlepath").font(.largeTitle)
                    Text("暂无备份记录").font(.headline)
                }.foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    List(selection: $selected) {
                        ForEach(model.history) { item in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(URL(fileURLWithPath: item.source).lastPathComponent).font(.headline).lineLimit(1)
                                    Spacer()
                                    Text(status(item.status)).font(.caption).foregroundStyle(tint(item.status))
                                }
                                Text(item.started.formatted(date: .abbreviated, time: .standard)).font(.caption).foregroundStyle(.secondary)
                                Text("\(percent(item)) · \(bytes(item.verifiedBytes)) 已验证")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 6).tag(item.id)
                        }
                    }.frame(width: 255)
                    Divider()
                    if let report {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 20) {
                                HStack {
                                    Text(status(report.status)).font(.title2.bold()).foregroundStyle(tint(report.status))
                                    Spacer()
                                    Text(percent(report)).font(.title2.monospacedDigit())
                                }
                                ProgressView(value: report.completion ?? 0).tint(tint(report.status))
                                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 12) {
                                    row("来源", report.source)
                                    row("目标", report.destination)
                                    row("开始", report.started.formatted(date: .numeric, time: .standard))
                                    row(report.status == "completed" ? "完成" : "结束", report.finished?.formatted(date: .numeric, time: .standard) ?? "—")
                                    row("已验证", "\(report.entries.count) / \(report.totalFiles.map(String.init) ?? "—") 个文件 · \(bytes(report.verifiedBytes))")
                                    row("实际传输", report.transferredBytes.map(bytes) ?? "—")
                                    row("复用", "\(report.entries.filter(\.reused).count) 个文件")
                                }
                                if let error = report.error { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
                                Divider()
                                DisclosureGroup("已完成文件（\(report.entries.count)）") {
                                    VStack(alignment: .leading, spacing: 12) {
                                        TextField("搜索文件名", text: $query).textFieldStyle(.roundedBorder)
                                        LazyVStack(alignment: .leading, spacing: 14) {
                                            ForEach(report.entries.filter { query.isEmpty || $0.source.localizedCaseInsensitiveContains(query) }, id: \.source) { entry in
                                                VStack(alignment: .leading, spacing: 4) {
                                                    Text(entry.source).font(.callout).textSelection(.enabled)
                                                    HStack {
                                                        Text(entry.reused ? "已复用" : "已传输")
                                                        Text(bytes(entry.bytes))
                                                        if let time = entry.completedAt { Text(time.formatted(date: .omitted, time: .standard)) }
                                                        if entry.deleted { Text("原文件已删除") }
                                                    }.font(.caption).foregroundStyle(.secondary)
                                                    Text(entry.destination).font(.caption2).foregroundStyle(.tertiary).textSelection(.enabled)
                                                }
                                            }
                                        }
                                    }.padding(.top, 12)
                                }
                                DisclosureGroup("进度时间线") {
                                    LazyVStack(alignment: .leading, spacing: 10) {
                                        ForEach(Array((report.events ?? []).enumerated()), id: \.offset) { _, event in
                                            HStack {
                                                Text(event.time.formatted(date: .omitted, time: .standard))
                                                Text(status(event.phase))
                                                Spacer()
                                                Text(report.totalFiles.flatMap { $0 > 0 ? "\(Int(Double(event.completedFiles) / Double($0) * 100))%" : nil } ?? "—")
                                                Text(bytes(event.transferredBytes))
                                            }.font(.caption).monospacedDigit()
                                        }
                                    }.padding(.top, 12)
                                }
                                Text("进度按已验证文件数计算；传输量不含复用文件。")
                                    .font(.caption).foregroundStyle(.tertiary)
                            }.padding(24)
                        }.id(report.id)
                    }
                }
            }
        }.frame(width: 980, height: 650)
    }
    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }.font(.callout)
    }
    private func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
    private func percent(_ report: BackupReport) -> String { report.completion.map { "\(Int($0 * 100))%" } ?? "—" }
    private func status(_ value: String) -> String {
        ["scanning": "扫描中", "copying": "传输中", "verified": "已验证", "cleaning": "清理中", "completed": "已完成", "cancelled": "已取消", "failed": "失败", "interrupted": "已中断"][value] ?? value
    }
    private func tint(_ value: String) -> Color {
        switch value {
        case "completed": return .mint
        case "failed", "interrupted": return .orange
        case "cancelled": return .secondary
        default: return .accentColor
        }
    }
}
