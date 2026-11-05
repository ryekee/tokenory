import AppKit
import OSLog
import SwiftUI

struct MenuBarView: View {
    @Environment(UsageStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("今日").font(.headline); Spacer(); Text("Tokenory").font(.caption).foregroundStyle(.secondary) }
            if let report = store.today {
                SummaryView(summary: report.summary, compact: true)
                if !report.clients.isEmpty {
                    Divider()
                    ForEach(report.clients) { group in
                        HStack { Text(clientName(group.key)); Spacer(); Text(compactTokens(group.summary.tokens)).monospacedDigit().foregroundStyle(.secondary) }
                    }
                }
            } else { ProgressView("正在读取用量…").frame(maxWidth: .infinity, minHeight: 60) }
            Divider()
            HStack(spacing: 7) {
                Circle().fill(store.connected ? (store.scanning ? Color.orange : Color.green) : Color.red).frame(width: 6, height: 6)
                Text(store.statusText).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { store.connected ? store.scan() : store.start() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).disabled(store.scanning).help(store.connected ? "立即扫描" : "重试连接")
            }
            if !store.connected, let error = store.error { Text(error).font(.caption).foregroundStyle(.orange).lineLimit(3) }
            HStack {
                Button("查看统计") { Logger(subsystem: "ee.ryek.tokenory", category: "windows").info("Opening dashboard"); openWindow(id: "dashboard"); NSApp.activate(ignoringOtherApps: true) }.keyboardShortcut("o")
                Spacer()
                SettingsLink { Image(systemName: "gearshape") }.help("设置")
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }.help("退出 Tokenory")
            }.buttonStyle(.plain)
        }.padding(20).frame(width: 340).task { await store.refreshToday() }
    }
}
