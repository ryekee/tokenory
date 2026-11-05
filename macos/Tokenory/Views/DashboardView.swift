import SwiftUI
import Charts

private enum DashboardSection: String, CaseIterable {
    case overview, details, imports, sources
    var title: String { L("nav." + rawValue) }
    var icon: String { switch self { case .overview: "chart.bar.xaxis"; case .details: "list.bullet.rectangle"; case .imports: "square.and.arrow.down"; case .sources: "externaldrive" } }
}
struct DashboardView: View {
    @Environment(UsageStore.self) private var store
    @State private var section: DashboardSection = .overview
    @State private var customStart = Date().addingTimeInterval(-29 * 86400)
    @State private var customEnd = Date()
    @State private var metric = "Tokens"
    @State private var selectedDetail: UsageDetail?
    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            List(selection: $section) { ForEach(DashboardSection.allCases, id: \.self) { item in Label(item.title, systemImage: item.icon).tag(item) } }
                .navigationSplitViewColumnWidth(min: 130, ideal: 150, max: 200)
                .safeAreaInset(edge: .bottom) { Text(store.statusText).font(.caption).foregroundStyle(.secondary).padding(16) }
        } detail: {
            VStack(spacing: 0) {
                ErrorBanner().padding(.horizontal, 20)
                if section == .imports { ImportView() }
                else if section == .sources { SourcesView() }
                else {
                    filters.padding(.horizontal, 24).padding(.vertical, 14)
                    Divider()
                    if let report = store.report {
                        if section == .details { details(report) }
                        else { overview(report) }
                    } else { ProgressView(L("usage.loading_stats")).frame(maxWidth: .infinity, maxHeight: .infinity) }
                }
            }.navigationTitle(section.title)
                .toolbar {
                    ToolbarItemGroup {
                        if store.loading { ProgressView().controlSize(.small) }
                        Button { store.scan() } label: { Label(L("action.scan"), systemImage: "arrow.clockwise") }.disabled(store.scanning || !store.connected)
                        if !store.connected { Button(L("action.reconnect")) { store.start() } }
                    }
                }
        }
        .frame(minWidth: 800, minHeight: 560)
        .onChange(of: store.filter) { _, _ in Task { await store.refresh() } }
        .sheet(item: $selectedDetail) { detail in DetailSheet(detail: detail) }
    }
    private var filters: some View {
        @Bindable var store = store
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker(L("field.date"), selection: $store.dateRange) { ForEach(UsageDateRange.allCases, id: \.self) { Text($0.title).tag($0) } }.labelsHidden().frame(width: 130)
                    .onChange(of: store.dateRange) { _, value in
                        store.filter.offset = 0
                        if value == .custom {
                            store.filter.from = UsageStore.day(customStart); store.filter.to = UsageStore.day(customEnd)
                        } else {
                            store.updateDateRange()
                        }
                    }
                if store.dateRange == .custom {
                    DatePicker(L("field.start"), selection: $customStart, displayedComponents: .date).labelsHidden().onChange(of: customStart) { _, d in store.filter.from = UsageStore.day(d); store.filter.offset = 0 }
                    Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                    DatePicker(L("field.end"), selection: $customEnd, displayedComponents: .date).labelsHidden().onChange(of: customEnd) { _, d in store.filter.to = UsageStore.day(d); store.filter.offset = 0 }
                }
                if section == .details {
                    Picker(L("field.source"), selection: Binding(get: { store.filter.source ?? "" }, set: { store.filter.source = $0.isEmpty ? nil : $0; store.filter.offset = 0 })) {
                        Text(L("filter.sources")).tag(""); Text(L("source.local")).tag("local"); Text("CC Switch").tag("cc-switch"); Text("tokens.ci").tag("tokens-ci")
                    }.labelsHidden().frame(width: 140)
                }
                Spacer()
                if section == .details { Text(LF("usage.record_count", store.report?.summary.recordCount ?? 0)).foregroundStyle(.secondary) }
            }
            HStack(spacing: 10) {
                filterPicker(L("filter.tools"), value: $store.filter.client, options: store.catalog?.clients ?? [], clients: true)
                filterPicker(L("filter.providers"), value: $store.filter.provider, options: store.catalog?.providers ?? [])
                filterPicker(L("filter.models"), value: $store.filter.model, options: store.catalog?.models ?? [])
                Spacer(minLength: 0)

            }
        }
    }
    private func filterPicker(_ title: String, value: Binding<String?>, options: [UsageGroup], clients: Bool = false) -> some View {
        Picker(title, selection: Binding(get: { value.wrappedValue ?? "" }, set: { value.wrappedValue = $0.isEmpty ? nil : $0; store.filter.offset = 0 })) {
            Text(title).tag("")
            ForEach(options) { Text(clients ? clientName($0.key) : $0.key).tag($0.key) }
        }.labelsHidden().frame(width: title == L("filter.models") ? 240 : 145, alignment: .leading)
    }
    private func overview(_ report: UsageReport) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                SummaryView(summary: report.summary)
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Text(L("usage.trend")).font(.headline)
                        Spacer()
                        Picker(L("usage.metric"), selection: $metric) { Text(L("usage.tokens")).tag("Tokens"); Text(L("cost.estimate")).tag("Cost") }.labelsHidden().pickerStyle(.segmented).frame(width: 220)
                    }
                    if report.daily.isEmpty { ContentUnavailableView(L("usage.empty"), systemImage: "chart.bar.xaxis").frame(height: 210) }
                    else {
                        Chart(report.daily) { day in
                            if let date = Localization.date(day.key) {
                                if metric == "Tokens" { BarMark(x: .value(L("field.date"), date, unit: .day), y: .value(L("usage.tokens"), day.summary.tokens)).foregroundStyle(Color.accentColor).cornerRadius(2) }
                                else if let cost = day.summary.knownEstimatedCostUsd { BarMark(x: .value(L("field.date"), date, unit: .day), y: .value("USD", cost)).foregroundStyle(Color.accentColor).cornerRadius(2) }
                            }
                        }
                        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) { _ in AxisTick(); AxisValueLabel(format: .dateTime.month(.abbreviated).day().locale(Localization.locale)) } }
                        .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                            AxisValueLabel { if let n = value.as(Double.self) { Text(metric == "Tokens" ? compactTokens(Int64(n)) : usd(n)) } }
                        } }
                        .frame(height: 230)
                    }
                }
                Divider()
                HStack(alignment: .top, spacing: 32) {
                    UsageGroupList(title: L("field.tool"), groups: report.clients, isClient: true)
                    UsageGroupList(title: L("field.model"), groups: report.models)
                }
            }.padding(24)
        }
    }
    private func details(_ report: UsageReport) -> some View {
        VStack(spacing: 0) {
            Table(report.details) {
                TableColumn(L("field.date")) { Text(Localization.day($0.date)) }.width(110)
                TableColumn(L("field.tool")) { Text(clientName($0.client)) }.width(min: 85, ideal: 100)
                TableColumn(L("field.model"), value: \.model).width(min: 120, ideal: 210)
                TableColumn("Tokens") { Text(compactTokens($0.total)).monospacedDigit() }.width(90)
                TableColumn(L("cost.estimate")) { Text(usd($0.estimatedCostUsd, detailed: true)).monospacedDigit() }.width(100)
                TableColumn("") { row in Button { selectedDetail = row } label: { Image(systemName: "info.circle") }.buttonStyle(.plain).accessibilityLabel(L("action.record_details")) }.width(25)
            }
            HStack {
                Button(L("action.previous")) { store.filter.offset = max(0, store.filter.offset - store.filter.limit) }.disabled(store.filter.offset == 0)
                Text("\(store.filter.offset / store.filter.limit + 1)").monospacedDigit()
                Button(L("action.next")) { store.filter.offset += store.filter.limit }.disabled(store.filter.offset + report.details.count >= Int(report.summary.recordCount))
                Spacer()
                Text(L("record.daily_note")).font(.caption).foregroundStyle(.secondary)
            }.padding(12)
        }
    }
}
struct DetailSheet: View {
    @Environment(UsageStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let detail: UsageDetail
    @State private var price = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(detail.model).font(.title2).textSelection(.enabled)
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 10) {
                row(L("field.date"), Localization.day(detail.date)); row(L("field.tool_provider"), "\(clientName(detail.client)) / \(detail.provider)")
                row(L("field.source"), detail.source); row(L("token.input"), detail.tokens.input.formatted(.number.locale(Localization.locale))); row(L("token.output"), detail.tokens.output.formatted(.number.locale(Localization.locale))); row(L("token.cache_read"), detail.tokens.cacheRead.formatted(.number.locale(Localization.locale))); row(L("token.cache_write"), detail.tokens.cacheWrite.formatted(.number.locale(Localization.locale))); row(L("token.reasoning"), detail.tokens.reasoning.formatted(.number.locale(Localization.locale)))
                row(L("cost.estimate"), usd(detail.estimatedCostUsd, detailed: true)); row(L("field.source_cost"), detail.sourceCostUsd.map { usd($0, detailed: true) } ?? L("value.unavailable"))
                if let session = detail.sessionId { row(L("field.session"), session) }
                row(L("field.date_basis"), detail.timezone ?? L("value.unknown_timezone"))
            }
            if let basis = detail.costBasis { DisclosureGroup(L("cost.calculation")) { Text(basis).font(.caption).textSelection(.enabled).foregroundStyle(.secondary) } }
            if !price.isEmpty { DisclosureGroup(L("price.snapshot")) { ScrollView { Text(price).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }.frame(maxHeight: 180) } }
            HStack { Spacer(); Button(L("action.done")) { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 600)
            .task {
                guard let id = detail.priceSnapshotId else { return }
                do { let value = try await store.perform("priceSnapshot", payload: .object(["id": .string(id)])); let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; price = String(decoding: try encoder.encode(value), as: UTF8.self) } catch { store.fail(error) }
            }
    }
    private func row(_ title: String, _ value: String) -> some View { GridRow { Text(title).foregroundStyle(.secondary); Text(value).textSelection(.enabled) } }
}
