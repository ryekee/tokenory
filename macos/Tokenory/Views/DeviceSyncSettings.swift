// [INPUT]: Private-library state and deliberate user actions.
// [OUTPUT]: iCloud sync and storage cards with live relative status and a Delete Data action with two-step confirmation.
// [POS]: iCloud settings section.
// [PROTOCOL]: Update this header on change, then check AGENTS.md
import SwiftUI

struct DeviceSyncSettings: View {
    @Environment(UsageStore.self) private var store
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
                    HStack {
                        if sync.busy || sync.managing { ProgressView().controlSize(.small) }
                        if let date = sync.lastContact {
                            TimelineView(.periodic(from: .now, by: 30)) { context in
                                Text(LF("cloud.last", relativeSyncTime(date, now: context.date)))
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if sync.enabled {
                            Button(L("cloud.refresh")) { sync.refresh(localChanged: true) }
                                .settingsActionForeground().disabled(sync.busy || sync.managing)
                        }
                    }
                    if sync.pausing { Text(L("cloud.pausing")).font(.callout).foregroundStyle(.secondary) }
                    if let message = sync.message { Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                    if let notice = sync.compatibilityNotice { Text(notice).font(.callout).foregroundStyle(.secondary) }
                }
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
                            }
                            if sync.hasUnconfirmedAllDeletion {
                                Button(L("cloud.checkAllDeletion")) { Task { await sync.confirmPreviousDeletion(all: true) } }
                                    .settingsActionForeground()
                            }
                        }
                        .disabled(sync.managing)
                    }
                }
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
