import SwiftUI
import CameraBackupCore

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var confirmDelete = false
    @State private var showNetwork = false
    @State private var showHistory = false
    private let accent = Color(red: 0.19, green: 0.79, blue: 0.63)
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            ScrollView {
                VStack(alignment: .leading, spacing: 23) {
                    HStack {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("相机备份").font(.system(size: 27, weight: .semibold))
                        }
                        Spacer()
                        Label("本地运行", systemImage: "lock.shield").font(.caption).foregroundStyle(accent)
                    }
                    card {
                        sectionTitle("01", "相机", icon: "camera")
                        if model.devices.isEmpty {
                            HStack(spacing: 18) {
                                Image(systemName: "cable.connector").font(.system(size: 36)).foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("等待相机连接").font(.headline)
                                    Text("连接 USB，选择「文件传输」。")
                                }
                            }.padding(.vertical, 12)
                        } else {
                            Picker("相机存储盘", selection: $model.selected) {
                                ForEach(model.devices) { device in
                                    Text("\(device.name) · \(device.recognized ? "DJI 素材目录" : "手动 / 通用存储盘")").tag(Optional(device.id))
                                }
                            }.disabled(model.busy)
                            if let device = model.device {
                                Text(device.url.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                        HStack {
                            Button("刷新设备", systemImage: "arrow.clockwise") { model.refresh() }
                            Button("手动选择相机…") { model.chooseSource() }
                            Spacer()
                        }.disabled(model.busy)
                    }
                    card {
                        sectionTitle("02", "备份位置", icon: "externaldrive")
                        HStack(spacing: 15) {
                            Image(systemName: "folder.badge.plus").font(.system(size: 30)).foregroundStyle(accent)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(model.destination?.lastPathComponent ?? "选择备份文件夹").font(.headline)
                                Text(model.destination?.path ?? "本机 / 外置硬盘 / NAS")
                                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(3)
                            }
                            Spacer()
                            Button("选择位置…") { model.chooseDestination() }.disabled(model.busy)
                        }.padding(.vertical, 6)
                        HStack {
                            Button("连接网络存储…", systemImage: "network") { showNetwork = true }.disabled(model.busy)
                            Spacer()
                            Text("增量去重 · SHA-256 校验").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    card {
                        sectionTitle("03", "备份选项", icon: "slider.horizontal.3")
                        Toggle(isOn: $model.autoBackup) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("连接后自动备份")
                                Text("应用运行时生效，保留原文件。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }.toggleStyle(.switch).disabled(model.busy)
                        Divider().padding(.vertical, 3)
                        Toggle(isOn: $model.deleteOriginals) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("本次备份后删除原文件")
                                Text("全部校验通过后清理。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }.toggleStyle(.switch).tint(.orange).disabled(model.busy)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        if model.busy {
                            HStack {
                                Text(model.progress?.phase ?? "准备备份").font(.headline)
                                Spacer()
                                if let p = model.progress { Text("\(p.completed) / \(p.total) 个文件").font(.caption).monospacedDigit() }
                            }
                            ProgressView(value: fraction).tint(accent)
                            if let p = model.progress {
                                HStack {
                                    Text(p.file).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Text("\(bytes(p.bytes)) / \(bytes(p.totalBytes))").monospacedDigit()
                                }.font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if let error = model.error {
                            Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout).textSelection(.enabled)
                        }
                        HStack(alignment: .center, spacing: 16) {
                            Text(model.message).font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                            if model.busy {
                                Button("停止任务") { model.cancel() }
                            } else {
                                Button {
                                    if model.deleteOriginals { confirmDelete = true } else { model.start() }
                                } label: {
                                    Label("开始备份", systemImage: "arrow.down.to.line").padding(.horizontal, 12).padding(.vertical, 5)
                                }.buttonStyle(.borderedProminent).tint(accent).foregroundStyle(.black).disabled(!model.canStart)
                            }
                        }
                    }
                }.padding(30)
            }
        }
        .frame(minWidth: 900, minHeight: 700)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.dark)
        .alert("备份验证后删除原文件？", isPresented: $confirmDelete) {
            Button("取消", role: .cancel) {}
            Button("备份并清理", role: .destructive) { model.start() }
        } message: {
            Text("将备份「\(model.device?.name ?? "相机")」DCIM 中的所有非隐藏普通文件至「\(model.destination?.path ?? "")」。整批校验通过后永久删除对应原文件，不经过废纸篓。")
        }
        .sheet(isPresented: $showHistory) { HistoryView(model: model) }
        .sheet(isPresented: $showNetwork) {
            VStack(alignment: .leading, spacing: 18) {
                Text("连接网络存储").font(.title2.bold())
                Text("连接后，选择共享中的备份文件夹。")
                    .foregroundStyle(.secondary)
                TextField("smb://nas.local/Photos", text: $model.networkAddress)
                HStack {
                    Button("取消") { showNetwork = false }
                    Spacer()
                    Button("在 Finder 中连接") { model.connectNetwork(); showNetwork = false }.buttonStyle(.borderedProminent)
                }
            }.padding(26).frame(width: 430)
        }
    }
    private var fraction: Double {
        guard let p = model.progress, p.totalBytes > 0 else { return 0 }
        return min(1, Double(p.bytes) / Double(p.totalBytes))
    }
    private func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up.fill").font(.system(size: 26)).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("ActionVault").font(.headline)
                    Text("相机素材保险库").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Label("相机备份", systemImage: "arrow.down.circle.fill")
                .font(.system(size: 14, weight: .medium)).foregroundStyle(accent)
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 16) {
                Text("备份守护").font(.caption).foregroundStyle(.secondary)
                Label("原始画质保留", systemImage: "photo.stack")
                Label("完整性校验", systemImage: "checkmark.shield")
                Label("同名素材不覆盖", systemImage: "doc.on.doc")
            }.font(.caption)
            Spacer()
            Button { showHistory = true } label: { Label("备份记录", systemImage: "clock.arrow.circlepath") }
                .buttonStyle(.plain)
            Button { model.showBackup() } label: { Label("打开备份文件夹", systemImage: "folder") }
                .buttonStyle(.plain).disabled(model.destination == nil)
            Text("1.1.0 · macOS")
                .font(.caption2).foregroundStyle(.tertiary).lineSpacing(5)
        }
        .padding(22).frame(width: 205).frame(maxHeight: .infinity)
        .background(Color.black.opacity(0.18))
        .overlay(alignment: .trailing) { Divider() }
    }
    private func sectionTitle(_ number: String, _ title: String, icon: String) -> some View {
        HStack {
            Text(number).font(.caption.monospaced().bold()).foregroundStyle(accent)
            Text(title).font(.headline)
            Spacer()
            Image(systemName: icon).foregroundStyle(.secondary)
        }
    }
    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16, content: content)
            .padding(20).background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.07), lineWidth: 1))
    }
}
