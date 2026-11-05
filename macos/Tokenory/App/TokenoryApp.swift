import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment["TOKENORY_TESTING"] != "1" else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(workspaceOpened(_:)), name: NSWindow.didBecomeMainNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(workspaceClosed(_:)), name: NSWindow.willCloseNotification, object: nil)
        UsageStore.shared.start()
    }
    @objc private func workspaceOpened(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window.canBecomeMain, !(window is NSPanel) else { return }
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    @objc private func workspaceClosed(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing.canBecomeMain, !(closing is NSPanel) else { return }
        let anotherWorkspace = NSApp.windows.contains {
            $0 !== closing && !($0 is NSPanel) && $0.canBecomeMain && ($0.isVisible || $0.isMiniaturized)
        }
        if !anotherWorkspace { NSApp.setActivationPolicy(.accessory) }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let window = sender.windows.first(where: { $0.identifier?.rawValue == "dashboard" }) {
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
        }
        return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { await UsageStore.shared.engine.stop(); NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
@main
struct TokenoryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = UsageStore.shared
    @AppStorage("appLanguage") private var language = AppLanguage.system.rawValue
    var body: some Scene {
        MenuBarExtra { MenuBarView().environment(store).environment(\.locale, Localization.locale).focusEffectDisabled().id(language) } label: { Image("MenuBarIcon").accessibilityLabel("Tokenory") }.menuBarExtraStyle(.window)
        Window("Tokenory", id: "dashboard") { DashboardView().environment(store).environment(\.locale, Localization.locale).environment(\.timeZone, TimeZone(identifier: "Asia/Shanghai")!).focusEffectDisabled().id(language) }.defaultSize(width: 1060, height: 740).defaultLaunchBehavior(ProcessInfo.processInfo.arguments.contains("--show-dashboard") ? .presented : .suppressed).commands { DashboardCommands() }
        Settings { SettingsView().environment(store).environment(\.locale, Localization.locale).focusEffectDisabled() }.windowResizability(.contentSize)
    }
}

private struct DashboardCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button(L("action.open_stats")) { openWindow(id: "dashboard"); NSApp.activate(ignoringOtherApps: true) }.keyboardShortcut("o")
        }
    }
}
