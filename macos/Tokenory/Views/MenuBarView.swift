// [INPUT]: Today-only usage and weighted turn speed, independent of dashboard filters.
// [OUTPUT]: Compact Tokens / cost / speed menu with cached readings, inline retry, scan progress and HUD visibility.
// [POS]: Menu bar popover; missing speed remains unavailable.
// [PROTOCOL]: Update this header on change, then check AGENTS.md
import AppKit
import SwiftUI

struct MenuBarView: View {
    @Environment(UsageStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dayClock = 0
    @State private var retrying = false
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
            } else if store.todayUsageError == nil && (store.connected || store.error == nil) {
                ProgressView(L("usage.loading")).frame(maxWidth: .infinity, minHeight: 60)
            }
            if store.today == nil, let error = store.todayUsageError, store.connected {
                WorkspaceErrorMessage(
                    title: L("usage.report_failed"),
                    detail: error
                ) {
                    if retrying {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(L("action.retry")) {
                            retrying = true
                            Task { await store.refreshToday(); retrying = false }
                        }
                    }
                }
                .transition(.opacity)
            }
            Divider()
            HStack(spacing: 7) {
                Circle().fill(store.connected ? (store.scanInProgress ? Color.orange : Color.green) : Color.red).frame(width: 6, height: 6)
                    .animation(DashboardMotion.animation(DashboardMotion.state, reduceMotion: reduceMotion), value: store.connected)
                    .animation(DashboardMotion.animation(DashboardMotion.state, reduceMotion: reduceMotion), value: store.scanInProgress)
                Text(LF("menu.collection_status", store.connected && store.scanInProgress ? L("status.scanning") : store.statusText))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if store.connected && store.scanInProgress {
                    ProgressView().controlSize(.small).frame(width: 24, height: 24).accessibilityLabel(L("status.scanning"))
                } else {
                    let title = L(store.connected ? "action.scan" : "action.reconnect")
                    Button { store.connected ? store.scan() : store.start() } label: {
                        Image(systemName: "arrow.clockwise").frame(width: 24, height: 24).contentShape(Rectangle())
                    }
                    .buttonStyle(WorkspaceHoverStyle()).accessibilityLabel(title)
                }
            }
            if !store.connected, let error = store.error {
                WorkspaceErrorMessage(title: error) {}.lineLimit(3)
                    .transition(.opacity)
            }
            Button { hud.enabled.toggle() } label: {
                HStack(spacing: 6) {
                    Text(L("hud.show"))
                    Image(systemName: "checkmark").opacity(hud.enabled ? 1 : 0).frame(width: 14)
                        .animation(DashboardMotion.animation(DashboardMotion.state, reduceMotion: reduceMotion), value: hud.enabled)
                    Spacer()
                }
                .padding(.horizontal, 6).padding(.vertical, 4).contentShape(Rectangle())
            }
            .buttonStyle(WorkspaceHoverStyle())
            .padding(.horizontal, -6)
            .accessibilityAddTraits(hud.enabled ? .isSelected : [])
            HStack(spacing: 4) {
                Button { openDashboard(using: openWindow) } label: {
                    Text(L("action.open_stats")).padding(.horizontal, 6).padding(.vertical, 4).contentShape(Rectangle())
                }
                .buttonStyle(WorkspaceHoverStyle()).keyboardShortcut("o")
                .padding(.leading, -6)
                Spacer()
                SettingsLink {
                    Image(systemName: "gearshape").frame(width: 26, height: 26).contentShape(Rectangle())
                }
                .buttonStyle(WorkspaceHoverStyle()).accessibilityLabel(L("settings.title"))
                Button { NSApp.terminate(nil) } label: {
                    Image(systemName: "power").frame(width: 26, height: 26).contentShape(Rectangle())
                }
                .buttonStyle(WorkspaceHoverStyle()).accessibilityLabel(L("action.quit"))
            }
        }.padding(20).frame(width: 400)
        .animation(DashboardMotion.animation(DashboardMotion.panel, reduceMotion: reduceMotion), value: store.today == nil && store.todayUsageError != nil && store.connected)
        .animation(DashboardMotion.animation(DashboardMotion.panel, reduceMotion: reduceMotion), value: !store.connected && store.error != nil)
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in dayClock += 1 }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in dayClock += 1 }
        .task(id: dayClock) {
            while !Task.isCancelled {
                let now = Date()
                await store.refreshToday(now: now)
                let midnight = LocalUsageDay(now: now).end
                do { try await Task.sleep(for: .seconds(max(0, midnight.timeIntervalSinceNow))) }
                catch { return }
            }
        }
    }
}
