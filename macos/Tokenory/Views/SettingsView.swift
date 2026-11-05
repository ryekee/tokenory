import AppKit
import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @Environment(UsageStore.self) private var store
    @State private var tab = "价格"
    @State private var login = LoginItemService()
    @State private var interval = 60
    @State private var claudePaths = ""
    @State private var codexPaths = ""
    @State private var provider = ""
    @State private var model = ""
    @State private var input = ""
    @State private var output = ""
    @State private var cacheRead = ""
    @State private var cacheWrite = ""
    @State private var free = false
    @State private var fast = false
    @State private var busy = false
    @State private var notice: String?
    @State private var preview: RepricePreview?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("设置", selection: $tab) { Text("价格").tag("价格"); Text("采集与启动").tag("采集与启动"); Text("数据").tag("数据") }.pickerStyle(.segmented)
            ErrorBanner()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if tab == "价格" { priceSettings }
                    else if tab == "采集与启动" { collectionSettings }
                    else { dataSettings }
                    if let notice { Text(notice).font(.callout).foregroundStyle(.secondary) }
                }.padding(.vertical, 8)
            }
        }.padding(24).frame(width: 650, height: 620)
            .task {
                await store.loadManagement(); login.refresh()
                if let s = store.settings { interval = s.intervalSeconds; claudePaths = (s.extraScanPaths["claude"] ?? []).joined(separator: "\n"); codexPaths = (s.extraScanPaths["codex"] ?? []).joined(separator: "\n") }
            }
            .sheet(isPresented: Binding(get: { preview != nil }, set: { if !$0 { preview = nil } })) {
                if let p = preview {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("重估预览").font(.title2)
                        Text("\(p.records) 条记录 · \(usd(p.before)) → \(usd(p.after))").font(.headline)
                        Text("仍有 \(compactTokens(p.unpricedTokens)) tokens 待计价。价格快照与源成本会保留。")
                        HStack { Button("取消") { preview = nil }; Spacer(); Button("确认重估") { applyReprice(p) }.buttonStyle(.borderedProminent).disabled(busy) }
                    }.padding(24).frame(width: 500)
                }
            }
    }
    private var priceSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Button("刷新参考价格") { refreshPrices() }.disabled(busy)
                Button("重估已有用量…") { reprice() }.disabled(busy || store.prices["current"]["id"].string == nil)
                if busy { ProgressView().controlSize(.small) }
            }
            Text("刷新价格只用于后续记录。DeepSeek 使用固定峰时 API 参考价；不还原历史账单。").font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("待计价模型（\(store.prices["missing"].array.count)）") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(store.prices["missing"].array, id: \.self) { missing in
                        Button { provider = missing["provider"].string ?? ""; model = missing["model"].string ?? "" } label: {
                            HStack { Text(missing["model"].string ?? "").lineLimit(2); Spacer(); Text(compactTokens(missing["tokens"].int ?? 0)) }
                        }.buttonStyle(.plain)
                    }
                }.padding(.top, 10)
            }
            Divider()
            Text("指定模型费率").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow { Text("提供方"); TextField("如 deepseek", text: $provider) }
                GridRow { Text("模型"); TextField("完整模型 ID", text: $model) }
                GridRow { Text("输入 / 输出"); HStack { TextField("USD / 百万", text: $input); TextField("USD / 百万", text: $output) } }
                GridRow { Text("缓存读取 / 写入"); HStack { TextField("未知可留空", text: $cacheRead); TextField("未知可留空", text: $cacheWrite) } }
            }.textFieldStyle(.roundedBorder)
            Toggle("已确认此模型免费", isOn: $free)
            Toggle("此费率明确包含 Fast / Ultrafast 档位", isOn: $fast)
            Button("保存费率") { savePrice() }.disabled(busy || provider.isEmpty || model.isEmpty)
        }
    }
    private var collectionSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("扫描间隔"); Stepper("\(interval) 秒", value: $interval, in: 15...86400, step: 15) }
            LabeledContent("日期归档时区", value: store.settings?.timezone ?? "Asia/Shanghai")
            Text("本地事件使用固定时区。历史导入保留来源日期，不随系统时区重分组。").font(.caption).foregroundStyle(.secondary)
            Text("Claude Code 额外目录").font(.headline)
            TextEditor(text: $claudePaths).font(.system(.body, design: .monospaced)).frame(height: 60).border(.quaternary)
            Text("Codex 额外目录").font(.headline)
            TextEditor(text: $codexPaths).font(.system(.body, design: .monospaced)).frame(height: 60).border(.quaternary)
            Text("每行一个绝对路径；默认目录继续扫描。").font(.caption).foregroundStyle(.secondary)
            Button("保存采集设置") { saveSettings() }
            Divider()
            Toggle("登录时启动 Tokenory", isOn: Binding(get: { login.enabled }, set: { value in do { try login.setEnabled(value) } catch { store.fail(error) } }))
            Text(login.statusText).font(.caption).foregroundStyle(.secondary)
            if login.status == .requiresApproval { Button("打开系统登录项设置") { SMAppService.openSystemSettingsLoginItems() } }
        }
    }
    private var dataSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(store.dataDirectory.path).font(.callout).textSelection(.enabled)
            Button("在 Finder 中显示") { NSWorkspace.shared.open(store.dataDirectory) }
            Button("创建数据库备份…") { backup() }.disabled(busy)
            Text("备份包含用量、导入批次、来源选择和价格快照。导入和重估前也会自动备份。").foregroundStyle(.secondary)
            Button("恢复数据库备份…") { restore() }.disabled(busy)
        }
    }
    private func refreshPrices() {
        busy = true
        Task { defer { busy = false }; do { _ = try await store.perform("refreshPrices"); notice = "价格已刷新，已有估算保持不变。"; await store.loadManagement() } catch { store.fail(error) } }
    }
    private func reprice() {
        guard let id = store.prices["current"]["id"].string else { return }; busy = true
        Task { defer { busy = false }; do { preview = try await store.perform("repricePreview", payload: .object(["snapshotId": .string(id), "filter": .object([:])])).decode(RepricePreview.self) } catch { store.fail(error) } }
    }
    private func applyReprice(_ p: RepricePreview) {
        busy = true
        Task { defer { busy = false }; do { _ = try await store.perform("repriceApply", payload: .object(["id": .string(p.id)])); preview = nil; notice = "重估已完成。"; await store.refresh(); await store.loadManagement() } catch { store.fail(error) } }
    }
    private func savePrice() {
        do {
            func rate(_ text: String) throws -> JSONValue {
                if text.trimmingCharacters(in: .whitespaces).isEmpty { return .null }
                guard let value = Double(text), value.isFinite, value >= 0 else { throw EngineError(code: "rate", message: "费率必须是非负数字。") }; return .number(value / 1_000_000)
            }
            let rates: JSONValue = .object(["input_cost_per_token": try rate(input), "output_cost_per_token": try rate(output), "cache_read_input_token_cost": try rate(cacheRead), "cache_creation_input_token_cost": try rate(cacheWrite)])
            let payload: JSONValue = .object(["provider": .string(provider), "model": .string(model), "matchedKey": .string(model), "source": .string("User"), "assumption": .string("User-specified fixed API-equivalent rates per token; no historical invoice reconstruction"), "explicitFree": .bool(free), "allowFast": .bool(fast), "rates": rates])
            busy = true
            Task { defer { busy = false }; do { _ = try await store.perform("savePrice", payload: payload); notice = "费率已保存。已有记录可通过重估更新。"; await store.loadManagement() } catch { store.fail(error) } }
        } catch { store.fail(error) }
    }
    private func saveSettings() {
        guard var settings = store.settings else { return }
        settings.intervalSeconds = interval
        settings.extraScanPaths = ["claude": claudePaths.split(separator: "\n").map(String.init), "codex": codexPaths.split(separator: "\n").map(String.init)]
        Task { do { _ = try await store.perform("updateSettings", payload: try .encode(settings)); notice = "采集设置已保存。"; await store.loadManagement() } catch { store.fail(error) } }
    }
    private func backup() {
        guard let file = FilePanels.save(name: "Tokenory-\(UsageStore.day(Date())).sqlite3") else { return }
        Task { do { _ = try await store.perform("backup", payload: .object(["path": .string(file.path)])); notice = "备份已保存。" } catch { store.fail(error) } }
    }
    private func restore() {
        guard let file = FilePanels.open(types: [.data]) else { return }
        busy = true
        Task { defer { busy = false }; do { try await store.restore(from: file); notice = "备份已恢复。" } catch { store.fail(error) } }
    }
}
