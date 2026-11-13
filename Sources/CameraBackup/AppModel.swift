import AppKit
import SwiftUI
import CameraBackupCore

struct CameraDevice: Identifiable, Hashable {
    let url: URL
    let name: String
    let recognized: Bool
    var id: String { url.path }
}
@MainActor
final class AppModel: ObservableObject {
    @Published var devices: [CameraDevice] = []
    @Published var selected: String?
    @Published var destination: URL?
    @Published var deleteOriginals = false
    @Published var autoBackup: Bool { didSet { UserDefaults.standard.set(autoBackup, forKey: "autoBackup") } }
    @Published var busy = false
    @Published var progress: BackupProgress?
    @Published var message = ""
    @Published var error: String?
    @Published var lastReport: BackupReport?
    @Published var networkAddress = "smb://"
    private var job: Task<Void, Never>?
    private var watchers: [NSObjectProtocol] = []
    private var attempted: Set<String> = []
    private var manual: CameraDevice?
    private var activity: NSObjectProtocol?
    var device: CameraDevice? { devices.first { $0.id == selected } }
    var canStart: Bool { device != nil && destination != nil && !busy }
    init() {
        autoBackup = UserDefaults.standard.bool(forKey: "autoBackup")
        if let path = UserDefaults.standard.string(forKey: "destination") { destination = URL(fileURLWithPath: path) }
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            watchers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    // Allow the camera's DCIM directory to become available after mount.
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    self?.refresh()
                }
            })
        }
        refresh()
    }
    func refresh() {
        guard !busy else { return }
        let keys: Set<URLResourceKey> = [.volumeIsInternalKey, .volumeIsLocalKey, .volumeNameKey]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) ?? []
        devices = volumes.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keys), values.volumeIsInternal == false,
                  values.volumeIsLocal == true,
                  FileManager.default.fileExists(atPath: url.appendingPathComponent("DCIM").path) else { return nil }
            let name = values.volumeName ?? url.lastPathComponent
            let dcim = (try? FileManager.default.contentsOfDirectory(atPath: url.appendingPathComponent("DCIM").path)) ?? []
            let recognized = name.uppercased().contains("DJI") || name.uppercased().contains("OSMO") || dcim.contains { $0.uppercased().contains("DJI") }
            return CameraDevice(url: url, name: name, recognized: recognized)
        }.sorted { $0.name < $1.name }
        if let manual, !devices.contains(where: { $0.id == manual.id }) { devices.append(manual) }
        attempted.formIntersection(Set(devices.map(\.id)))
        if !devices.contains(where: { $0.id == selected }) { selected = devices.first?.id }
        startNextAutomatic()
    }
    private func startNextAutomatic() {
        guard autoBackup, !busy, destination != nil,
              let next = devices.first(where: { $0.recognized && !attempted.contains($0.id) }) else { return }
        selected = next.id
        start(automatic: true)
    }
    func chooseSource() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.message = "选择包含 DCIM 文件夹的相机磁盘根目录"; panel.prompt = "选择相机"
        if panel.runModal() == .OK, let url = panel.url {
            guard FileManager.default.fileExists(atPath: url.appendingPathComponent("DCIM").path) else { error = "请选择包含 DCIM 文件夹的磁盘或目录。"; return }
            manual = CameraDevice(url: url, name: url.lastPathComponent, recognized: false)
            refresh(); selected = url.path
        }
    }
    func chooseDestination() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.message = "选择本机文件夹，或已挂载的 NAS / SMB 网络共享"; panel.prompt = "设为备份位置"
        if panel.runModal() == .OK, let url = panel.url {
            destination = url
            UserDefaults.standard.set(url.path, forKey: "destination")
        }
    }
    func connectNetwork() {
        guard let url = URL(string: networkAddress), ["smb", "afp"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty == false else {
            error = "请输入有效的网络地址，例如 smb://nas.local/Photos"; return
        }
        NSWorkspace.shared.open(url)
        message = "连接后请选择备份文件夹。"
    }
    func start(automatic: Bool = false) {
        guard canStart, let device, let destination else { return }
        attempted.insert(device.id)
        let shouldDelete = !automatic && deleteOriginals
        busy = true; error = nil; lastReport = nil; progress = nil
        message = automatic ? "自动备份中" : ""
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Camera backup in progress")
        job = Task {
            let worker = Task.detached(priority: .userInitiated) {
                try BackupEngine.run(source: device.url, destination: destination, deleteOriginals: shouldDelete) { update in
                    Task { @MainActor in self.progress = update }
                }
            }
            do {
                let report = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                lastReport = report
                let copied = report.entries.filter { !$0.reused }.count
                let reused = report.entries.filter(\.reused).count
                let deleted = report.entries.filter(\.deleted).count
                message = "备份完成：新增 \(copied) 个，已存在 \(reused) 个，已清理 \(deleted) 个原文件。"
            } catch is CancellationError {
                message = "任务已停止，已完成的备份保留。若清理已开始，已删除的文件仍可从备份恢复。"
            } catch {
                self.error = error.localizedDescription
                message = "任务未完成。已完成的备份保留；详细结果请查看备份记录。"
            }
            if let activity { ProcessInfo.processInfo.endActivity(activity) }; activity = nil
            busy = false; job = nil
            startNextAutomatic()
        }
    }
    func cancel() { job?.cancel(); message = "正在停止…" }
    func showBackup() {
        guard let destination else { return }
        let root = destination.appendingPathComponent("ActionVault")
        NSWorkspace.shared.open(FileManager.default.fileExists(atPath: root.path) ? root : destination)
    }
}
