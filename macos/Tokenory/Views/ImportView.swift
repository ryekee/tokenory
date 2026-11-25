// [INPUT]: 接收导入预览、采集状态和来源覆盖记录。
// [OUTPUT]: 自动识别导入格式，预览和提交结果留在卡片内；按设备展示来源，提供 JSON 或 CSV 导出。
// [POS]: 设置中的数据页内联导入预览、冲突选择和批次历史；来源页按设备展示用量。
// [PROTOCOL]: Update this header on change, then check AGENTS.md
import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

private func sourceDisplayName(_ source: String) -> String {
    switch source {
    case "local": L("source.local")
    case "cc-switch": "CC Switch"
    case "tokens-ci": "tokens.ci"
    default: source
    }
}

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
@MainActor @Observable
final class ImportDraft {
    enum Operation {
        case preview, apply, undo

        var failureTitle: String {
            switch self {
            case .preview: L("import.preview_failed")
            case .apply: L("import.apply_failed")
            case .undo: L("import.undo_failed")
            }
        }
    }

    var preview: ImportPreview?
    var previewFile: URL?
    var acceptedDates = false
    var acceptedPartial = false
    var choices: [String: String] = [:]
    var operation: Operation?
    var failure: (operation: Operation, detail: String)?
    var notice: String?

    var busy: Bool { operation != nil }
}

struct ImportView: View {
    private struct PendingUndo {
        let id: String
        let source: String
        let dates: String
    }

    @Environment(UsageStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var draft: ImportDraft
    @State private var pendingUndo: PendingUndo?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Text(L("nav.imports")).font(.headline)
                Spacer()
                ProgressView().controlSize(.small)
                    .frame(width: 16, height: 16)
                    .opacity(draft.operation == .preview || draft.operation == .undo ? 1 : 0)
                    .accessibilityHidden(!(draft.operation == .preview || draft.operation == .undo))
                Button(L("import.choose"), action: choose).settingsActionForeground().fixedSize()
            }
            if let notice = draft.notice {
                Label(notice, systemImage: "checkmark.circle").font(.callout).foregroundStyle(.secondary)
                    .transition(.opacity)
            }
            if let failure = draft.failure, failure.operation != .apply {
                WorkspaceErrorMessage(title: failure.operation.failureTitle,
                                      note: failure.operation == .preview ? L("import.formats_hint") : nil,
                                      detail: failure.detail) {}
                    .transition(.opacity)
            }
            if let preview = draft.preview {
                VStack(alignment: .leading, spacing: 14) {
                    Divider()
                    previewDetails(preview)
                }
                .transition(.opacity)
            }
            if !store.sources["batches"].array.isEmpty {
                Divider()
                DisclosureGroup(L("import.batches")) { batchHistory }
            }
        }
        .clipped()
        .animation(DashboardMotion.animation(DashboardMotion.panel, reduceMotion: reduceMotion), value: draft.notice)
        .animation(DashboardMotion.animation(DashboardMotion.panel, reduceMotion: reduceMotion), value: draft.failure != nil)
        .animation(DashboardMotion.animation(DashboardMotion.panel, reduceMotion: reduceMotion), value: draft.preview != nil)
        .disabled(draft.busy)
        .alert(L("import.confirm_undo"), isPresented: Binding(
            get: { pendingUndo != nil },
            set: { if !$0 { pendingUndo = nil } }
        ), presenting: pendingUndo) { batch in
            Button(L("action.cancel"), role: .cancel) {}.keyboardShortcut(.defaultAction)
            Button(L("import.undo"), role: .destructive) { undo(batch.id) }
        } message: { batch in
            Text(LF("import.undo_scope", batch.source, batch.dates))
        }
    }

    private func previewDetails(_ preview: ImportPreview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("import.preview")).font(.headline)
                Spacer()
                Text(sourceDisplayName(preview.source)).font(.caption).foregroundStyle(.secondary)
            }
            if let file = draft.previewFile {
                Text(verbatim: file.lastPathComponent)
                    .font(.callout).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Text("\(Text(preview.tokens.formatted(.number.locale(Localization.locale))).font(DisplayNumberFont.font(for: .title2))) tokens")
                .font(.title2)
            Text(LF("import.summary", Localization.dateRange(preview.start, preview.end), preview.dayCount, preview.rowCount))
                .font(.callout).foregroundStyle(.secondary)
            if preview.sourceTimezone == nil {
                Toggle(L("import.keep_dates"), isOn: $draft.acceptedDates).toggleStyle(.checkbox).controlSize(.small)
            }
            if !preview.partialDates.isEmpty {
                Toggle(LF("import.partial_dates", preview.partialDates.map(Localization.day).formatted(.list(type: .and).locale(Localization.locale))), isOn: $draft.acceptedPartial)
                    .toggleStyle(.checkbox).controlSize(.small)
            }
            if !preview.conflicts.isEmpty {
                Divider()
                Text(L("import.conflicts"))
                if preview.conflicts.count > 1 {
                    HStack {
                        Button(L("import.keep_all")) { for c in preview.conflicts { draft.choices[c.id] = "existing" } }
                            .settingsActionForeground()
                        Button(L("import.replace_all")) { for c in preview.conflicts { draft.choices[c.id] = "imported" } }
                            .settingsActionForeground()
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
                            sourceChoice(LF("import.existing", sourceDisplayName(conflict.existingSource)), value: "existing", id: conflict.id)
                            sourceChoice(L("import.incoming"), value: "imported", id: conflict.id)
                        }.accessibilityElement(children: .contain)
                    }
                }
            }
            if let failure = draft.failure, failure.operation == .apply {
                WorkspaceErrorMessage(title: failure.operation.failureTitle, detail: failure.detail) {
                    if let file = draft.previewFile {
                        Button(L("import.preview")) { readPreview(file) }.settingsActionForeground()
                    }
                }
                .transition(.opacity)
            }
            HStack(spacing: 8) {
                Spacer()
                Button(L("action.cancel")) { draft.preview = nil; draft.previewFile = nil; draft.failure = nil }
                    .settingsActionForeground()
                ProgressView().controlSize(.small)
                    .frame(width: 16, height: 16)
                    .opacity(draft.operation == .apply ? 1 : 0)
                    .accessibilityHidden(draft.operation != .apply)
                Button(L("import.apply")) { apply(preview) }
                    .buttonStyle(.borderedProminent)
                    .disabled((!draft.acceptedDates && preview.sourceTimezone == nil)
                              || (!draft.acceptedPartial && !preview.partialDates.isEmpty))
            }
        }
    }

    private func sourceChoice(_ title: String, value: String, id: String) -> some View {
        let selected = draft.choices[id] == value
        return Button { draft.choices[id] = value } label: {
            HStack(spacing: 6) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                Text(title)
            }
            .font(.callout)
            .foregroundStyle(selected ? WorkspaceStyle.selection : .primary)
            .animation(DashboardMotion.animation(DashboardMotion.state, reduceMotion: reduceMotion), value: selected)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(WorkspaceHoverStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var batchHistory: some View {
        ForEach(store.sources["batches"].array, id: \.self) { batch in
            let source = sourceDisplayName(batch["preview"]["source"].string ?? "")
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
                        .settingsActionForeground()
                }
            }.padding(.vertical, 4)
        }
    }

    private func choose() {
        guard !draft.busy, let file = FilePanels.open() else { return }
        readPreview(file)
    }

    private func readPreview(_ file: URL) {
        guard !draft.busy else { return }
        draft.operation = .preview; draft.notice = nil; draft.failure = nil
        draft.preview = nil; draft.previewFile = nil
        draft.choices = [:]; draft.acceptedDates = false; draft.acceptedPartial = false
        Task {
            defer { draft.operation = nil }
            do {
                let preview = try await store.perform("importPreview", payload: .object(["source": .string("auto"), "path": .string(file.path)])).decode(ImportPreview.self)
                draft.preview = preview
                draft.previewFile = file
                draft.choices = Dictionary(uniqueKeysWithValues: preview.conflicts.map { ($0.id, "existing") })
            } catch {
                draft.failure = (.preview, file.lastPathComponent + "\n" + error.localizedDescription)
            }
        }
    }
    private func apply(_ p: ImportPreview) {
        guard !draft.busy else { return }
        draft.operation = .apply; draft.notice = nil; draft.failure = nil
        Task {
            defer { draft.operation = nil }
            do {
                let result = try await store.perform("importApply", payload: .object(["id": .string(p.id), "options": .object([
                    "acceptOriginalDates": .bool(draft.acceptedDates), "acceptPartialDates": .bool(draft.acceptedPartial),
                    "resolutions": .object(draft.choices.mapValues(JSONValue.string))
                ])]))
                await store.loadManagement(notifyOnFailure: false)
                await store.refresh()
                draft.notice = result["alreadyImported"].bool == true ? L("import.duplicate") : L("import.complete")
                draft.preview = nil; draft.previewFile = nil
            } catch {
                draft.failure = (.apply, error.localizedDescription)
            }
        }
    }
    private func undo(_ id: String) {
        guard !draft.busy else { return }
        draft.operation = .undo; draft.notice = nil; draft.failure = nil
        Task {
            defer { draft.operation = nil }
            do {
                _ = try await store.perform("importUndo", payload: .object(["id": .string(id)]))
                await store.loadManagement(notifyOnFailure: false)
                await store.refresh()
                draft.notice = L("import.undo_complete")
            } catch {
                draft.failure = (.undo, error.localizedDescription)
            }
        }
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

@MainActor @Observable
final class SourceExportState {
    var inProgress = false
    var notice: String?
    var failure: String?
}

struct SourcesView: View {
    @Environment(UsageStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let exportState: SourceExportState
    let exportAllowed: Bool
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
            if store.sources != .null { WorkspacePanel { supportedClients } }
            WorkspacePanel { exportControls }
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
                        ZStack {
                            Label(L("action.scan"), systemImage: "arrow.clockwise").hidden()
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text(L("status.scanning"))
                            }.hidden()
                            if store.scanInProgress {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text(L("status.scanning"))
                                }
                            } else {
                                Label(L("action.scan"), systemImage: "arrow.clockwise")
                            }
                        }
                        .animation(DashboardMotion.animation(DashboardMotion.state, reduceMotion: reduceMotion), value: store.scanInProgress)
                    }
                    .settingsActionForeground().disabled(!store.connected || store.scanInProgress)
                }
                Divider()
                if let error = store.sourcesError {
                    WorkspaceErrorMessage(
                        title: L(store.sources == .null ? "source.load_failed" : "source.refresh_failed"),
                        detail: error
                    ) {
                        Button(L("action.retry")) { Task { await loadSources() } }
                            .settingsActionForeground().disabled(sourceLoading)
                    }
                    .transition(.opacity)
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
                if store.sources != .null, store.status?.lastScan == nil, !store.scanInProgress {
                    Text(L("source.scan_pending"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .clipped()
            .animation(DashboardMotion.animation(DashboardMotion.panel, reduceMotion: reduceMotion), value: store.sourcesError != nil)
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
                        Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
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
            .foregroundStyle(scan.status == "partial" || !scan.errors.isEmpty ? WorkspaceStyle.warning : Color.secondary)
    }

    private func coverageRow(_ source: JSONValue) -> some View {
        let sourceName = source["source"].string ?? ""
        let title = sourceDisplayName(sourceName)
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
                            Text(LF("source.counted", compactTokens(client.summary.tokens)))
                                .monospacedDigit().foregroundStyle(.secondary)
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L("export.scope_note")).foregroundStyle(.secondary)
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                        exportScopeRow("field.date", exportDateRange)
                        if let client = store.filter.client { exportScopeRow("field.tool", clientName(client)) }
                        if let provider = store.filter.provider { exportScopeRow("field.provider", provider) }
                        if let model = store.filter.model { exportScopeRow("field.model", model) }
                        if let source = store.filter.source { exportScopeRow("field.source", sourceDisplayName(source)) }
                        if let start = store.filter.timestampFromMs { exportScopeRow("export.time_from", exportTime(start)) }
                        if let end = store.filter.timestampToMs { exportScopeRow("export.time_to", exportTime(end)) }
                    }
                    .textSelection(.enabled)
                    Text(L("export.note")).foregroundStyle(.secondary)
                }
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                        .frame(width: 16, height: 16)
                        .opacity(exportState.inProgress ? 1 : 0)
                        .accessibilityHidden(!exportState.inProgress)
                    Menu(L("export.action")) {
                        Button("JSON") { export("json") }
                        Button("CSV") { export("csv") }
                    }
                    .settingsActionForeground().fixedSize().disabled(!exportAllowed || !store.connected)
                }
            }
            if let failure = exportState.failure {
                WorkspaceErrorMessage(title: L("export.failed"), detail: failure) {}
                    .transition(.opacity)
            } else if let notice = exportState.notice {
                Label(notice, systemImage: "checkmark.circle").font(.callout).foregroundStyle(.secondary)
                    .transition(.opacity)
            }
        }
        .clipped()
        .animation(DashboardMotion.animation(DashboardMotion.panel, reduceMotion: reduceMotion), value: exportState.failure != nil)
        .animation(DashboardMotion.animation(DashboardMotion.panel, reduceMotion: reduceMotion), value: exportState.notice)
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
        guard exportAllowed, !exportState.inProgress else { return }
        let filter = store.filter
        guard let file = FilePanels.save(name: "Tokenory-\(UsageStore.day(Date())).\(format)") else { return }
        exportState.inProgress = true; exportState.notice = nil; exportState.failure = nil
        Task {
            defer { exportState.inProgress = false }
            do {
                _ = try await store.perform("export", payload: .object([
                    "path": .string(file.path), "format": .string(format), "filter": try .encode(filter)
                ]))
                exportState.notice = L("export.done")
            } catch {
                exportState.failure = error.localizedDescription
            }
        }
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
