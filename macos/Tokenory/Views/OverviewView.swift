// [INPUT]: Selected-range and annual reports for this Mac and participating devices.
// [OUTPUT]: Rolling totals, independent Codex subagent card, rankings, range charts, and annual activity.
// [POS]: Native overview composition; disclosure keeps detailed caveats off the canvas.
// [PROTOCOL]: Update this header on change, then check AGENTS.md
import SwiftUI

private struct CodexSubagentsView: View {
    let report: CodexSubagentReport
    let local: CodexSubagentReport?
    let hasRemote: Bool
    let remote: [CodexSubagentReport]
    let codexSummary: UsageSummary?
    @Environment(\.colorScheme) private var colorScheme
    private let metricFont = Font.title3.weight(.medium).monospacedDigit()

    private var tokensShare: Double? {
        subagentShare(Double(report.tokens), of: codexSummary.map { Double($0.tokens) })
    }
    private var costShare: Double? {
        subagentShare(report.cost?.knownEstimatedCostUsd, of: codexSummary?.knownEstimatedCostUsd)
    }
    private var partialCost: Bool {
        (report.cost?.unpricedTokens ?? 0) > 0 || (codexSummary?.unpricedTokens ?? 0) > 0
    }

    var body: some View {
        WorkspacePanel {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(L("subagents.title")).font(.headline).foregroundStyle(WorkspaceStyle.text)
                    Spacer()
                    if hasRemote { OverviewDeviceLegend() }
                    WorkspaceInfoPopover(title: L("subagents.basis")) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L("subagents.count_help"))
                            Text(L("subagents.tokens_help"))
                            Text(L("subagents.cost_help"))
                            Text(L("subagents.conversations_help"))
                        }
                        .padding(16)
                        .frame(width: 290, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 28) {
                        startedMetric
                        summaryMetrics
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        startedMetric
                        summaryMetrics
                    }
                }
                if let local, !local.conversations.isEmpty {
                    Divider()
                    DisclosureGroup(L("subagents.conversations")) {
                        VStack(spacing: 0) {
                            ForEach(local.conversations) { conversation in
                                CodexSubagentConversationView(
                                    conversation: conversation,
                                    totalTokens: local.tokens,
                                    totalCost: local.cost
                                )
                            }
                        }
                    }
                    .disclosureGroupStyle(WorkspaceDisclosureStyle())
                }
            }
        }
    }

    private var startedMetric: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L("subagents.started")).font(.caption).foregroundStyle(WorkspaceStyle.subtext)
            Text(report.starts.formatted(.number.locale(Localization.locale)))
                .font(metricFont)
            if hasRemote {
                OverviewShareBar(total: Double(report.starts), amount: Double(report.starts),
                                 other: remote.reduce(0) { $0 + Double($1.starts) })
                    .frame(width: 86)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var summaryMetrics: some View {
        HStack(alignment: .top, spacing: 24) {
            shareMetric(
                title: L("usage.tokens"),
                value: report.tokens.formatted(.number.locale(Localization.locale)),
                share: tokensShare,
                otherShare: subagentShare(remote.reduce(0) { $0 + Double($1.tokens) }, of: codexSummary.map { Double($0.tokens) }),
                partial: false,
                color: WorkspaceStyle.localUsage
            )
            shareMetric(
                title: L("cost.estimate"),
                value: subagentCostText(report.cost),
                share: costShare,
                otherShare: subagentShare(remote.compactMap { $0.cost?.knownEstimatedCostUsd }.reduce(0, +),
                                          of: codexSummary?.knownEstimatedCostUsd),
                partial: partialCost,
                color: WorkspaceStyle.costColor(colorScheme)
            )
        }
    }

    private func shareMetric(title: String, value: String, share: Double?, otherShare: Double?, partial: Bool, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(WorkspaceStyle.subtext)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(value)
                    .font(metricFont)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 2)
                Text(subagentShareText(share, partial: partial))
                    .font(.caption)
                    .foregroundStyle(WorkspaceStyle.subtext)
                    .monospacedDigit()
            }
            if hasRemote {
                OverviewShareBar(total: 1, amount: share ?? 0, other: otherShare ?? 0)
            } else {
                SubagentShareBar(share: share, color: color)
            }
        }
        .frame(minWidth: 165, maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private func subagentShare(_ amount: Double?, of total: Double?) -> Double? {
    guard let amount, let total, amount.isFinite, total.isFinite, total > 0 else { return nil }
    return amount / total
}

private func subagentShareText(_ share: Double?, partial: Bool = false) -> String {
    guard let share else { return "—" }
    let value = share.formatted(.percent.precision(.fractionLength(0...1)).locale(Localization.locale))
    return partial ? "≈" + value : value
}

private func subagentCostText(_ cost: CodexSubagentCost?) -> String {
    guard let cost, let value = cost.knownEstimatedCostUsd else { return "—" }
    return (cost.unpricedTokens > 0 ? "≈" : "") + usd(value)
}

private struct SubagentShareBar: View {
    let share: Double?
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(color.opacity(0.08))
                if let share {
                    Capsule().fill(color.opacity(0.7))
                        .frame(width: geometry.size.width * min(max(share, 0), 1))
                }
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

private struct CodexSubagentConversationView: View {
    let conversation: CodexSubagentConversation
    let totalTokens: Int64
    let totalCost: CodexSubagentCost?
    @Environment(\.colorScheme) private var colorScheme

    private var title: String {
        if let title = conversation.title, !title.isEmpty { return title }
        return LF("subagents.untitled", String(conversation.id.prefix(8)))
    }

    private var tokensShare: Double? {
        subagentShare(Double(conversation.tokens), of: Double(totalTokens))
    }

    private var costShare: Double? {
        subagentShare(conversation.cost?.knownEstimatedCostUsd, of: totalCost?.knownEstimatedCostUsd)
    }

    private var partialCost: Bool {
        (conversation.cost?.unpricedTokens ?? 0) > 0 || (totalCost?.unpricedTokens ?? 0) > 0
    }

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 9) {
                ForEach(conversation.agents) { agent in
                    agentRows(agent)
                }
                if conversation.mainTurns != nil || conversation.mainTokens != nil {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(L("subagents.main")).fontWeight(.medium)
                        if let turns = conversation.mainTurns {
                            Text(LF("subagents.main_turns", turns.formatted(.number.locale(Localization.locale))))
                                .foregroundStyle(WorkspaceStyle.subtext)
                        }
                        Spacer(minLength: 8)
                        if let tokens = conversation.mainTokens {
                            Text(tokens.formatted(.number.locale(Localization.locale)))
                                .monospacedDigit()
                        }
                    }
                    .font(.caption)
                }
            }
            .padding(.vertical, 5)
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 10) {
                    Text(title).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(LF("subagents.started_value", conversation.starts.formatted(.number.locale(Localization.locale))))
                        .foregroundStyle(WorkspaceStyle.subtext)
                }
                HStack(alignment: .top, spacing: 20) {
                    conversationMetric(
                        title: L("usage.tokens"),
                        value: conversation.tokens.formatted(.number.locale(Localization.locale)),
                        share: tokensShare,
                        partial: false,
                        color: WorkspaceStyle.localUsage
                    )
                    conversationMetric(
                        title: L("cost.estimate"),
                        value: subagentCostText(conversation.cost),
                        share: costShare,
                        partial: partialCost,
                        color: WorkspaceStyle.costColor(colorScheme)
                    )
                }
            }
            .font(.callout)
            .padding(.vertical, 4)
        }
        .disclosureGroupStyle(WorkspaceDisclosureStyle())
    }

    private func conversationMetric(title: String, value: String, share: Double?, partial: Bool, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title).foregroundStyle(WorkspaceStyle.subtext)
                Text(value).monospacedDigit()
                Spacer(minLength: 2)
                Text(subagentShareText(share, partial: partial))
                    .foregroundStyle(WorkspaceStyle.subtext)
                    .monospacedDigit()
            }
            .font(.caption)
            SubagentShareBar(share: share, color: color)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func agentRows(_ agent: CodexSubagent) -> some View {
        let name = agent.name.flatMap { $0.isEmpty ? nil : $0 } ?? LF("subagents.unnamed", String(agent.id.prefix(8)))
        if agent.models.isEmpty {
            HStack {
                Text(name).fontWeight(.medium)
                Spacer()
                Text("—").foregroundStyle(WorkspaceStyle.subtext)
            }
            .font(.caption)
        } else {
            ForEach(agent.models) { model in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(name).fontWeight(.medium)
                    Text(model.model).foregroundStyle(WorkspaceStyle.subtext).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(model.tokens.formatted(.number.locale(Localization.locale))).monospacedDigit()
                    Text(subagentCostText(model.cost)).monospacedDigit().foregroundStyle(WorkspaceStyle.subtext)
                }
                .font(.caption)
            }
        }
    }
}

struct OverviewView: View {
    let report: UsageReport
    let localOnly: Bool
    let isActive: Bool
    let openDatePicker: () -> Void
    @Environment(UsageStore.self) private var store
    @Environment(\.colorScheme) private var colorScheme
    @State private var rankingMetric: UsageMetric = .tokens
    @State private var previousRange: (UsageDateRange, String?, String?)?
    @State private var calendarDrillDown: String?

    private var overview: UsageReport { localOnly ? report : (store.combinedOverview ?? report) }
    private var localAtSync: UsageReport { localOnly ? report : (store.cloudLocalOverview ?? report) }
    private var remoteReports: [String: UsageReport] { localOnly ? [:] : store.remoteOverviewReports }
    private var multiDevice: Bool { !remoteReports.isEmpty && store.combinedOverview != nil }
    private var totalRows: [OverviewDeviceRow] {
        func row(_ id: String, _ name: String, _ source: UsageReport) -> OverviewDeviceRow {
            OverviewDeviceRow(id: id, name: name, summary: source.summary, models: source.overviewModelCount)
        }
        return [row("total", L("cloud.overview.total"), overview), row("local", store.localDeviceName, localAtSync)]
            + remoteReports.keys.sorted().compactMap { id in
                remoteReports[id].map { row("remote:" + id, store.deviceName(id), $0) }
            }
    }
    private var reportFilter: UsageFilter { store.reportFilter ?? store.filter }
    private var range: DashboardDateSpan? {
        isActive ? DashboardDateSpan(from: reportFilter.from, to: reportFilter.to) : nil
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        Color.clear.frame(height: 0).id("overview-top")
                        LazyVStack(alignment: .leading, spacing: 20) {
                            if previousRange != nil {
                                Button { restoreRange() } label: { Label(L("overview.back"), systemImage: "arrow.left") }
                                    .buttonStyle(.plain).foregroundStyle(WorkspaceStyle.selection).font(.caption)
                            }
                            if !localOnly, let notice = store.cloud.compatibilityNotice {
                                Label(notice, systemImage: "icloud.slash").font(.callout).foregroundStyle(.secondary)
                            }
                            WorkspacePanel {
                                VStack(alignment: .leading, spacing: 20) {
                                    if overview.summary.recordCount > 0 {
                                        totals
                                        TokenMixView(tokens: overview.summary.tokenBreakdown, range: range)
                                        Divider()
                                    }
                                    UsageTrendChart(report: overview, localReport: localAtSync,
                                                    remoteReports: remoteReports,
                                                    localName: store.localDeviceName, deviceName: store.deviceName,
                                                    filter: reportFilter, animateRangeChanges: isActive, openDatePicker: openDatePicker)
                                }
                            }
                            if overview.summary.recordCount > 0 {
                                let layout = geometry.size.width >= 720
                                    ? AnyLayout(HStackLayout(alignment: .top, spacing: 18))
                                    : AnyLayout(VStackLayout(alignment: .leading, spacing: 18))
                                WorkspacePanel {
                                    VStack(alignment: .leading, spacing: 16) {
                                        HStack(spacing: 12) {
                                            Picker(L("overview.sort"), selection: $rankingMetric) {
                                                ForEach(UsageMetric.allCases, id: \.self) { Text($0.title).tag($0) }
                                            }.labelsHidden().pickerStyle(.segmented).tint(WorkspaceStyle.selection).fixedSize()
                                            Spacer()
                                            if multiDevice { OverviewDeviceLegend() }
                                            if rankingMetric.fastAmount(in: overview.summary) > 0 {
                                                HStack(spacing: 5) {
                                                    Capsule().fill(WorkspaceStyle.fastUsage(colorScheme)).frame(width: 10, height: 3)
                                                        .accessibilityHidden(true)
                                                    Text(L("fast.title")).font(.caption).foregroundStyle(WorkspaceStyle.subtext)
                                                }
                                            }
                                        }
                                        Divider()
                                        layout {
                                            UsageRankingView(groups: overview.clients, remoteGroups: Dictionary(grouping: remoteReports.values.flatMap(\.clients), by: \.key), kind: .tool, metric: rankingMetric, range: range)
                                            UsageRankingView(groups: overview.models, remoteGroups: Dictionary(grouping: remoteReports.values.flatMap(\.models), by: \.key), kind: .model, metric: rankingMetric, range: range)
                                        }
                                    }
                                }
                            }
                            if let subagents = overview.codexSubagents, subagents.hasActivity {
                                CodexSubagentsView(report: subagents,
                                                  local: multiDevice
                                                    ? store.cloud.matchingSubagentDetails(in: report, for: reportFilter)
                                                    : report.codexSubagents,
                                                  hasRemote: multiDevice,
                                                  remote: remoteReports.values.compactMap(\.codexSubagents),
                                                  codexSummary: overview.clients.first { $0.key == "codex" }?.summary)
                            }
                            if let activity = localOnly ? store.activity : (store.combinedActivity ?? store.activity), !activity.daily.isEmpty,
                               let calendar = localOnly ? store.activityCalendar : (store.combinedActivityCalendar ?? store.activityCalendar) {
                                let hasRemote = !localOnly && store.combinedActivity != nil && !store.remoteActivityReports.isEmpty
                                UsageActivityView(report: activity, activity: calendar, showsDeviceBreakdown: hasRemote) { day in
                                    if reportFilter.from == day, reportFilter.to == day, store.filter == reportFilter {
                                        proxy.scrollTo("overview-top", anchor: .top)
                                        return
                                    }
                                    if previousRange == nil { previousRange = (store.dateRange, store.filter.from, store.filter.to) }
                                    calendarDrillDown = day
                                    store.dateRange = .custom
                                    var filter = store.filter; filter.from = day; filter.to = day; filter.offset = 0
                                    store.filter = filter
                                }
                                UsageHabitsView(report: activity, activity: calendar, horizontal: geometry.size.width >= 760)
                                UsageHistoryChart(report: activity, localOnly: localOnly || !hasRemote)
                            }
                        }.padding(.horizontal, 22).padding(.bottom, 22).padding(.top, 4)
                    }
                }
                .onChange(of: reportFilter) { _, new in
                    if let day = calendarDrillDown, new.from == day, new.to == day {
                        proxy.scrollTo("overview-top", anchor: .top)
                    }
                    calendarDrillDown = nil
                }
            }
        }
        .cursorTooltipSurface()
    }
    private func restoreRange() {
        guard let previousRange else { return }
        store.dateRange = previousRange.0
        var filter = store.filter; filter.from = previousRange.1; filter.to = previousRange.2; filter.offset = 0
        store.filter = filter; store.updateDateRange(); self.previousRange = nil
    }
    private var totals: some View {
        let fields = totalFields
        return ViewThatFits(in: .horizontal) {
            totalsGrid(fields)
            VStack(alignment: .leading, spacing: 14) {
                totalsGrid(Array(fields.prefix(2)))
                totalsGrid(Array(fields.dropFirst(2)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private struct TotalField: Identifiable {
        let id: String
        let value: String
        let amount: Double?
        let local: String?
        var primary = false
        var explainsCost = false
    }

    private var totalFields: [TotalField] {
        let summary = overview.summary
        var fields = [
            TotalField(id: "usage.tokens", value: compactTokens(summary.tokens), amount: Double(summary.tokens),
                       local: compactTokens(localAtSync.summary.tokens), primary: true),
            TotalField(id: summary.costStatus == "partial" ? "cost.known" : "cost.estimate",
                       value: usd(summary.knownEstimatedCostUsd), amount: summary.knownEstimatedCostUsd,
                       local: usd(localAtSync.summary.knownEstimatedCostUsd), primary: true, explainsCost: true)
        ]
        if reportFilter.from == nil || reportFilter.from != reportFilter.to {
            fields.append(TotalField(id: "overview.active_days", value: summary.activeDays.formatted(),
                                     amount: Double(summary.activeDays), local: nil))
        }
        let count = overview.overviewModelCount
        fields.append(TotalField(id: "overview.models", value: count.formatted(), amount: Double(count),
                                 local: localAtSync.overviewModelCount.formatted()))
        return fields
    }

    private func totalsGrid(_ fields: [TotalField]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 5) {
            GridRow(alignment: .firstTextBaseline) {
                ForEach(fields) { field in
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(L(field.id)).font(.subheadline).foregroundStyle(WorkspaceStyle.subtext)
                        if field.explainsCost { costInfo }
                    }
                }
            }
            GridRow(alignment: .firstTextBaseline) {
                ForEach(fields) { field in
                    DashboardRollingValue(text: field.value, value: field.amount, range: range,
                                          style: .semibold(field.primary ? 32 : 23), themed: true)
                        .fixedSize()
                        .cursorTooltip(enabled: multiDevice && field.local != nil) {
                            OverviewDeviceReadout(rows: totalRows)
                        }
                        .frame(maxWidth: field.primary ? .infinity : nil, alignment: .leading)
                        .accessibilityLabel(L(field.id) + " " + field.value)
                }
            }
            if multiDevice {
                GridRow(alignment: .firstTextBaseline) {
                    ForEach(fields) { field in
                        if let local = field.local {
                            if field.id == "overview.models" {
                                Text(local).font(.caption).monospacedDigit().foregroundStyle(WorkspaceStyle.subtext)
                                    .cursorTooltip(enabled: multiDevice) { OverviewDeviceReadout(rows: totalRows) }
                                    .accessibilityLabel(LF("cloud.overview.localValue", local))
                            } else {
                                totalDetail(icon: "desktopcomputer", label: L("cloud.overview.local"), value: local, showsDevices: true)
                                    .accessibilityLabel(LF("cloud.overview.localValue", local))
                            }
                        } else { Color.clear.frame(width: 1, height: 1).accessibilityHidden(true) }
                    }
                }
            }
            if fields.contains(where: { $0.id == "usage.tokens" }),
               let fast = overview.summary.fastTokens, fast > 0 {
                GridRow(alignment: .firstTextBaseline) {
                    totalDetail(icon: "bolt.fill", label: L("fast.title"), value: compactTokens(fast))
                        .help(L("fast.tokens_help"))
                        .accessibilityLabel(LF("fast.value_accessibility", compactTokens(fast)))
                        .accessibilityHint(L("fast.tokens_help"))
                    ForEach(fields.dropFirst()) { _ in
                        Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
                    }
                }
            }
        }
    }

    private func totalDetail(icon: String, label: String, value: String, showsDevices: Bool = false) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).frame(width: 13, alignment: .center)
            ZStack(alignment: .leading) {
                Text(L("cloud.overview.local")).hidden().accessibilityHidden(true)
                Text(L("fast.title")).hidden().accessibilityHidden(true)
                Text(label)
            }
            Text(value).monospacedDigit()
                .cursorTooltip(enabled: showsDevices && multiDevice) {
                    OverviewDeviceReadout(rows: totalRows)
                }
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(WorkspaceStyle.subtext)
        .fixedSize()
        .accessibilityElement(children: .ignore)
    }

    private var costInfo: some View {
        WorkspaceInfoPopover(title: L("overview.cost_info")) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("overview.cost_help"))
                if overview.summary.unpricedTokens > 0 { Text(LF("usage.unpriced", compactTokens(overview.summary.unpricedTokens))) }
                if let n = overview.summary.partialDays, n > 0 { Text(LF("usage.partial_days", n)) }
            }.padding(16).frame(width: 280, alignment: .leading).fixedSize(horizontal: false, vertical: true)
        }
    }

}

private struct TokenMixView: View {
    let tokens: TokenBreakdown
    let range: DashboardDateSpan?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var parts: [(String, Int64, Color)] {
        [("token.input", tokens.input, WorkspaceStyle.localUsage), ("token.output", tokens.output, WorkspaceStyle.outputTokens),
         ("token.cache_read", tokens.cacheRead, WorkspaceStyle.cacheRead), ("token.cache_write", tokens.cacheWrite, WorkspaceStyle.cacheWrite),
         ("token.reasoning", tokens.reasoning, WorkspaceStyle.reasoningTokens)]
    }
    var body: some View {
        let total = parts.reduce(Int64(0)) { $0 + $1.1 }
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    ForEach(parts.indices, id: \.self) { i in
                        Rectangle().fill(parts[i].2.opacity(0.8))
                            .frame(width: total > 0 ? geometry.size.width * Double(parts[i].1) / Double(total) : 0)
                    }
                }
                .animation(reduceMotion || range == nil ? nil : DashboardMotion.grow, value: range)
                .clipShape(Capsule())
            }.frame(height: 5).accessibilityHidden(true)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 142), alignment: .leading)], alignment: .leading, spacing: 7) {
                ForEach(parts.indices, id: \.self) { i in
                    HStack(spacing: 5) {
                        Circle().fill(parts[i].2).frame(width: 5, height: 5)
                        Text(L(parts[i].0)).foregroundStyle(WorkspaceStyle.subtext)
                        DashboardRollingValue(text: compactTokens(parts[i].1), value: Double(parts[i].1),
                                              range: range, style: .caption2, themed: true)
                    }.font(.caption2).help(total > 0 ? (Double(parts[i].1) / Double(total)).formatted(.percent.precision(.fractionLength(1))) : "0%")
                        .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

private extension UsageMetric {
    func amount(in summary: UsageSummary) -> Double? {
        self == .tokens ? Double(summary.tokens) : summary.knownEstimatedCostUsd
    }

    func fastAmount(in summary: UsageSummary) -> Double {
        self == .tokens ? Double(summary.fastTokens ?? 0) : summary.fastEstimatedCostUsd ?? 0
    }

    func fastReadout(in summary: UsageSummary) -> String? {
        guard fastAmount(in: summary) > 0 else { return nil }
        return self == .tokens
            ? LF("fast.tokens", compactTokens(summary.fastTokens ?? 0))
            : LF("fast.cost", usd(summary.fastEstimatedCostUsd))
    }
}

private struct UsageRankingView: View {
    let groups: [UsageGroup]
    let remoteGroups: [String: [UsageGroup]]
    let kind: BrandKind
    let metric: UsageMetric
    let range: DashboardDateSpan?
    @State private var expanded = false
    private var sorted: [UsageGroup] {
        groups.sorted {
            let a = metric.amount(in: $0.summary) ?? -1
            let b = metric.amount(in: $1.summary) ?? -1
            return a == b ? $0.key < $1.key : a > b
        }
    }
    var body: some View {
        let total = groups.reduce(0.0) { $0 + (metric.amount(in: $1.summary) ?? 0) }
        VStack(alignment: .leading, spacing: 16) {
            Text(L(kind == .tool ? "usage.by_tool" : "usage.by_model"))
                .font(.headline).foregroundStyle(WorkspaceStyle.text).frame(height: 24)
            ForEach(expanded ? sorted : Array(sorted.prefix(5))) { group in
                rankingRow(group, total: total)
            }
            if groups.count > 5 {
                Button(L(expanded ? "action.show_less" : "action.show_all")) { expanded.toggle() }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(WorkspaceStyle.selection)
            }
            if groups.isEmpty { Text(L("usage.empty")).foregroundStyle(WorkspaceStyle.subtext).padding(.vertical, 24) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rankingRow(_ group: UsageGroup, total: Double) -> some View {
        let summary = group.summary
        let amount = metric.amount(in: summary)
        let share = amount.map { total > 0 ? $0 / total : 0 }
        let remote = remoteGroups[group.key] ?? []
        let other = remote.reduce(0.0) { $0 + (metric.amount(in: $1.summary) ?? 0) }
        let otherFast = remote.reduce(0.0) { $0 + metric.fastAmount(in: $1.summary) }
        let fastText = metric.fastReadout(in: summary)
        let costText = L(summary.costStatus == "partial" ? "cost.known" : "cost.estimate") + ": " + usd(summary.knownEstimatedCostUsd)
        return HStack(spacing: 10) {
            BrandIcon(name: group.key, kind: kind, size: 18)
            VStack(spacing: 7) {
                HStack {
                    Text(kind == .tool ? clientName(group.key) : group.key).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(WorkspaceStyle.text)
                    Spacer(minLength: 8)
                    DashboardRollingValue(text: metric == .tokens ? compactTokens(summary.tokens) : usd(amount),
                                          value: amount, range: range, style: .callout, themed: true)
                }.font(.callout)
                OverviewShareBar(total: total, amount: amount ?? 0, other: other,
                                 fast: metric.fastAmount(in: summary), otherFast: otherFast, height: 5, range: range)
            }
            DashboardRollingValue(text: share?.formatted(.percent.precision(.fractionLength(0))) ?? "—",
                                  value: share, range: range, style: .caption2, secondary: true, themed: true)
                .foregroundStyle(WorkspaceStyle.subtext).frame(width: 35, alignment: .trailing)
        }
        .help([group.key, costText, fastText].compactMap { $0 }.joined(separator: "\n"))
        .accessibilityElement(children: .combine)
        .accessibilityValue(fastText ?? "")
    }

}
