import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
enum FilePanels {
    static func open(types: [UTType] = [.json]) -> URL? {
        let panel = NSOpenPanel(); panel.prompt = L("panel.open"); panel.allowedContentTypes = types; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
    static func save(name: String) -> URL? {
        let panel = NSSavePanel(); panel.prompt = L("panel.save"); panel.nameFieldStringValue = name
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
                    Picker(L("import.format"), selection: $source) { Text("CC Switch").tag("cc-switch"); Text(L("import.tokens_ci")).tag("tokens-ci") }.frame(width: 250)
                    Button(L("import.choose")) { choose() }.disabled(busy)
                    if busy { ProgressView().controlSize(.small) }
                }
                if let notice { Text(notice).foregroundStyle(.secondary) }
                if let preview {
                    GroupBox(L("import.preview")) {
                        VStack(alignment: .leading, spacing: 14) {
                            Text(preview.tokens.formatted(.number.locale(Localization.locale)) + " tokens").font(.title2).monospacedDigit()
                            Text(LF("import.summary", Localization.dateRange(preview.start, preview.end), preview.dayCount, preview.rowCount)).foregroundStyle(.secondary)
                            if preview.sourceTimezone == nil { Toggle(L("import.keep_dates"), isOn: $acceptedDates) }
                            if !preview.partialDates.isEmpty { Toggle(LF("import.partial_dates", preview.partialDates.map(Localization.day).formatted(.list(type: .and).locale(Localization.locale))), isOn: $acceptedPartial) }
                            if !preview.conflicts.isEmpty {
                                Divider()
                                Text(L("import.conflicts"))
                                HStack {
                                    Button(L("import.keep_all")) { for c in preview.conflicts { choices[c.id] = "existing" } }
                                    Button(L("import.replace_all")) { for c in preview.conflicts { choices[c.id] = "imported" } }
                                }
                                ForEach(preview.conflicts) { conflict in
                                    HStack {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text("\(conflict.date) · \(clientName(conflict.client))")
                                            Text(LF("import.compare", compactTokens(conflict.existingTokens), compactTokens(conflict.incomingTokens))).font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Picker(L("import.source"), selection: Binding(get: { choices[conflict.id] ?? "" }, set: { choices[conflict.id] = $0 })) {
                                            Text(L("import.select")).tag(""); Text(LF("import.existing", conflict.existingSource)).tag("existing"); Text(L("import.incoming")).tag("imported")
                                        }.labelsHidden().frame(width: 190)
                                    }
                                }
                            }
                            HStack { Spacer(); Button(L("import.apply")) { apply(preview) }.buttonStyle(.borderedProminent).disabled(busy || (!acceptedDates && preview.sourceTimezone == nil) || (!acceptedPartial && !preview.partialDates.isEmpty) || preview.conflicts.contains { choices[$0.id] == nil }) }
                        }.padding(12)
                    }
                }
                Divider()
                Text(L("import.batches")).font(.headline)
                ForEach(store.sources["batches"].array, id: \.self) { batch in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(batch["preview"]["source"].string ?? "") · \(Localization.dateRange(batch["preview"]["start"].string ?? "", batch["preview"]["end"].string ?? ""))")
                            Text(LF("import.batch_status", compactTokens(batch["preview"]["tokens"].int ?? 0), batch["active"].bool == true ? L("import.active") : L("import.undone"))).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if batch["active"].bool == true { Button(L("import.undo")) { undo(batch["id"].string ?? "") }.disabled(busy) }
                    }.padding(.vertical, 4)
                }
                if store.sources["batches"].array.isEmpty { Text(L("import.no_batches")).foregroundStyle(.secondary) }
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
                notice = result["alreadyImported"].bool == true ? L("import.duplicate") : L("import.complete")
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
                                Text(source.status == "ok" ? L("source.ok") : source.status == "partial" ? L("status.partial") : L("source.empty"))
                                Text(LF("source.files", source.files, source.records)).font(.caption).foregroundStyle(.secondary)
                                ForEach(source.errors, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                        }
                    }
                }
                Text(L("source.coverage")).font(.headline)
                ForEach(store.sources["coverage"].array, id: \.self) { source in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(clientName(source["client"].string ?? "")) · \(source["source"].string ?? "")")
                            Text(Localization.dateRange(source["from"].string ?? "", source["to"].string ?? "")).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(LF("source.counted", compactTokens(source["selectedTokens"].int ?? 0)))
                            Text(LF("source.saved", compactTokens(source["tokens"].int ?? 0))).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Divider()
                HStack { Button(L("export.json")) { export("json") }; Button(L("export.csv")) { export("csv") }; if let notice { Text(notice).foregroundStyle(.secondary) } }
                Text(L("export.note")).font(.caption).foregroundStyle(.secondary)
            }.padding(24)
        }.task { await store.loadManagement() }
    }
    private func export(_ format: String) {
        guard let file = FilePanels.save(name: "Tokenory-\(UsageStore.day(Date())).\(format)") else { return }
        Task { do { _ = try await store.perform("export", payload: .object(["path": .string(file.path), "format": .string(format), "filter": try .encode(store.filter)])); notice = L("export.done") } catch { store.fail(error) } }
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
