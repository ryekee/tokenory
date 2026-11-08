import AppKit
import SwiftUI
import ServiceManagement

private enum SettingsSection: String, CaseIterable {
    case general, prices, collection, data
    var title: String { L("settings." + rawValue) }
    var icon: String {
        switch self {
        case .general: "gearshape"
        case .prices: "dollarsign.circle"
        case .collection: "arrow.triangle.2.circlepath"
        case .data: "externaldrive"
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
    @State private var interval = 60
    @State private var scanPaths: [String: String] = [:]
    @State private var selectedClient = "claude"
    @State private var busy = false
    @State private var notice: String?
    @State private var preview: RepricePreview?
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
                        case .prices: priceSettings
                        case .collection: collectionSettings
                        case .data: dataSettings
                        }
                        if let notice {
                            Label(notice, systemImage: "checkmark.circle")
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
            .onChange(of: tab) { _, _ in notice = nil }
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
                    Text(LF("update.current", UpdateChecker.shared.currentVersion)).foregroundStyle(.secondary)
                    Spacer()
                    if UpdateChecker.shared.isChecking { ProgressView().controlSize(.small) }
                    Button(L("update.check")) { Task { await UpdateChecker.shared.check() } }
                        .disabled(UpdateChecker.shared.isChecking)
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
                        if busy { ProgressView().controlSize(.small) }
                    }.padding(.top, 2)
                }
            }
            WorkspacePanel {
                VStack(alignment: .leading, spacing: 16) {
                    DisclosureGroup(L("price.rates"), isExpanded: $ratesExpanded) {
                        PriceCatalogView(providers: store.priceProviders)
                    }
                    Divider()
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(L("price.deepseek_schedule")).font(.callout).foregroundStyle(.secondary)
                            Link(L("price.official_page"), destination: URL(string: "https://api-docs.deepseek.com/quick_start/pricing/")!)
                        }.padding(.top, 12)
                    } label: { BrandLabel(name: "deepseek", kind: .provider, title: "DeepSeek") }
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
                        }.padding(.top, 12)
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
            HStack {
                Spacer()
                Button(L("settings.save")) { saveSettings() }.buttonStyle(.borderedProminent)
            }
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
                        Button(L("data.backup")) { backup() }.disabled(busy)
                        Button(L("data.restore")) { restore() }.disabled(busy)
                    }
                }
            }
        }
    }
    private func refreshPrices() {
        busy = true
        Task { defer { busy = false }; do { _ = try await store.perform("refreshPrices"); notice = L("price.refreshed"); await store.loadManagement() } catch { store.fail(error) } }
    }
    private func reprice() {
        guard let id = store.prices["current"]["id"].string else { return }; busy = true
        Task { defer { busy = false }; do { preview = try await store.perform("repricePreview", payload: .object(["snapshotId": .string(id), "filter": .object([:])])).decode(RepricePreview.self) } catch { store.fail(error) } }
    }
    private func applyReprice(_ p: RepricePreview) {
        busy = true
        Task { defer { busy = false }; do { _ = try await store.perform("repriceApply", payload: .object(["id": .string(p.id)])); preview = nil; notice = L("price.applied"); await store.refresh(); await store.loadManagement() } catch { store.fail(error) } }
    }
    private func saveSettings() {
        guard var settings = store.settings else { return }
        settings.intervalSeconds = interval
        settings.extraScanPaths = scanPaths.mapValues { text in
            text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }.filter { !$0.value.isEmpty }
        Task { do { _ = try await store.perform("updateSettings", payload: try .encode(settings)); notice = L("settings.saved"); await store.loadManagement() } catch { store.fail(error) } }
    }
    private func backup() {
        guard let file = FilePanels.save(name: "Tokenory-\(UsageStore.day(Date())).sqlite3") else { return }
        Task { do { _ = try await store.perform("backup", payload: .object(["path": .string(file.path)])); notice = L("data.backed_up") } catch { store.fail(error) } }
    }
    private func restore() {
        guard let file = FilePanels.open(types: [.data]) else { return }
        busy = true
        Task { defer { busy = false }; do { try await store.restore(from: file); notice = L("data.restored") } catch { store.fail(error) } }
    }
}
