import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
enum FilePanels {
    static func open(types: [UTType] = [.json]) -> URL? {
        let panel = NSOpenPanel(); panel.allowedContentTypes = types; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
    static func save(name: String) -> URL? {
        let panel = NSSavePanel(); panel.nameFieldStringValue = name
        return panel.runModal() == .OK ? panel.url : nil
    }
}
struct ImportView: View {
    @Environment(UsageStore.self) private var store
    @State private var source = "cc-switch"
    @State private var preview: ImportPreview?
    @State private var acceptedDates = false
    @State private var acceptedPartial = false
    @State private var choices: [String: String] = [:]
    @State private var busy = false
    @State private var notice: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Picker("格式", selection: $source) { Text("CC Switch").tag("cc-switch"); Text("tokens.ci 快照").tag("tokens-ci") }.frame(width: 250)
                    Button("选择 JSON 文件…") { choose() }.disabled(busy)
                    if busy { ProgressView().controlSize(.small) }
                }
                if let notice { Text(notice).foregroundStyle(.secondary) }
                if let preview {
                    GroupBox("导入预览") {
                        VStack(alignment: .leading, spacing: 14) {
                            Text(preview.tokens.formatted() + " tokens").font(.title2).monospacedDigit()
                            Text("\(preview.start) — \(preview.end) · \(preview.dayCount) 天 · \(preview.rowCount) 条日汇总").foregroundStyle(.secondary)
                            if preview.sourceTimezone == nil { Toggle("保留来源原始日期（来源时区未知）", isOn: $acceptedDates) }
                            if !preview.partialDates.isEmpty { Toggle("接受未完成日期的部分记录：" + preview.partialDates.joined(separator: "、"), isOn: $acceptedPartial) }
                            if !preview.conflicts.isEmpty {
                                Divider()
                                Text("这些日期已有记录，请选择计入总数的来源。两份数据都会保留。")
                                HStack {
                                    Button("全部保留已有") { for c in preview.conflicts { choices[c.id] = "existing" } }
                                    Button("全部使用导入") { for c in preview.conflicts { choices[c.id] = "imported" } }
                                }
                                ForEach(preview.conflicts) { conflict in
                                    HStack {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text("\(conflict.date) · \(clientName(conflict.client))")
                                            Text("已有 \(compactTokens(conflict.existingTokens)) / 导入 \(compactTokens(conflict.incomingTokens)) tokens").font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Picker("有效来源", selection: Binding(get: { choices[conflict.id] ?? "" }, set: { choices[conflict.id] = $0 })) {
                                            Text("请选择").tag(""); Text("已有 · \(conflict.existingSource)").tag("existing"); Text("本次导入").tag("imported")
                                        }.labelsHidden().frame(width: 190)
                                    }
                                }
                            }
                            HStack { Spacer(); Button("确认导入") { apply(preview) }.buttonStyle(.borderedProminent).disabled(busy || (!acceptedDates && preview.sourceTimezone == nil) || (!acceptedPartial && !preview.partialDates.isEmpty) || preview.conflicts.contains { choices[$0.id] == nil }) }
                        }.padding(12)
                    }
                }
                Divider()
                Text("导入批次").font(.headline)
                ForEach(store.sources["batches"].array, id: \.self) { batch in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(batch["preview"]["source"].string ?? "") · \(batch["preview"]["start"].string ?? "") — \(batch["preview"]["end"].string ?? "")")
                            Text("\(compactTokens(batch["preview"]["tokens"].int ?? 0)) tokens · \(batch["active"].bool == true ? "已导入" : "已撤销")").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if batch["active"].bool == true { Button("撤销") { undo(batch["id"].string ?? "") }.disabled(busy) }
                    }.padding(.vertical, 4)
                }
                if store.sources["batches"].array.isEmpty { Text("尚无导入批次").foregroundStyle(.secondary) }
            }.padding(24)
        }.task { await store.loadManagement() }
    }
    private func choose() {
        guard let file = FilePanels.open() else { return }
        busy = true; notice = nil
        Task {
            defer { busy = false }
            do {
                preview = try await store.perform("importPreview", payload: .object(["source": .string(source), "path": .string(file.path)])).decode(ImportPreview.self)
                choices = [:]; acceptedDates = false; acceptedPartial = false
            } catch { store.fail(error) }
        }
    }
    private func apply(_ p: ImportPreview) {
        busy = true
        Task {
            defer { busy = false }
            do {
                let result = try await store.perform("importApply", payload: .object(["id": .string(p.id), "options": .object(["acceptOriginalDates": .bool(acceptedDates), "acceptPartialDates": .bool(acceptedPartial), "resolutions": .object(choices.mapValues(JSONValue.string))])]))
                notice = result["alreadyImported"].bool == true ? "此文件已导入，总数未增加。" : "导入完成。可在总览选择「全部」查看历史。"
                preview = nil; await store.loadManagement(); await store.refresh()
            } catch { store.fail(error) }
        }
    }
    private func undo(_ id: String) {
        busy = true
        Task { defer { busy = false }; do { _ = try await store.perform("importUndo", payload: .object(["id": .string(id)])); await store.loadManagement(); await store.refresh() } catch { store.fail(error) } }
    }
}
struct SourcesView: View {
    @Environment(UsageStore.self) private var store
    @State private var notice: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let scan = store.status?.lastScan {
                    ForEach(scan.sources, id: \.client) { source in
                        GroupBox(clientName(source.client)) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("\(source.status == "ok" ? "采集正常" : source.status == "partial" ? "部分日志待重试" : "未发现日志") · \(source.files) 个文件 · \(source.records) 条记录")
                                ForEach(source.errors, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                        }
                    }
                }
                Text("来源覆盖").font(.headline)
                ForEach(store.sources["coverage"].array, id: \.self) { source in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(clientName(source["client"].string ?? "")) · \(source["source"].string ?? "")")
                            Text("\(source["from"].string ?? "") — \(source["to"].string ?? "")").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            Text("计入 \(compactTokens(source["selectedTokens"].int ?? 0))")
                            Text("已保存 \(compactTokens(source["tokens"].int ?? 0)) tokens").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Divider()
                HStack { Button("导出 JSON…") { export("json") }; Button("导出 CSV…") { export("csv") }; if let notice { Text(notice).foregroundStyle(.secondary) } }
                Text("导出当前筛选下的有效记录，包含来源与计价依据。").font(.caption).foregroundStyle(.secondary)
            }.padding(24)
        }.task { await store.loadManagement() }
    }
    private func export(_ format: String) {
        guard let file = FilePanels.save(name: "Tokenory-\(UsageStore.day(Date())).\(format)") else { return }
        Task { do { _ = try await store.perform("export", payload: .object(["path": .string(file.path), "format": .string(format), "filter": try .encode(store.filter)])); notice = "已导出" } catch { store.fail(error) } }
    }
}
extension JSONValue: Hashable {
    func hash(into hasher: inout Hasher) {
        switch self {
        case .object(let o): hasher.combine(0); for key in o.keys.sorted() { hasher.combine(key); hasher.combine(o[key]) }
        case .array(let a): hasher.combine(1); hasher.combine(a)
        case .string(let s): hasher.combine(2); hasher.combine(s)
        case .integer(let i): hasher.combine(3); hasher.combine(i)
        case .number(let n): hasher.combine(4); hasher.combine(n)
        case .bool(let b): hasher.combine(5); hasher.combine(b)
        case .null: hasher.combine(6)
        }
    }
}
