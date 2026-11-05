import AppKit
import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @Environment(UsageStore.self) private var store
    @State private var tab = "general"
    @AppStorage("appLanguage") private var language = AppLanguage.system.rawValue
    @State private var login = LoginItemService()
    @State private var interval = 60
    @State private var claudePaths = ""
    @State private var codexPaths = ""
    @State private var busy = false
    @State private var notice: String?
    @State private var preview: RepricePreview?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker(L("settings.title"), selection: $tab) { Text(L("settings.general")).tag("general"); Text(L("settings.prices")).tag("prices"); Text(L("settings.collection")).tag("collection"); Text(L("settings.data")).tag("data") }.labelsHidden().pickerStyle(.segmented)
            ErrorBanner()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if tab == "general" { generalSettings }
                    else if tab == "prices" { priceSettings }
                    else if tab == "collection" { collectionSettings }
                    else { dataSettings }
                    if let notice { Text(notice).font(.callout).foregroundStyle(.secondary) }
                }.padding(.vertical, 8)
            }
        }.padding(24).frame(width: 680, height: 580).navigationTitle(L("settings.window"))
            .task {
                await store.loadManagement(); login.refresh()
                if let s = store.settings { interval = s.intervalSeconds; claudePaths = (s.extraScanPaths["claude"] ?? []).joined(separator: "\n"); codexPaths = (s.extraScanPaths["codex"] ?? []).joined(separator: "\n") }
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
        Form {
            Picker(L("language.title"), selection: $language) {
                ForEach(AppLanguage.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
            }
            LabeledContent(L("currency.title"), value: L("currency.usd"))
            Toggle(L("settings.login"), isOn: Binding(get: { login.enabled }, set: { value in do { try login.setEnabled(value) } catch { store.fail(error) } }))
            if login.status == .requiresApproval { Button(L("settings.open_login")) { SMAppService.openSystemSettingsLoginItems() } }
        }.formStyle(.grouped)
    }
    private var priceSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L("price.automatic")).font(.headline)
            Text(L("price.explanation")).foregroundStyle(.secondary)
            HStack {
                Button(L("price.refresh")) { refreshPrices() }.disabled(busy)
                Button(L("price.reestimate")) { reprice() }.disabled(busy || store.prices["current"]["id"].string == nil)
                if busy { ProgressView().controlSize(.small) }
            }
            Divider()
            Text("DeepSeek").font(.headline)
            Text(L("price.deepseek_schedule")).font(.callout).foregroundStyle(.secondary)
            Link(L("price.official_page"), destination: URL(string: "https://api-docs.deepseek.com/quick_start/pricing/")!)
            DisclosureGroup(L("price.rates")) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L("price.rate_units")).font(.caption).foregroundStyle(.secondary)
                    Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 10) {
                        GridRow { Text(L("field.model")); Text(L("token.input")); Text(L("token.cache_read")); Text(L("token.output")) }.font(.caption).foregroundStyle(.secondary)
                        ForEach(store.prices["current"]["snapshot"]["entries"].array, id: \.self) { entry in
                            GridRow {
                                Text(entry["model"].string ?? "").lineLimit(1).truncationMode(.middle).help(entry["source"].string ?? "")
                                Text(rate(entry, "input_cost_per_token"))
                                Text(rate(entry, "cache_read_input_token_cost"))
                                Text(rate(entry, "output_cost_per_token"))
                            }.font(.caption).monospacedDigit()
                        }
                    }
                }.padding(.top, 12)
            }
            DisclosureGroup(LF("price.missing_models", store.prices["missing"].array.count)) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L("price.missing_reason")).font(.caption).foregroundStyle(.secondary)
                    ForEach(store.prices["missing"].array, id: \.self) { missing in
                        HStack { Text(missing["model"].string ?? ""); Spacer(); Text(compactTokens(missing["tokens"].int ?? 0)).monospacedDigit() }
                    }
                }.padding(.top, 12)
            }
        }
    }
    private func rate(_ entry: JSONValue, _ key: String) -> String {
        guard let value = entry["rates"][key].double else { return L("value.unavailable") }
        return usd(value * 1_000_000, detailed: true)
    }
    private var collectionSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text(L("settings.interval")); Stepper(LF("settings.interval_seconds", interval), value: $interval, in: 15...86400, step: 15) }
            LabeledContent(L("settings.timezone"), value: store.settings?.timezone ?? "Asia/Shanghai")
            Text(L("settings.timezone_note")).font(.caption).foregroundStyle(.secondary)
            Text(L("settings.claude_paths")).font(.headline)
            TextEditor(text: $claudePaths).font(.system(.body, design: .monospaced)).frame(height: 60).border(.quaternary)
            Text(L("settings.codex_paths")).font(.headline)
            TextEditor(text: $codexPaths).font(.system(.body, design: .monospaced)).frame(height: 60).border(.quaternary)
            Text(L("settings.paths_note")).font(.caption).foregroundStyle(.secondary)
            Button(L("settings.save")) { saveSettings() }

        }
    }
    private var dataSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(store.dataDirectory.path).font(.callout).textSelection(.enabled)
            Button(L("data.finder")) { NSWorkspace.shared.open(store.dataDirectory) }
            Button(L("data.backup")) { backup() }.disabled(busy)
            Text(L("data.backup_note")).foregroundStyle(.secondary)
            Button(L("data.restore")) { restore() }.disabled(busy)
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
        settings.extraScanPaths = ["claude": claudePaths.split(separator: "\n").map(String.init), "codex": codexPaths.split(separator: "\n").map(String.init)]
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
