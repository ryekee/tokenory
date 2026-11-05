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
    var body: some Scene {
        MenuBarExtra("Tokenory", systemImage: "chart.bar.xaxis") { MenuBarView().environment(store) }.menuBarExtraStyle(.window)
        Window("Tokenory", id: "dashboard") { DashboardView().environment(store) }.defaultSize(width: 1060, height: 740).defaultLaunchBehavior(ProcessInfo.processInfo.arguments.contains("--show-dashboard") ? .presented : .suppressed).commands { DashboardCommands() }
        Settings { SettingsView().environment(store) }
    }
}

private struct DashboardCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("查看统计") { openWindow(id: "dashboard"); NSApp.activate(ignoringOtherApps: true) }.keyboardShortcut("o")
        }
    }
}
