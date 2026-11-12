import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model?.busy == true else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "备份仍在进行"
        alert.informativeText = "请先在窗口中停止任务，等待当前操作结束后再退出。"
        alert.addButton(withTitle: "返回备份")
        alert.runModal()
        return .terminateCancel
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
@main
struct ActionVaultApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup("ActionVault · 相机备份") {
            ContentView(model: model)
                .onAppear { delegate.model = model; NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true) }
        }
        .defaultSize(width: 980, height: 740)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("备份") {
                Button("刷新设备") { model.refresh() }.keyboardShortcut("r").disabled(model.busy)
                Button("打开备份位置") { model.showBackup() }.disabled(model.destination == nil)
            }
        }
    }
}
