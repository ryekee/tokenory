// [INPUT]: 接收用量存储、更新服务及系统登录项状态。
// [OUTPUT]: 提供通用、HUD、价格、采集和数据设置；确认账本恢复，在操作旁显示采集和备份结果。
// [POS]: 设置窗口入口；价格目录交给 PriceCatalogView 展示。
// [PROTOCOL]: Update this header on change, then check AGENTS.md
import AppKit
import SwiftUI
import ServiceManagement

private enum SettingsSection: String, CaseIterable {
    case general, hud, prices, collection, data
    var title: String { L("settings." + rawValue) }
    var icon: String {
        switch self {
        case .general: "gearshape"
        case .hud: "rectangle.on.rectangle"
        case .prices: "dollarsign.circle"
        case .collection: "arrow.triangle.2.circlepath"
        case .data: "externaldrive"
        }
    }

}

private enum SettingsOperation {
    case saveCollection, backup, restore

    var section: SettingsSection { self == .saveCollection ? .collection : .data }

    var messageKeys: (pending: String, succeeded: String, failed: String) {
        switch self {
        case .saveCollection: ("settings.saving", "settings.saved", "settings.save_failed")
        case .backup: ("data.backing_up", "data.backed_up", "data.backup_failed")
        case .restore: ("data.restoring", "data.restored", "data.restore_failed")
        }
    }
}

private struct SettingsOperationStatus {
    enum Phase {
        case pending, succeeded, failed(String)
    }

    let operation: SettingsOperation
    let phase: Phase

    var isPending: Bool {
        if case .pending = phase { return true }
        return false
    }

    var message: String {
        let keys = operation.messageKeys
        switch phase {
        case .pending: return L(keys.pending)
        case .succeeded: return L(keys.succeeded)
        case .failed: return L(keys.failed)
        }
    }
}

struct SettingsView: View {
    @Environment(UsageStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @State private var ratesExpanded = true
    @State private var tab: SettingsSection = .general
    @AppStorage("appLanguage") private var language = AppLanguage.system.rawValue
    @State private var login = LoginItemService()
    @ObservedObject private var updates = UpdateChecker.shared
    @State private var interval = 60
    @State private var scanPaths: [String: String] = [:]
    @State private var selectedClient = "claude"
    @State private var pricingBusy = false
    @State private var priceNotice: String?
    @State private var collectionStatus: SettingsOperationStatus?
    @State private var ledgerStatus: SettingsOperationStatus?
    @State private var preview: RepricePreview?
    @State private var pendingRestore: URL?

    private var busy: Bool {
        pricingBusy || collectionStatus?.isPending == true || ledgerStatus?.isPending == true
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                WorkspaceTabs(items: SettingsSection.allCases.map { WorkspaceTab(id: $0, title: $0.title, icon: $0.icon) }, selection: $tab)
                Spacer()
            }.frame(width: 164).background(.regularMaterial)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                Text(tab.title).font(.system(size: 22, weight: .semibold))
                    .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 18)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ErrorBanner()
                        switch tab {
                        case .general: generalSettings
                        case .hud: HUDSettingsView()
                        case .prices: priceSettings
                        case .collection: collectionSettings
                        case .data: dataSettings
                        }
                        if tab == .prices, let priceNotice {
                            Label(priceNotice, systemImage: "checkmark.circle")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }.padding(.horizontal, 24).padding(.bottom, 24)
                        .id(tab).transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(WorkspaceStyle.canvas(scheme))
        }
        .frame(width: 880, height: 610).navigationTitle(L("settings.window"))
            .toolbar(removing: .title)
            .disclosureGroupStyle(WorkspaceDisclosureStyle())
            .onChange(of: tab) { _, _ in priceNotice = nil }
            .onChange(of: interval) { _, _ in clearSavedCollectionStatus() }
            .onChange(of: scanPaths) { _, _ in clearSavedCollectionStatus() }
            .task {
                await store.loadManagement(); login.refresh()
                if let s = store.settings { interval = s.intervalSeconds; scanPaths = s.extraScanPaths.mapValues { $0.joined(separator: "\n") } }
            }
            .sheet(isPresented: Binding(get: { preview != nil }, set: { if !$0 { preview = nil } })) {
                if let p = preview {
                    VStack(alignment: .leading, spacing: 18) {
                        Text(L("price.preview")).font(.title2)
                        Text(LF("price.preview_summary", p.records, usd(p.before), usd(p.after))).font(.headline)
                        Text(LF("price.preview_unpriced", compactTokens(p.unpricedTokens)))
                        HStack { Button(L("action.cancel")) { preview = nil }; Spacer(); Button(L("price.apply")) { applyReprice(p) }.buttonStyle(.borderedProminent).disabled(busy) }
                    }.padding(24).frame(width: 500)
                }
            }
            .alert(
                L("data.restore_confirm_title"),
                isPresented: Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } }),
                presenting: pendingRestore
            ) { backup in
                Button(L("action.cancel"), role: .cancel) {}
                    .keyboardShortcut(.defaultAction)
                Button(L("data.restore_confirm_action"), role: .destructive) { restore(from: backup) }
            } message: { backup in
                Text(LF("data.restore_confirm_message", backup.lastPathComponent))
            }
    }
    private var generalSettings: some View {
        WorkspacePanel {
            VStack(spacing: 16) {
                HStack {
                    Text(L("language.title"))
                    Spacer()
                    Picker(L("language.title"), selection: $language) {
                        ForEach(AppLanguage.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                    }.labelsHidden().fixedSize().frame(width: 180, alignment: .trailing)
                }
                Divider()
                HStack {
                    Text(L("currency.title"))
                    Spacer()
                    Text(L("currency.usd")).foregroundStyle(.secondary).frame(width: 180, alignment: .trailing)
                }
                Divider()
                HStack {
                    Text(L("settings.login"))
                    Spacer()
                    Toggle(L("settings.login"), isOn: Binding(get: { login.enabled }, set: { value in do { try login.setEnabled(value) } catch { store.fail(error) } }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small).fixedSize().frame(width: 180, alignment: .trailing)
                }
                Divider()
                HStack {
                    Text(LF("update.current", updates.currentVersion)).foregroundStyle(.secondary)
                    Spacer()
                    Button(L("update.check")) { updates.check() }
                        .disabled(!updates.canCheckForUpdates)
                }
                HStack {
                    Text(L("update.automatic"))
                    Spacer()
                    Toggle(L("update.automatic"), isOn: Binding(
                        get: { updates.automaticallyChecksForUpdates },
                        set: { updates.setAutomaticChecks($0) }
                    )).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                if updates.automaticallyChecksForUpdates {
                    HStack {
                        Text(L("update.frequency"))
                        Spacer()
                        Picker(L("update.frequency"), selection: Binding(
                            get: { updates.checkIntervalHours },
                            set: { updates.setIntervalHours($0) }
                        )) {
                            ForEach(UpdateChecker.intervalHours, id: \.self) { hours in
                                Text(L("update.interval_\(hours)")).tag(hours)
                            }
                        }.labelsHidden().fixedSize()
                    }
                }
                if let error = updates.startupError {
                    Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                }
                if login.status == .requiresApproval {
                    Button(L("settings.open_login")) { SMAppService.openSystemSettingsLoginItems() }
                }
            }
        }
    }
    private var priceSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            WorkspacePanel {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L("price.automatic")).font(.headline)
                    Text(L("price.explanation")).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button(L("price.refresh")) { refreshPrices() }.disabled(busy)
                        Button(L("price.reestimate")) { reprice() }.disabled(busy || store.prices["current"]["id"].string == nil)
                        if pricingBusy { ProgressView().controlSize(.small) }
                    }.padding(.top, 2)
                }
            }
            WorkspacePanel {
                VStack(alignment: .leading, spacing: 16) {
                    DisclosureGroup(L("price.rates"), isExpanded: $ratesExpanded) {
                        PriceCatalogView(providers: store.priceProviders, usedModels: store.usedPriceModels)
                    }
                    Divider()
                    DisclosureGroup(LF("price.missing_models", store.prices["missing"].array.count)) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(L("price.missing_reason")).font(.caption).foregroundStyle(.secondary)
                            ForEach(store.prices["missing"].array, id: \.self) { missing in
                                HStack {
                                    BrandLabel(name: missing["model"].string ?? "", kind: .model).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Text(compactTokens(missing["tokens"].int ?? 0)).monospacedDigit()
                                }.font(.callout)
                            }
                        }
                    }
                }
            }
        }
    }
    private var collectionSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            WorkspacePanel {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text(L("settings.interval"))
                        Spacer()
                        Stepper(LF("settings.interval_seconds", interval), value: $interval, in: 15...86400, step: 15)
                            .fixedSize()
                    }
                    Divider()
                    HStack {
                        Text(L("settings.timezone"))
                        Spacer()
                        Text(store.settings?.timezone ?? "Asia/Shanghai").foregroundStyle(.secondary)
                    }
                    Text(L("settings.timezone_note")).font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(collectionStatus?.isPending == true)
            WorkspacePanel {
                VStack(alignment: .leading, spacing: 12) {
                    Picker(L("field.tool"), selection: $selectedClient) {
                        ForEach(store.clients.filter(\.supportsExtraPaths)) { client in
                            Text(client.name).tag(client.id)
                        }
                    }
                    pathEditor(L("settings.extra_paths"), tool: selectedClient, text: Binding(
                        get: { scanPaths[selectedClient] ?? "" },
                        set: { scanPaths[selectedClient] = $0 }
                    ))
                    Text(L("settings.paths_note")).font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(collectionStatus?.isPending == true)
            VStack(alignment: .trailing, spacing: 8) {
                Button(L("settings.save"), action: saveSettings)
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || store.settings == nil)
                if let collectionStatus { operationFeedback(collectionStatus) }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
    private func pathEditor(_ title: String, tool: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            BrandLabel(name: tool, kind: .tool, title: title).font(.callout).fontWeight(.medium)
            TextEditor(text: text)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8).frame(height: 70)
                .background(WorkspaceStyle.canvas(scheme), in: RoundedRectangle(cornerRadius: WorkspaceStyle.fieldRadius))
                .accessibilityLabel(title)
        }
    }
    private var dataSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            WorkspacePanel {
                VStack(alignment: .leading, spacing: 12) {
                    Label(L("data.location"), systemImage: "folder").font(.headline)
                    Text(store.dataDirectory.path).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(L("data.finder")) { NSWorkspace.shared.open(store.dataDirectory) }
                }
            }
            WorkspacePanel {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L("data.backups")).font(.headline)
                    Text(L("data.backup_note")).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button(L("data.backup"), action: backup)
                        Button(L("data.restore"), action: chooseRestore)
                    }
                    .disabled(busy)
                    if let ledgerStatus { operationFeedback(ledgerStatus) }
                }
            }
        }
    }
    private func operationFeedback(_ status: SettingsOperationStatus) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            switch status.phase {
            case .pending:
                ProgressView(status.message)
                    .controlSize(.small)
            case .succeeded:
                Label(status.message, systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            case .failed(let detail):
                HStack(spacing: 8) {
                    Label(status.message, systemImage: "exclamationmark.circle")
                    Button(L("action.retry")) { retry(status.operation) }
                        .disabled(busy)
                }
                DisclosureGroup(L("error.details")) {
                    Text(detail).font(.caption).textSelection(.enabled)
                }
            }
        }
        .font(.callout)
    }

    private func retry(_ operation: SettingsOperation) {
        switch operation {
        case .saveCollection: saveSettings()
        case .backup: backup()
        case .restore: chooseRestore()
        }
    }

    private func clearSavedCollectionStatus() {
        if case .succeeded? = collectionStatus?.phase { collectionStatus = nil }
    }

    private func setOperationStatus(_ phase: SettingsOperationStatus.Phase, for operation: SettingsOperation) {
        let status = SettingsOperationStatus(operation: operation, phase: phase)
        if operation == .saveCollection { collectionStatus = status }
        else { ledgerStatus = status }
        if !status.isPending, tab == operation.section, NSApp.isActive {
            AccessibilityNotification.Announcement(status.message).post()
        }
    }

    private func runOperation(_ operation: SettingsOperation, action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        setOperationStatus(.pending, for: operation)
        Task {
            do {
                try await action()
                setOperationStatus(.succeeded, for: operation)
            } catch {
                setOperationStatus(.failed(error.localizedDescription), for: operation)
            }
        }
    }

    private func refreshPrices() {
        pricingBusy = true
        Task { defer { pricingBusy = false }; do { _ = try await store.perform("refreshPrices"); priceNotice = L("price.refreshed"); await store.loadManagement() } catch { store.fail(error) } }
    }
    private func reprice() {
        guard let id = store.prices["current"]["id"].string else { return }; pricingBusy = true
        Task { defer { pricingBusy = false }; do { preview = try await store.perform("repricePreview", payload: .object(["snapshotId": .string(id), "filter": .object([:])])).decode(RepricePreview.self) } catch { store.fail(error) } }
    }
    private func applyReprice(_ p: RepricePreview) {
        pricingBusy = true
        Task { defer { pricingBusy = false }; do { _ = try await store.perform("repriceApply", payload: .object(["id": .string(p.id)])); preview = nil; priceNotice = L("price.applied"); await store.refresh(); await store.loadManagement() } catch { store.fail(error) } }
    }
    private func saveSettings() {
        guard var settings = store.settings else { return }
        settings.intervalSeconds = interval
        settings.extraScanPaths = scanPaths.mapValues { text in
            text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }.filter { !$0.value.isEmpty }
        runOperation(.saveCollection) {
            _ = try await store.perform("updateSettings", payload: try .encode(settings))
            await store.loadManagement()
        }
    }
    private func backup() {
        guard !busy, let file = FilePanels.save(name: "Tokenory-\(UsageStore.day(Date())).sqlite3") else { return }
        runOperation(.backup) {
            _ = try await store.perform("backup", payload: .object(["path": .string(file.path)]))
        }
    }
    private func chooseRestore() {
        guard !busy else { return }
        pendingRestore = FilePanels.open(types: [.data])
    }
    private func restore(from file: URL) {
        runOperation(.restore) { try await store.restore(from: file) }
    }
}
