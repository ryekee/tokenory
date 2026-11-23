// [INPUT]: 接收导入预览、采集状态和来源覆盖记录。
// [OUTPUT]: 提供导入格式切换、预览、来源概览和导出入口。
// [POS]: 设置中的数据页内联导入预览、冲突选择和批次历史；来源页按设备展示用量。
// [PROTOCOL]: Update this header on change, then check AGENTS.md
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
    private struct PendingUndo: Identifiable {
        let id: String
        let source: String
        let dates: String
    }

    @Environment(UsageStore.self) private var store
    @State private var source = "cc-switch"
    @State private var preview: ImportPreview?
    @State private var acceptedDates = false
    @State private var acceptedPartial = false
    @State private var choices: [String: String] = [:]
    @Binding var busy: Bool
    @State private var notice: String?
    @State private var pendingUndo: PendingUndo?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("nav.imports")).font(.headline)
            HStack(spacing: 12) {
                Picker(L("import.format"), selection: $source) {
                    Text("CC Switch").tag("cc-switch")
                    Text(L("import.tokens_ci")).tag("tokens-ci")
                }.pickerStyle(.segmented).fixedSize()
                Button(L("import.choose")) { choose() }
                if busy { ProgressView().controlSize(.small) }
            }
            if let notice { Text(notice).font(.callout).foregroundStyle(.secondary) }
            if let preview {
                Divider()
                previewDetails(preview)
            }
            Divider()
            DisclosureGroup(L("import.batches")) { batchHistory }
        }
        .disabled(busy)
        .onChange(of: source) { _, _ in
            preview = nil
            notice = nil
        }
        .alert(item: $pendingUndo) { batch in
            Alert(title: Text(L("import.confirm_undo")),
                  message: Text(LF("import.undo_scope", batch.source, batch.dates)),
                  primaryButton: .destructive(Text(L("import.undo"))) { undo(batch.id) },
                  secondaryButton: .cancel(Text(L("action.cancel"))))
        }
    }

    private func previewDetails(_ preview: ImportPreview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("import.preview")).font(.headline)
            Text(preview.tokens.formatted(.number.locale(Localization.locale)) + " tokens").font(.title2).monospacedDigit()
            Text(LF("import.summary", Localization.dateRange(preview.start, preview.end), preview.dayCount, preview.rowCount)).foregroundStyle(.secondary)
            if preview.sourceTimezone == nil { Toggle(L("import.keep_dates"), isOn: $acceptedDates) }
            if !preview.partialDates.isEmpty { Toggle(LF("import.partial_dates", preview.partialDates.map(Localization.day).formatted(.list(type: .and).locale(Localization.locale))), isOn: $acceptedPartial) }
            if !preview.conflicts.isEmpty {
                Divider()
                Text(L("import.conflicts"))
                if preview.conflicts.count > 1 {
                    HStack {
                        Button(L("import.keep_all")) { for c in preview.conflicts { choices[c.id] = "existing" } }
                        Button(L("import.replace_all")) { for c in preview.conflicts { choices[c.id] = "imported" } }
                    }
                }
                ForEach(preview.conflicts) { conflict in
                    HStack {
                        BrandIcon(name: conflict.client, kind: .tool)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(clientName(conflict.client)).fontWeight(.medium)
                            Text(Localization.day(conflict.date)).font(.caption).foregroundStyle(.secondary)
                            Text(LF("import.compare", compactTokens(conflict.existingTokens), compactTokens(conflict.incomingTokens))).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .leading, spacing: 2) {
                            sourceChoice(LF("import.existing", conflict.existingSource), value: "existing", id: conflict.id)
                            sourceChoice(L("import.incoming"), value: "imported", id: conflict.id)
                        }.accessibilityElement(children: .contain)
                    }
                }
            }
            HStack {
                Spacer()
                Button(L("action.cancel")) { self.preview = nil }
                Button(L("import.apply")) { apply(preview) }
                    .buttonStyle(.borderedProminent)
                    .disabled((!acceptedDates && preview.sourceTimezone == nil)
                              || (!acceptedPartial && !preview.partialDates.isEmpty)
                              || preview.conflicts.contains { choices[$0.id] == nil })
            }
        }
    }

    private func sourceChoice(_ title: String, value: String, id: String) -> some View {
        let selected = choices[id] == value
        return Button { choices[id] = value } label: {
            Label(title, systemImage: selected ? "largecircle.fill.circle" : "circle")
                .font(.callout)
                .foregroundStyle(selected ? WorkspaceStyle.selection : .primary)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var batchHistory: some View {
        ForEach(store.sources["batches"].array, id: \.self) { batch in
            let source = batch["preview"]["source"].string ?? ""
            let dates = Localization.dateRange(batch["preview"]["start"].string ?? "", batch["preview"]["end"].string ?? "")
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(source)
                    Text(dates).font(.caption).foregroundStyle(.secondary)
                    Text(LF("import.batch_status", compactTokens(batch["preview"]["tokens"].int ?? 0), batch["active"].bool == true ? L("import.active") : L("import.undone"))).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if batch["active"].bool == true, let id = batch["id"].string {
                    Button(L("import.undo")) { pendingUndo = PendingUndo(id: id, source: source, dates: dates) }
                }
            }.padding(.vertical, 4)
        }
        if store.sources != .null && store.sources["batches"].array.isEmpty {
            Text(L("import.no_batches")).foregroundStyle(.secondary)
        }
    }
    private func choose() {
        guard let file = FilePanels.open() else { return }
        busy = true; notice = nil; preview = nil
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
struct LocalSourceGroup: Identifiable {
    let id: String
    let scan: SourceStatus?
    let coverage: [JSONValue]

    var selectedTokens: Int64 { coverage.reduce(0) { $0 + ($1["selectedTokens"].int ?? 0) } }

    static func collect(scan: [SourceStatus], coverage: [JSONValue]) -> [Self] {
        let scans = Dictionary(scan.filter { $0.status != "unavailable" }.map { ($0.client, $0) },
                               uniquingKeysWith: { _, latest in latest })
        let grouped = Dictionary(grouping: coverage, by: { $0["client"].string ?? "" })
        return Set(scans.keys).union(grouped.keys).filter { !$0.isEmpty }.map {
            Self(id: $0, scan: scans[$0], coverage: grouped[$0] ?? [])
        }.sorted {
            if $0.selectedTokens != $1.selectedTokens { return $0.selectedTokens > $1.selectedTokens }
            return clientName($0.id).localizedStandardCompare(clientName($1.id)) == .orderedAscending
        }
    }
}

struct SourcesView: View {
    @Environment(UsageStore.self) private var store
    @State private var notice: String?
    @State private var sourceLoading = true

    private var localGroups: [LocalSourceGroup] {
        LocalSourceGroup.collect(scan: store.status?.lastScan?.sources ?? [], coverage: store.sources["coverage"].array)
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            localDevice
            ForEach(store.cloud.sources) { remoteDevice($0) }
            if store.cloud.sources.isEmpty {
                remoteState
            } else if !store.cloud.enabled {
                Text(L("source.sync_paused")).font(.caption).foregroundStyle(.secondary)
            }
            Divider().padding(.vertical, 4)
            if store.sources != .null { supportedClients }
            exportControls
        }
        .disclosureGroupStyle(WorkspaceDisclosureStyle())
        .task { await loadSources() }
    }

    private var localDevice: some View {
        let groups = localGroups
        return WorkspacePanel {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    deviceHeading(name: store.localDeviceName, detail: L("cloud.overview.local"))
                    Button {
                        store.scan()
                    } label: {
                        Label(L("action.scan"), systemImage: "arrow.clockwise")
                    }
                    .disabled(!store.connected || store.scanning)
                }
                Divider()
                if let error = store.sourcesError {
                    HStack(spacing: 10) {
                        Label(L(store.sources == .null ? "source.load_failed" : "source.refresh_failed"),
                              systemImage: "exclamationmark.circle").help(error)
                        Button(L("action.retry")) { Task { await loadSources() } }.disabled(sourceLoading)
                    }.font(.callout).padding(.vertical, 4)
                } else if store.sources == .null {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(L("usage.loading")).foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                }
                if store.sources != .null && groups.isEmpty {
                    Text(L("source.empty")).foregroundStyle(.secondary).padding(.vertical, 4)
                } else if store.sources != .null {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(groups) { group in
                            localTool(group)
                            if group.id != groups.last?.id { Divider().padding(.vertical, 5) }
                        }
                    }
                }
                if store.sources != .null, store.status?.lastScan == nil {
                    Text(L(store.scanning ? "source.scanning" : "source.scan_pending"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func deviceHeading(name: String, detail: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Label(name, systemImage: "desktopcomputer").font(.headline).lineLimit(1)
                Spacer(minLength: 8)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            VStack(alignment: .leading, spacing: 4) {
                Label(name, systemImage: "desktopcomputer").font(.headline).lineLimit(2)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func localTool(_ group: LocalSourceGroup) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                if let scan = group.scan {
                    Text(LF("source.files", scan.files, scan.records))
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(scan.errors, id: \.self) { error in
                        Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                    }
                }
                if group.coverage.isEmpty {
                    Text(L("source.empty")).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Array(group.coverage.enumerated()), id: \.offset) { _, source in
                    coverageRow(source)
                }
            }.padding(.bottom, 5)
        } label: {
            ViewThatFits(in: .horizontal) {
                localToolLabel(group, horizontal: true)
                localToolLabel(group, horizontal: false)
            }
        }
    }

    @ViewBuilder private func localToolLabel(_ group: LocalSourceGroup, horizontal: Bool) -> some View {
        if horizontal {
            HStack(spacing: 10) {
                BrandLabel(name: group.id, kind: .tool, title: clientName(group.id))
                if let scan = group.scan { scanLabel(scan) }
                Spacer(minLength: 12)
                if !group.coverage.isEmpty { Text(LF("source.counted", compactTokens(group.selectedTokens))).monospacedDigit().foregroundStyle(.secondary) }
            }.font(.callout)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                BrandLabel(name: group.id, kind: .tool, title: clientName(group.id))
                HStack {
                    if let scan = group.scan { scanLabel(scan) }
                    if !group.coverage.isEmpty { Text(LF("source.counted", compactTokens(group.selectedTokens))).monospacedDigit().foregroundStyle(.secondary) }
                }.font(.caption)
            }.font(.callout)
        }
    }

    private func scanLabel(_ scan: SourceStatus) -> some View {
        Text(L(scan.status == "ok" ? "source.ok" : scan.status == "partial" ? "status.partial" : "source.empty"))
            .font(.caption)
            .foregroundStyle(scan.status == "partial" || !scan.errors.isEmpty ? Color.orange : Color.secondary)
    }

    private func coverageRow(_ source: JSONValue) -> some View {
        let sourceName = source["source"].string ?? ""
        let title = sourceName == "local" ? L("source.local") : sourceName == "cc-switch" ? "CC Switch" : sourceName == "tokens-ci" ? "tokens.ci" : sourceName
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                coverageIdentity(title: title, source: source)
                Spacer(minLength: 8)
                coverageTotals(source)
            }
            VStack(alignment: .leading, spacing: 5) {
                coverageIdentity(title: title, source: source)
                coverageTotals(source)
            }
        }
        .padding(.vertical, 3)
    }

    private func coverageIdentity(title: String, source: JSONValue) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.callout)
            Text(Localization.dateRange(source["from"].string ?? "", source["to"].string ?? ""))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func coverageTotals(_ source: JSONValue) -> some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text(LF("source.counted", compactTokens(source["selectedTokens"].int ?? 0)))
            Text(LF("source.saved", compactTokens(source["tokens"].int ?? 0))).foregroundStyle(.secondary)
        }.font(.caption).monospacedDigit()
    }

    private func remoteDevice(_ device: DeviceSourceSummary) -> some View {
        WorkspacePanel {
            VStack(alignment: .leading, spacing: 14) {
                deviceHeading(name: device.name, detail: LF("source.updated", device.updatedAt.formatted(
                    Date.FormatStyle(date: .abbreviated, time: .shortened, locale: Localization.locale))))
                Divider()
                if device.clients.isEmpty {
                    Text(L("source.empty")).foregroundStyle(.secondary).padding(.vertical, 4)
                } else {
                    ForEach(device.clients, id: \.key) { client in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            BrandLabel(name: client.key, kind: .tool, title: clientName(client.key))
                                .lineLimit(2)
                            Spacer(minLength: 8)
                            Text(LF("source.counted", compactTokens(client.summary.tokens))).monospacedDigit()
                        }.font(.callout)
                    }
                }
            }
        }
    }

    @ViewBuilder private var remoteState: some View {
        if let message = store.cloud.message {
            Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        } else if store.cloud.busy && store.cloud.enabled {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L("source.syncing")).font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Text(L(store.cloud.enabled ? "source.no_remote_devices" : "source.sync_off"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var supportedClients: some View {
        DisclosureGroup(LF("source.supported_clients", store.clients.count)) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L("source.local_inputs")).font(.callout).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .leading)], alignment: .leading, spacing: 12) {
                    ForEach(store.clients) { client in
                        BrandLabel(name: client.id, kind: .tool, title: client.name)
                    }
                }
                Text(L("source.wrapper_clients")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var exportControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("export.scope_note")).font(.caption).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                exportScopeRow("field.date", exportDateRange)
                if let client = store.filter.client { exportScopeRow("field.tool", clientName(client)) }
                if let provider = store.filter.provider { exportScopeRow("field.provider", provider) }
                if let model = store.filter.model { exportScopeRow("field.model", model) }
                if let source = store.filter.source { exportScopeRow("field.source", exportSource(source)) }
                if let start = store.filter.timestampFromMs { exportScopeRow("export.time_from", exportTime(start)) }
                if let end = store.filter.timestampToMs { exportScopeRow("export.time_to", exportTime(end)) }
            }
            .font(.caption)
            .textSelection(.enabled)
            HStack {
                Button(L("export.json")) { export("json") }
                Button(L("export.csv")) { export("csv") }
                if let notice { Text(notice).foregroundStyle(.secondary) }
            }
            Text(L("export.note")).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }

    private func exportScopeRow(_ key: String, _ value: String) -> some View {
        GridRow {
            Text(L(key)).foregroundStyle(.secondary)
            Text(value).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var exportDateRange: String {
        switch (store.filter.from, store.filter.to) {
        case let (from?, to?): return Localization.dateRange(from, to)
        case let (from?, nil): return LF("export.date_from", Localization.day(from))
        case let (nil, to?): return LF("export.date_to", Localization.day(to))
        case (nil, nil): return L("range.all")
        }
    }

    private func exportSource(_ source: String) -> String {
        switch source {
        case "local": L("source.local")
        case "cc-switch": "CC Switch"
        case "tokens-ci": "tokens.ci"
        default: source
        }
    }

    private func exportTime(_ milliseconds: Int64) -> String {
        Date(timeIntervalSince1970: Double(milliseconds) / 1000)
            .formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: Localization.locale,
                                        calendar: Localization.reportingCalendar, timeZone: Localization.reportingCalendar.timeZone))
    }

    private func loadSources() async {
        sourceLoading = true
        await store.loadSources()
        sourceLoading = false
    }

    private func export(_ format: String) {
        let filter = store.filter
        guard let file = FilePanels.save(name: "Tokenory-\(UsageStore.day(Date())).\(format)") else { return }
        Task { do { _ = try await store.perform("export", payload: .object(["path": .string(file.path), "format": .string(format), "filter": try .encode(filter)])); notice = L("export.done") } catch { store.fail(error) } }
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
