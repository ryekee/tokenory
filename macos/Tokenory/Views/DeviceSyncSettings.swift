// [INPUT]: Private-library state and deliberate user actions.
// [OUTPUT]: Publish, pause and withdraw usage, or explain why sync is unavailable for this ledger.
import SwiftUI

struct DeviceSyncSettings: View {
    @Environment(UsageStore.self) private var store
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
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label(sync.localName, systemImage: "desktopcomputer").font(.headline)
                Spacer()
                Toggle(L("settings.cloud"), isOn: Binding(get: { sync.enabled }, set: { on in
                    Task { if on { await sync.enable() } else { await sync.stop() } }
                })).toggleStyle(.switch).labelsHidden().disabled(sync.managing)
            }
            Text(L("cloud.scope")).foregroundStyle(.secondary)
            HStack {
                if sync.busy || sync.managing { ProgressView().controlSize(.small) }
                if let date = sync.lastContact {
                    Text(LF("cloud.last", date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: Localization.locale))))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if sync.enabled { Button(L("cloud.refresh")) { sync.refresh(localChanged: true) }.disabled(sync.busy || sync.managing) }
            }
            if let message = sync.message { Text(message).foregroundStyle(.secondary).textSelection(.enabled) }
            Divider()
            Text(L("cloud.storage")).font(.headline)
            Text(L("cloud.pauseNote")).foregroundStyle(.secondary)
            HStack {
                Button(Scope.device.title) { deletion = .device }
                Button(Scope.all.title) { deletion = .all }
            }.disabled(sync.managing)
        }
        .alert(item: $deletion) { scope in
            Alert(title: Text(scope.title), message: Text(scope.detail),
                  primaryButton: .destructive(Text(scope.title)) { Task { await sync.delete(all: scope == .all) } },
                  secondaryButton: .cancel(Text(L("action.cancel"))))
        }
    }
}
