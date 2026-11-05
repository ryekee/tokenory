import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment["TOKENORY_TESTING"] != "1" else { return }
        UsageStore.shared.start()
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
        MenuBarExtra { MenuBarView().environment(store).environment(\.locale, Localization.locale).id(language) } label: { Image("MenuBarIcon").accessibilityLabel("Tokenory") }.menuBarExtraStyle(.window)
        Window("Tokenory", id: "dashboard") { DashboardView().environment(store).environment(\.locale, Localization.locale).environment(\.timeZone, TimeZone(identifier: "Asia/Shanghai")!).id(language) }.defaultSize(width: 1060, height: 740).defaultLaunchBehavior(ProcessInfo.processInfo.arguments.contains("--show-dashboard") ? .presented : .suppressed).commands { DashboardCommands() }
        Settings { SettingsView().environment(store).environment(\.locale, Localization.locale) }
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
