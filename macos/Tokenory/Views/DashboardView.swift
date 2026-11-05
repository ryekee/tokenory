import SwiftUI
import Charts

struct DashboardView: View {
    @Environment(UsageStore.self) private var store
    @State private var section = "总览"
    @State private var customStart = Date().addingTimeInterval(-29 * 86400)
    @State private var customEnd = Date()
    @State private var metric = "Tokens"
    @State private var selectedDetail: UsageDetail?
    private let sections = [("总览", "chart.bar.xaxis"), ("明细", "list.bullet.rectangle"), ("导入", "square.and.arrow.down"), ("来源", "externaldrive")]
    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            List(selection: $section) { ForEach(sections, id: \.0) { item in Label(item.0, systemImage: item.1).tag(item.0) } }
                .navigationSplitViewColumnWidth(min: 130, ideal: 150, max: 200)
                .safeAreaInset(edge: .bottom) { Text(store.statusText).font(.caption).foregroundStyle(.secondary).padding(16) }
        } detail: {
            VStack(spacing: 0) {
                ErrorBanner().padding(.horizontal, 20)
                if section == "导入" { ImportView() }
                else if section == "来源" { SourcesView() }
                else {
                    filters.padding(20)
                    Divider()
                    if let report = store.report {
                        if section == "明细" { details(report) }
                        else { overview(report) }
                    } else { ProgressView("正在读取统计…").frame(maxWidth: .infinity, maxHeight: .infinity) }
                }
            }.navigationTitle(section)
                .toolbar {
                    ToolbarItemGroup {
                        if store.loading { ProgressView().controlSize(.small) }
                        Button { store.scan() } label: { Label("立即扫描", systemImage: "arrow.clockwise") }.disabled(store.scanning || !store.connected)
                        if !store.connected { Button("重试连接") { store.start() } }
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
                Picker("日期", selection: $store.dateRange) { ForEach(UsageDateRange.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width: 130)
                    .onChange(of: store.dateRange) { _, value in
                        store.filter.offset = 0
                        if value == .custom {
                            store.filter.from = UsageStore.day(customStart); store.filter.to = UsageStore.day(customEnd)
                        } else {
                            store.updateDateRange()
                        }
                    }
                if store.dateRange == .custom {
                    DatePicker("起始", selection: $customStart, displayedComponents: .date).labelsHidden().onChange(of: customStart) { _, d in store.filter.from = UsageStore.day(d); store.filter.offset = 0 }
                    Text("—").foregroundStyle(.secondary)
                    DatePicker("结束", selection: $customEnd, displayedComponents: .date).labelsHidden().onChange(of: customEnd) { _, d in store.filter.to = UsageStore.day(d); store.filter.offset = 0 }
                }
                Spacer()
                if section == "明细" { Text("\(store.report?.summary.recordCount ?? 0) 条记录").foregroundStyle(.secondary) }
            }
            HStack {
                filterPicker("所有工具", value: $store.filter.client, options: store.catalog?.clients ?? [], clients: true)
                filterPicker("所有提供方", value: $store.filter.provider, options: store.catalog?.providers ?? [])
                filterPicker("所有模型", value: $store.filter.model, options: store.catalog?.models ?? [])
                if section == "明细" {
                    Picker("来源", selection: Binding(get: { store.filter.source ?? "" }, set: { store.filter.source = $0.isEmpty ? nil : $0; store.filter.offset = 0 })) {
                        Text("所有来源").tag(""); Text("本地日志").tag("local"); Text("CC Switch").tag("cc-switch"); Text("tokens.ci").tag("tokens-ci")
                    }.labelsHidden()
                }
            }
        }
    }
    private func filterPicker(_ title: String, value: Binding<String?>, options: [UsageGroup], clients: Bool = false) -> some View {
        Picker(title, selection: Binding(get: { value.wrappedValue ?? "" }, set: { value.wrappedValue = $0.isEmpty ? nil : $0; store.filter.offset = 0 })) {
            Text(title).tag("")
            ForEach(options) { Text(clients ? clientName($0.key) : $0.key).tag($0.key) }
        }.labelsHidden().frame(maxWidth: .infinity)
    }
    private func overview(_ report: UsageReport) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SummaryView(summary: report.summary)
                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        Picker("趋势指标", selection: $metric) { Text("Tokens").tag("Tokens"); Text("API 估算").tag("Cost") }.pickerStyle(.segmented).frame(width: 200)
                        if report.daily.isEmpty { ContentUnavailableView("此范围暂无记录", systemImage: "chart.bar.xaxis").frame(height: 190) }
                        else {
                            Chart(report.daily) { day in
                                if metric == "Tokens" { BarMark(x: .value("日期", day.key), y: .value("Tokens", day.summary.tokens)).foregroundStyle(Color.accentColor.gradient) }
                                else if let cost = day.summary.knownEstimatedCostUsd { BarMark(x: .value("日期", day.key), y: .value("USD", cost)).foregroundStyle(Color.teal.gradient) }
                            }.chartXAxis { AxisMarks(values: .automatic(desiredCount: 6)) }.frame(height: 210)
                        }
                    }.padding(12)
                }
                HStack(alignment: .top, spacing: 16) {
                    UsageGroupList(title: "工具", groups: report.clients, isClient: true)
                    UsageGroupList(title: "模型", groups: report.models)
                }
            }.padding(24)
        }
    }
    private func details(_ report: UsageReport) -> some View {
        VStack(spacing: 0) {
            Table(report.details) {
                TableColumn("日期", value: \.date).width(90)
                TableColumn("工具") { Text(clientName($0.client)) }.width(min: 85, ideal: 100)
                TableColumn("模型", value: \.model).width(min: 120, ideal: 210)
                TableColumn("Tokens") { Text(compactTokens($0.total)).monospacedDigit() }.width(90)
                TableColumn("API 估算") { Text(usd($0.estimatedCostUsd)).monospacedDigit() }.width(100)
                TableColumn("") { row in Button { selectedDetail = row } label: { Image(systemName: "info.circle") }.buttonStyle(.plain).accessibilityLabel("查看记录详情") }.width(25)
            }
            HStack {
                Button("上一页") { store.filter.offset = max(0, store.filter.offset - store.filter.limit) }.disabled(store.filter.offset == 0)
                Text("\(store.filter.offset / store.filter.limit + 1)").monospacedDigit()
                Button("下一页") { store.filter.offset += store.filter.limit }.disabled(store.filter.offset + report.details.count >= Int(report.summary.recordCount))
                Spacer()
                Text("日汇总保留原粒度").font(.caption).foregroundStyle(.secondary)
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
                row("日期", detail.date); row("工具 / 提供方", "\(clientName(detail.client)) / \(detail.provider)")
                row("来源", detail.source); row("新输入", detail.tokens.input.formatted()); row("输出", detail.tokens.output.formatted()); row("缓存读取", detail.tokens.cacheRead.formatted()); row("缓存写入", detail.tokens.cacheWrite.formatted()); row("Reasoning", detail.tokens.reasoning.formatted())
                row("API 估算", usd(detail.estimatedCostUsd)); row("源成本", detail.sourceCostUsd.map { usd($0) } ?? "未提供")
                if let session = detail.sessionId { row("会话", session) }
                row("日期口径", detail.timezone ?? "来源原始日期；时区未知")
            }
            if let basis = detail.costBasis { Text(basis).font(.caption).textSelection(.enabled).foregroundStyle(.secondary) }
            if !price.isEmpty { DisclosureGroup("价格快照") { ScrollView { Text(price).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }.frame(maxHeight: 180) } }
            HStack { Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 600)
            .task {
                guard let id = detail.priceSnapshotId else { return }
                do { let value = try await store.perform("priceSnapshot", payload: .object(["id": .string(id)])); let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; price = String(decoding: try encoder.encode(value), as: UTF8.self) } catch { store.fail(error) }
            }
    }
    private func row(_ title: String, _ value: String) -> some View { GridRow { Text(title).foregroundStyle(.secondary); Text(value).textSelection(.enabled) } }
}
