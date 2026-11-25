// [INPUT]: Private-library state and deliberate user actions.
// [OUTPUT]: iCloud sync and storage cards with live relative status, inline errors and two-step deletion.
// [POS]: iCloud settings section.
// [PROTOCOL]: Update this header on change, then check AGENTS.md
import SwiftUI

struct DeviceSyncSettings: View {
    @Environment(UsageStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var choosingDeletionScope = false
    @State private var deletion: Scope?
    private enum Scope: Identifiable {
        case device, all
        var id: Self { self }
        var title: String { L(self == .device ? "cloud.deleteDevice" : "cloud.deleteAll") }
        var detail: String { L(self == .device ? "cloud.confirmDevice" : "cloud.confirmAll") }
    }

    var body: some View {
        let sync = store.cloud
        if !sync.availableForLedger {
            WorkspacePanel {
                Label(L("cloud.default_ledger_only"), systemImage: "icloud.slash")
                    .foregroundStyle(.secondary)
            }
        } else {
            syncControls(sync)
        }
    }

    private func syncControls(_ sync: DeviceSyncStore) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            WorkspacePanel {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Label(sync.localName, systemImage: "desktopcomputer").font(.headline)
                            Text(L("cloud.scope"))
                                .font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        SettingsSwitch(label: L("settings.cloud"), isOn: Binding(get: { sync.enabled }, set: { on in
                            Task { if on { await sync.enable() } else { await sync.stop() } }
                        })).disabled(sync.managing)
                    }
                    if sync.enabled || sync.busy || sync.managing || sync.lastContact != nil {
                        HStack(spacing: 8) {
                            if let date = sync.lastContact {
                                TimelineView(.periodic(from: .now, by: 30)) { context in
                                    Text(LF("cloud.last", relativeSyncTime(date, now: context.date)))
                                        .font(.callout).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            ProgressView().controlSize(.small)
                                .frame(width: 16, height: 16)
                                .opacity(sync.busy || sync.managing ? 1 : 0)
                                .accessibilityHidden(!(sync.busy || sync.managing))
                            if sync.enabled {
                                Button(L("cloud.refresh")) { sync.refresh(localChanged: true) }
                                    .settingsActionForeground().disabled(sync.busy || sync.managing)
                            }
                        }
                        .transition(.opacity)
                    }
                    if sync.pausing {
                        Text(L("cloud.pausing")).font(.callout).foregroundStyle(.secondary)
                            .transition(.opacity)
                    }
                    if let message = sync.message {
                        WorkspaceErrorMessage(title: message) {}
                            .transition(.opacity)
                    }
                    if let notice = sync.compatibilityNotice {
                        Text(notice).font(.callout).foregroundStyle(.secondary)
                            .transition(.opacity)
                    }
                }
                .clipped()
                .animation(DashboardMotion.animation(DashboardMotion.panel, reduceMotion: reduceMotion), value: sync.enabled || sync.busy || sync.managing || sync.lastContact != nil)
                .animation(DashboardMotion.animation(DashboardMotion.panel, reduceMotion: reduceMotion), value: sync.pausing)
                .animation(DashboardMotion.animation(DashboardMotion.panel, reduceMotion: reduceMotion), value: sync.message != nil)
                .animation(DashboardMotion.animation(DashboardMotion.panel, reduceMotion: reduceMotion), value: sync.compatibilityNotice != nil)
            }
            WorkspacePanel {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L("cloud.storage")).font(.headline)
                            Text(L("cloud.pauseNote"))
                                .font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        VStack(alignment: .trailing, spacing: 8) {
                            Button(L("cloud.delete_data")) { choosingDeletionScope = true }
                                .settingsActionForeground()
                            if sync.hasUnconfirmedDeviceDeletion {
                                Button(L("cloud.checkDeviceDeletion")) { Task { await sync.confirmPreviousDeletion(all: false) } }
                                    .settingsActionForeground()
                                    .transition(.opacity)
                            }
                            if sync.hasUnconfirmedAllDeletion {
                                Button(L("cloud.checkAllDeletion")) { Task { await sync.confirmPreviousDeletion(all: true) } }
                                    .settingsActionForeground()
                                    .transition(.opacity)
                            }
                        }
                        .disabled(sync.managing)
                    }
                }
                .clipped()
                .animation(DashboardMotion.animation(DashboardMotion.panel, reduceMotion: reduceMotion), value: sync.hasUnconfirmedDeviceDeletion)
                .animation(DashboardMotion.animation(DashboardMotion.panel, reduceMotion: reduceMotion), value: sync.hasUnconfirmedAllDeletion)
            }
        }
        .confirmationDialog(L("cloud.choose_delete_scope"), isPresented: $choosingDeletionScope, titleVisibility: .visible) {
            Button(Scope.device.title, role: .destructive) { deletion = .device }
            Button(Scope.all.title, role: .destructive) { deletion = .all }
            Button(L("action.cancel"), role: .cancel) {}.keyboardShortcut(.defaultAction)
        }
        .alert(deletion?.title ?? "", isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } }),
               presenting: deletion) { scope in
            Button(L("action.cancel"), role: .cancel) {}.keyboardShortcut(.defaultAction)
            Button(scope.title, role: .destructive) { Task { await sync.delete(all: scope == .all) } }
        } message: { scope in
            Text(scope.detail)
        }
    }

    private func relativeSyncTime(_ date: Date, now: Date) -> String {
        if now.timeIntervalSince(date) < 1 { return L("cloud.just_now") }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Localization.locale
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
