// [INPUT]: 接收用量存储、更新服务及系统登录项状态。
// [OUTPUT]: 各项设置、卡片内的重算确认、采集和备份恢复反馈。
// [POS]: 设置窗口入口；价格目录交给 PriceCatalogView 展示。
// [PROTOCOL]: Update this header on change, then check AGENTS.md
import AppKit
import SwiftUI
import ServiceManagement

private enum SettingsSection: String, CaseIterable {
    case general, hud, prices, collection, sources, cloud, data, about
    var title: String { L(self == .sources ? "nav.sources" : "settings." + rawValue) }
    var icon: String {
        switch self {
        case .general: "gearshape"
        case .hud: "rectangle.on.rectangle"
        case .prices: "dollarsign.circle"
        case .collection: "arrow.triangle.2.circlepath"
        case .sources: "square.stack.3d.up"
        case .cloud: "icloud"
        case .data: "externaldrive"
        case .about: "info.circle"
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

        var stateKey: Int {
            switch self {
            case .pending: 1
            case .succeeded: 2
            case .failed: 3
            }
        }
    }

    let operation: SettingsOperation
    let phase: Phase

    var isPending: Bool {
        if case .pending = phase { return true }
        return false
    }

    var isSucceeded: Bool {
        if case .succeeded = phase { return true }
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

private struct PriceReview {
    let estimate: RepricePreview
    let usesSavedRates: Bool
}

struct SettingsView: View {
    @Environment(UsageStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var ratesExpanded = true
    @State private var tab: SettingsSection = .general
    @AppStorage("appLanguage") private var language = AppLanguage.system.rawValue
    @AppStorage(AppAppearance.defaultsKey) private var appearance = AppAppearance.system
    @State private var login = LoginItemService()
    @ObservedObject private var updates = UpdateChecker.shared
    @State private var interval = 60
    @State private var scanPaths: [String: String] = [:]
    @State private var defaultScanPaths: [String: [String]] = [:]
    @State private var defaultPathsLoaded = false
    @State private var defaultPathsFailed = false
    @State private var collectionDraftInitialized = false
    @State private var selectedClient = "claude"
    @State private var pricingBusy = false
    @State private var priceNotice: String?
    @State private var priceFailure: (title: String, detail: String)?
    @State private var collectionStatus: SettingsOperationStatus?
    @State private var ledgerStatus: SettingsOperationStatus?
    @State private var importDraft = ImportDraft()
    @State private var exportState = SourceExportState()
    @State private var priceReview: PriceReview?
    @State private var pendingRestore: URL?

    private var busy: Bool {
        importDraft.busy || exportState.inProgress || pricingBusy
            || collectionStatus?.isPending == true || ledgerStatus?.isPending == true
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
                            .transition(.opacity)
                        switch tab {
                        case .general: generalSettings
                        case .hud: HUDSettingsView()
                        case .prices: priceSettings
                        case .collection: collectionSettings
                        case .sources: SourcesView(exportState: exportState, exportAllowed: !busy)
                        case .cloud: DeviceSyncSettings()
                        case .data: dataSettings
                        case .about: aboutSettings
                        }
                    }.padding(.horizontal, 24).padding(.bottom, 24)
                        .animation(DashboardMotion.animation(DashboardMotion.panel, reduceMotion: reduceMotion), value: store.error != nil)
                }
                .id(tab)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(WorkspaceStyle.canvas(scheme))
        }
        .frame(width: 880, height: 610).navigationTitle(L("settings.window"))
            .toolbar(removing: .title)
            .disclosureGroupStyle(WorkspaceDisclosureStyle())
            .onChange(of: appearance) { _, value in value.apply() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                login.refresh()
            }
            .onChange(of: interval) { _, _ in clearSavedCollectionStatus() }
            .onChange(of: scanPaths) { _, _ in clearSavedCollectionStatus() }
            .task {
                login.refresh()
                await store.loadManagement()
                initializeCollectionDraft()
            }
            .task(id: tab) {
                if tab == .collection && !defaultPathsLoaded { await loadDefaultScanPaths() }
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
        let pickerWidth = WorkspaceDropdownTrigger.fittingWidth(for: AppLanguage.allCases.map(\.title) + AppAppearance.allCases.map(\.title))
        return WorkspacePanel {
            VStack(spacing: 16) {
                HStack {
                    Text(L("appearance.title"))
                    Spacer()
                    WorkspaceDropdown(
                        label: L("appearance.title"), selection: $appearance,
                        options: AppAppearance.allCases, width: pickerWidth, title: { $0.title }
                    )
                }
                Divider()
                HStack {
                    Text(L("language.title"))
                    Spacer()
                    WorkspaceDropdown(
                        label: L("language.title"), selection: $language,
                        options: AppLanguage.allCases.map(\.rawValue), width: pickerWidth,
                        title: { (AppLanguage(rawValue: $0) ?? .system).title }
                    )
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
                    SettingsSwitch(label: L("settings.login"), isOn: Binding(get: { login.enabled }, set: { value in do { try login.setEnabled(value) } catch { store.fail(error) } }))
                }
                if login.status == .requiresApproval {
                    HStack {
                        Text(login.statusText).font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button(L("settings.open_login")) { SMAppService.openSystemSettingsLoginItems() }
                            .settingsActionForeground()
                    }
                    .transition(.opacity)
                }
            }
            .clipped()
            .animation(DashboardMotion.animation(DashboardMotion.panel, reduceMotion: reduceMotion), value: login.status == .requiresApproval)
        }
    }

    private var aboutSettings: some View {
        let frequencies = UpdateChecker.intervalHours.map { L("update.interval_\($0)") }
        let pickerWidth = WorkspaceDropdownTrigger.fittingWidth(for: frequencies)
        return VStack(alignment: .leading, spacing: 14) {
            WorkspacePanel {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable().scaledToFit().frame(width: 56, height: 56)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Tokenory").font(.title2.weight(.semibold))
                        Text(LF("update.current", updates.currentVersion)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(L("update.check")) { updates.check() }
                        .settingsActionForeground().disabled(!updates.canCheckForUpdates)
                }
            }
            WorkspacePanel {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text(L("update.automatic"))
                        Spacer()
                        SettingsSwitch(label: L("update.automatic"), isOn: Binding(
                            get: { updates.automaticallyChecksForUpdates },
                            set: { updates.setAutomaticChecks($0) }
                        ))
                    }
                    if updates.automaticallyChecksForUpdates {
                        VStack(alignment: .leading, spacing: 14) {
                            Divider()
                            HStack {
                                Text(L("update.frequency"))
                                Spacer()
                                WorkspaceDropdown(
                                    label: L("update.frequency"),
                                    selection: Binding(get: { updates.checkIntervalHours }, set: { updates.setIntervalHours($0) }),
                                    options: UpdateChecker.intervalHours, width: pickerWidth, title: { L("update.interval_\($0)") }
                                )
                            }
                        }
                        .transition(.opacity)
                    }
                    if let error = updates.startupError {
                        WorkspaceErrorMessage(title: error) {}
                            .transition(.opacity)
                    }
                }
                .clipped()
                .animation(DashboardMotion.animation(DashboardMotion.panel, reduceMotion: reduceMotion), value: updates.automaticallyChecksForUpdates)
                .animation(DashboardMotion.animation(DashboardMotion.panel, reduceMotion: reduceMotion), value: updates.startupError != nil)
            }
        }
    }
    private var priceSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            WorkspacePanel {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 20) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L("price.automatic")).font(.headline)
                            Text(L("price.explanation")).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                                .frame(width: 16, height: 16)
                                .opacity(pricingBusy && priceReview == nil ? 1 : 0)
                                .accessibilityHidden(!(pricingBusy && priceReview == nil))
                            Button(L("price.refresh"), action: refreshPricesAndPreview)
                                .settingsActionForeground().disabled(busy || priceReview != nil)
                        }
                        .fixedSize(horizontal: true, vertical: false)
                    }
                    if let priceReview {
                        VStack(alignment: .leading, spacing: 14) {
                            Divider()
                            priceReviewContent(priceReview)
                        }
                        .transition(.opacity)
                    }
                    if let priceFailure {
                        WorkspaceErrorMessage(title: priceFailure.title, detail: priceFailure.detail) {}
                            .transition(.opacity)
                    } else if let priceNotice, priceReview == nil {
                        Label(priceNotice, systemImage: "checkmark.circle")
                            .font(.callout).foregroundStyle(.secondary)
                            .transition(.opacity)
                    }
                }
                .clipped()
                .animation(DashboardMotion.animation(DashboardMotion.panel, reduceMotion: reduceMotion), value: priceReview != nil)
                .animation(DashboardMotion.animation(DashboardMotion.panel, reduceMotion: reduceMotion), value: priceFailure != nil)
                .animation(DashboardMotion.animation(DashboardMotion.panel, reduceMotion: reduceMotion), value: priceNotice)
            }
            WorkspacePanel {
                VStack(alignment: .leading, spacing: 16) {
                    DisclosureGroup(L("price.rates"), isExpanded: $ratesExpanded) {
                        PriceCatalogView(providers: store.priceProviders, usedModels: store.usedPriceModels)
                    }
                    let missingModels = store.prices["missing"].array
                    if !missingModels.isEmpty {
                        Divider()
                        DisclosureGroup(LF("price.missing_models", missingModels.count)) {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(L("price.missing_reason")).font(.caption).foregroundStyle(.secondary)
                                ForEach(missingModels, id: \.self) { missing in
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
    }

    private func priceReviewContent(_ review: PriceReview) -> some View {
        let estimate = review.estimate
        return VStack(alignment: .leading, spacing: 9) {
            Text(L("price.preview")).font(.headline)
            if review.usesSavedRates {
                Text(L("price.refresh_fallback")).font(.callout).foregroundStyle(.secondary)
            }
            Text(LF("price.preview_summary", estimate.records, usd(estimate.before), usd(estimate.after)))
            if estimate.unpricedTokens > 0 {
                Text(LF("price.preview_unpriced", compactTokens(estimate.unpricedTokens)))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Spacer()
                Button(L("action.cancel")) { priceReview = nil }.settingsActionForeground().disabled(pricingBusy)
                ProgressView().controlSize(.small)
                    .frame(width: 16, height: 16)
                    .opacity(pricingBusy ? 1 : 0)
                    .accessibilityHidden(!pricingBusy)
                Button(L("price.apply")) { applyReprice(estimate) }
                    .buttonStyle(.borderedProminent).disabled(busy)
            }
        }
        .font(.callout)
    }
    private var collectionSettings: some View {
        let intervals = [30, 60, 120]
        let intervalTitles = (intervals + [interval]).map { LF("settings.interval_seconds", $0) }
        return VStack(alignment: .leading, spacing: 14) {
            WorkspacePanel {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text(L("settings.interval"))
                        Spacer()
                        WorkspaceDropdown(
                            label: L("settings.interval"), selection: $interval, options: intervals,
                            width: WorkspaceDropdownTrigger.fittingWidth(for: intervalTitles),
                            title: { LF("settings.interval_seconds", $0) }
                        )
                    }
                    Divider()
                    HStack {
                        Text(L("settings.timezone"))
                        Spacer()
                        Text(store.systemTimeZone.identifier).foregroundStyle(.secondary)
                    }
                    Text(L("settings.timezone_note")).font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(collectionStatus?.isPending == true || !collectionDraftInitialized)
            WorkspacePanel {
                VStack(alignment: .leading, spacing: 12) {
                    let clients = store.clients.filter(\.supportsExtraPaths)
                    Group {
                        HStack(spacing: 10) {
                            Text(L("field.tool"))
                            WorkspaceDropdown(
                                label: L("field.tool"), selection: $selectedClient, options: clients.map(\.id), width: 156,
                                title: { id in clients.first(where: { $0.id == id })?.name ?? clientName(id) },
                                brand: { ($0, .tool) }
                            ).disabled(clients.isEmpty)
                        }
                        pathEditor(text: Binding(
                            get: { scanPaths[selectedClient] ?? "" },
                            set: { scanPaths[selectedClient] = $0 }
                        ))
                        Text(L("settings.paths_note")).font(.caption).foregroundStyle(.secondary)
                        if let conflict = duplicateScanPathClient {
                            WorkspaceErrorMessage(title: LF("settings.duplicate_path", clientName(conflict))) {}
                                .transition(.opacity)
                        }
                    }
                    .disabled(collectionStatus?.isPending == true || !collectionDraftInitialized)
                    collectionSaveControl
                }
                .clipped()
                .animation(DashboardMotion.animation(DashboardMotion.panel, reduceMotion: reduceMotion), value: duplicateScanPathClient != nil)
                .animation(DashboardMotion.animation(DashboardMotion.panel, reduceMotion: reduceMotion), value: collectionStatus?.phase.stateKey ?? 0)
            }
        }
    }

    private var collectionSaveControl: some View {
        Group {
            if case .failed(let detail)? = collectionStatus?.phase {
                WorkspaceErrorMessage(title: L("settings.save_failed"), detail: detail) { collectionSaveButton }
                    .transition(.opacity)
            } else {
                collectionSaveButton.frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private var collectionSaveButton: some View {
        Button(action: saveSettings) {
            ZStack {
                // Keep the button width stable while the status changes.
                ForEach(["settings.save", "settings.saving", "settings.saved", "action.retry"], id: \.self) { key in
                    Label(L(key), systemImage: "checkmark").hidden()
                }
                Group {
                    if let status = collectionStatus {
                        switch status.phase {
                        case .pending:
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text(status.message)
                            }
                        case .succeeded:
                            Label(status.message, systemImage: "checkmark")
                        case .failed:
                            Text(L("action.retry"))
                        }
                    } else {
                        Text(L("settings.save"))
                    }
                }
                .transition(.opacity)
            }
            .animation(DashboardMotion.animation(DashboardMotion.state, reduceMotion: reduceMotion), value: collectionStatus?.phase.stateKey ?? 0)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
        .disabled(busy || collectionStatus?.isSucceeded == true || !hasCollectionEdits
                  || !defaultPathsLoaded || duplicateScanPathClient != nil)
    }
    private func pathEditor(text: Binding<String>) -> some View {
        let defaults = defaultScanPaths[selectedClient] ?? []
        return VStack(alignment: .leading, spacing: 0) {
            if defaultPathsFailed {
                WorkspaceErrorMessage(title: L("settings.default_paths_failed")) {
                    Button(L("action.retry")) { Task { await loadDefaultScanPaths() } }
                        .settingsActionForeground()
                }.padding(8)
            } else if defaultPathsLoaded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(defaults, id: \.self) { path in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: "lock.fill").font(.system(size: 10)).accessibilityHidden(true)
                                Text(path).font(.system(size: 12, design: .monospaced))
                                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                            }
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.padding(8)
                }.frame(height: min(CGFloat(max(defaults.count, 1)) * 19 + 16, 110))
                Divider().padding(.horizontal, 8)
            } else {
                ProgressView().controlSize(.small).padding(8)
            }
            TextEditor(text: text)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8).frame(height: 70)
                .accessibilityLabel(L("settings.extra_paths"))
        }
        .background(WorkspaceStyle.canvas(scheme), in: RoundedRectangle(cornerRadius: WorkspaceStyle.fieldRadius))
    }

    private func loadDefaultScanPaths() async {
        defaultPathsFailed = false
        if store.settings == nil {
            await store.loadManagement()
            guard store.settings != nil else {
                defaultPathsFailed = true
                return
            }
        }
        initializeCollectionDraft()
        do {
            defaultScanPaths = try await store.perform("defaultScanPaths").decode([String: [String]].self)
            defaultPathsLoaded = true
        } catch {
            defaultPathsLoaded = false
            defaultPathsFailed = true
        }
    }

    private func initializeCollectionDraft() {
        guard !collectionDraftInitialized, let settings = store.settings else { return }
        interval = settings.intervalSeconds
        scanPaths = settings.extraScanPaths.mapValues { $0.joined(separator: "\n") }
        collectionDraftInitialized = true
    }

    private func expandedScanPath(_ value: String, home: String) -> String {
        if value == "~" { return home }
        if value.hasPrefix("~/") { return home + String(value.dropFirst()) }
        return value
    }

    private func scanPathIdentity(_ value: String, home: String) -> String {
        let expanded = expandedScanPath(value, home: home)
        guard expanded.hasPrefix("/") else { return expanded }
        return URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func normalizedScanPaths(home: String) -> [String: [String]] {
        scanPaths.mapValues { text in
            text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                .map { expandedScanPath($0, home: home) }
        }.filter { !$0.value.isEmpty }
    }

    private var hasCollectionEdits: Bool {
        guard collectionDraftInitialized, let settings = store.settings else { return false }
        return interval != settings.intervalSeconds || normalizedScanPaths(home: settings.homeDir) != settings.extraScanPaths
    }

    private var duplicateScanPathClient: String? {
        guard let settings = store.settings, defaultPathsLoaded else { return nil }
        for client in scanPaths.keys.sorted() {
            let current = scanPaths[client, default: ""].split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let old = settings.extraScanPaths[client, default: []]
            let counts: ([String]) -> [String: Int] = { paths in
                paths.reduce(into: [:]) { result, path in
                    result[scanPathIdentity(path, home: settings.homeDir), default: 0] += 1
                }
            }
            let oldCounts = counts(old)
            let defaults = Set((defaultScanPaths[client] ?? []).map { scanPathIdentity($0, home: settings.homeDir) })
            for (path, count) in counts(current) where count > oldCounts[path, default: 0] {
                if count > 1 || defaults.contains(path) { return client }
            }
        }
        return nil
    }
    private var dataSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            WorkspacePanel {
                ImportView(draft: importDraft)
                    .disabled(exportState.inProgress || pricingBusy
                              || collectionStatus?.isPending == true || ledgerStatus?.isPending == true)
            }
            WorkspacePanel {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 20) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L("data.backups")).font(.headline)
                            Text(L("data.backup_note")).font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Menu(L("data.backup_management")) {
                            Button(L("data.backup"), action: backup)
                            Button(L("data.restore"), action: chooseRestore)
                        }
                        .settingsActionForeground()
                        .fixedSize()
                        .disabled(busy)
                    }
                    if let ledgerStatus {
                        operationFeedback(ledgerStatus)
                            .transition(.opacity)
                    }
                }
                .clipped()
                .animation(DashboardMotion.animation(DashboardMotion.panel, reduceMotion: reduceMotion), value: ledgerStatus?.phase.stateKey ?? 0)
            }
            WorkspacePanel {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("data.location")).font(.headline)
                        Text(store.dataDirectory.path).font(.callout).foregroundStyle(.secondary)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button(L("data.finder")) { NSWorkspace.shared.open(store.dataDirectory) }
                        .settingsActionForeground()
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
                WorkspaceErrorMessage(title: status.message, detail: detail) {
                    Button(L("action.retry")) { retry(status.operation) }
                        .settingsActionForeground().disabled(busy)
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
        if collectionStatus?.isSucceeded == true { collectionStatus = nil }
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

    private func refreshPricesAndPreview() {
        guard !busy, priceReview == nil else { return }
        pricingBusy = true
        priceNotice = nil
        priceFailure = nil
        Task {
            defer { pricingBusy = false }
            do {
                struct RefreshedPrice: Decodable { let id: String }
                let snapshotId: String
                var refreshError: Error?
                do {
                    snapshotId = try await store.perform("refreshPrices").decode(RefreshedPrice.self).id
                    await store.loadManagement(notifyOnFailure: false)
                } catch {
                    guard let savedId = store.prices["current"]["id"].string else { throw error }
                    snapshotId = savedId
                    refreshError = error
                }
                let payload: JSONValue = .object(["snapshotId": .string(snapshotId), "filter": .object([:])])
                let estimate = try await store.perform("repricePreview", payload: payload).decode(RepricePreview.self)
                if estimate.records > 0 {
                    priceReview = PriceReview(estimate: estimate, usesSavedRates: refreshError != nil)
                } else if let refreshError {
                    priceFailure = (L("price.refresh_failed"), refreshError.localizedDescription)
                } else {
                    priceNotice = L("price.refreshed")
                }
            } catch { priceFailure = (L("price.refresh_failed"), error.localizedDescription) }
        }
    }
    private func applyReprice(_ p: RepricePreview) {
        guard !busy else { return }
        pricingBusy = true
        priceFailure = nil
        Task {
            defer { pricingBusy = false }
            do {
                _ = try await store.perform("repriceApply", payload: .object(["id": .string(p.id)]))
                await store.refresh()
                await store.loadManagement(notifyOnFailure: false)
                priceReview = nil
                priceNotice = L("price.applied")
            } catch {
                priceReview = nil
                priceFailure = (L("price.apply_failed"), error.localizedDescription)
            }
        }
    }
    private func saveSettings() {
        guard hasCollectionEdits, var settings = store.settings else { return }
        settings.intervalSeconds = interval
        settings.extraScanPaths = normalizedScanPaths(home: settings.homeDir)
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
        runOperation(.restore) {
            try await store.restore(from: file)
            importDraft = ImportDraft()
            priceReview = nil
        }
    }
}
