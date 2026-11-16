// [INPUT]: Today-only usage and weighted turn speed, independent of dashboard filters.
// [OUTPUT]: Compact Tokens / cost / speed summary, source usage and HUD visibility.
// [POS]: Menu bar popover; missing speed remains unavailable.
// [PROTOCOL]: Update this header on change, then check AGENTS.md
import AppKit
import OSLog
import SwiftUI

struct MenuBarView: View {
    @Environment(UsageStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @State private var hud = HUDPreferences.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text(L("range.today")).font(.headline); Spacer(); Text("Tokenory").font(.caption).foregroundStyle(.secondary) }
            if let report = store.today {
                MenuBarSummary(summary: report.summary, turns: store.todayTurns, speedError: store.todaySpeedError)
                if !report.clients.isEmpty {
                    Divider()
                    ForEach(report.clients) { group in
                        HStack { BrandLabel(name: group.key, kind: .tool, title: clientName(group.key)); Spacer(); Text(compactTokens(group.summary.tokens)).monospacedDigit().foregroundStyle(.secondary) }
                    }
                }
            } else { ProgressView(L("usage.loading")).frame(maxWidth: .infinity, minHeight: 60) }
            Divider()
            HStack(spacing: 7) {
                Circle().fill(store.connected ? (store.scanning ? Color.orange : Color.green) : Color.red).frame(width: 6, height: 6)
                Text(store.statusText).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { store.connected ? store.scan() : store.start() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).disabled(store.scanning).help(store.connected ? L("action.scan") : L("action.reconnect"))
            }
            if !store.connected, let error = store.error { Text(error).font(.caption).foregroundStyle(.orange).lineLimit(3) }
            Button { hud.enabled.toggle() } label: {
                HStack(spacing: 6) {
                    Text(L("hud.show"))
                    Image(systemName: "checkmark").opacity(hud.enabled ? 1 : 0).frame(width: 14)
                    Spacer()
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(hud.enabled ? .isSelected : [])
            HStack {
                Button(L("action.open_stats")) { Logger(subsystem: "ee.ryek.tokenory", category: "windows").info("Opening dashboard"); openWindow(id: "dashboard"); NSApp.activate(ignoringOtherApps: true) }.keyboardShortcut("o")
                Spacer()
                SettingsLink { Image(systemName: "gearshape") }.help(L("settings.title"))
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }.help(L("action.quit"))
            }.buttonStyle(.plain)
        }.padding(20).frame(width: 400).task {
            while !Task.isCancelled {
                let now = Date()
                await store.refreshToday(now: now)
                let midnight = Localization.reportingCalendar.startOfDay(for: now).addingTimeInterval(86_400)
                do { try await Task.sleep(for: .seconds(max(0, midnight.timeIntervalSinceNow))) }
                catch { return }
            }
        }
    }
}
