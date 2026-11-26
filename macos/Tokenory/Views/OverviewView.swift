// [INPUT]: Selected-range and annual reports for this Mac and participating devices.
// [OUTPUT]: Rolling totals and titled overview cards for insights, subagents, rankings and annual activity.
// [POS]: Native overview composition; disclosure keeps detailed caveats off the canvas.
// [PROTOCOL]: Update this header on change, then check AGENTS.md
import SwiftUI

private struct SubagentsCardView: View {
    struct ToolEntry: Identifiable {
        let id: String
        let name: String
        let report: CodexSubagentReport
        let local: CodexSubagentReport?
        let remote: [CodexSubagentReport]
        let toolTokens: Int64
    }

    let entries: [ToolEntry]
    let hasRemote: Bool
    let overallSummary: UsageSummary
    @Environment(\.colorScheme) private var colorScheme
    private var metricFont: Font { DisplayNumberFont.font(for: .title3) }

    private var totalStarts: Int64 { entries.reduce(0) { $0 + $1.report.starts } }
    private var totalTokens: Int64 { entries.reduce(0) { $0 + $1.report.tokens } }
    private var totalCost: CodexSubagentCost? {
        var known = 0.0, hasKnown = false
        var unpriced: Int64 = 0
        for entry in entries {
            if let usd = entry.report.cost?.knownEstimatedCostUsd {
                known += usd
                hasKnown = true
            }
            unpriced += entry.report.cost?.unpricedTokens ?? 0
        }
        guard hasKnown || unpriced > 0 else { return nil }
        return CodexSubagentCost(knownEstimatedCostUsd: hasKnown ? known : nil, unpricedTokens: unpriced)
    }
    private var remoteTokens: Double {
        entries.reduce(0) { sum, entry in sum + entry.remote.reduce(0) { $0 + Double($1.tokens) } }
    }
    private var remoteCost: Double {
        entries.reduce(0) { sum, entry in sum + entry.remote.compactMap { $0.cost?.knownEstimatedCostUsd }.reduce(0, +) }
    }
    private var tokensShare: Double? {
        subagentShare(Double(totalTokens), of: Double(overallSummary.tokens))
    }
    private var costShare: Double? {
        subagentShare(totalCost?.knownEstimatedCostUsd, of: overallSummary.knownEstimatedCostUsd)
    }
    private var partialCost: Bool {
        (totalCost?.unpricedTokens ?? 0) > 0 || overallSummary.unpricedTokens > 0
    }

    var body: some View {
        WorkspacePanel {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        OverviewCardTitle(title: L("subagents.card_title"), symbol: "arrow.triangle.branch")
                        Text(LF("subagents.started_value", totalStarts.formatted(.number.locale(Localization.locale))))
                            .font(.caption)
                            .foregroundStyle(WorkspaceStyle.subtext)
                            .monospacedDigit()
                    }
                    Spacer()
                    if hasRemote { OverviewDeviceLegend() }
                    WorkspaceInfoPopover(title: L("subagents.basis")) {
                        Text(L("subagents.supported_only_help"))
                            .padding(14)
                            .frame(width: 260, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(alignment: .top, spacing: 24) {
                    shareMetric(
                        title: L("usage.tokens"),
                        value: totalTokens.formatted(.number.locale(Localization.locale)),
                        share: tokensShare,
                        otherShare: subagentShare(remoteTokens, of: Double(overallSummary.tokens)),
                        partial: false,
                        color: WorkspaceStyle.localUsage
                    )
                    shareMetric(
                        title: L("cost.estimate"),
                        value: subagentCostText(totalCost),
                        share: costShare,
                        otherShare: subagentShare(remoteCost, of: overallSummary.knownEstimatedCostUsd),
                        partial: partialCost,
                        color: WorkspaceStyle.costColor(colorScheme)
                    )
                }
                Divider()
                VStack(spacing: 4) {
                    ForEach(entries) { entry in
                        toolSection(entry)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func toolSection(_ entry: ToolEntry) -> some View {
        let conversations = entry.local?.conversations ?? []
        if !conversations.isEmpty, let local = entry.local {
            DisclosureGroup {
                VStack(spacing: 0) {
                    ForEach(conversations) { conversation in
                        CodexSubagentConversationView(
                            conversation: conversation,
                            totalTokens: local.tokens,
                            totalCost: local.cost
                        )
                    }
                }
            } label: {
                toolRowLabel(entry)
            }
            .disclosureGroupStyle(WorkspaceDisclosureStyle())
        } else {
            toolRowLabel(entry)
                .padding(.vertical, 12)
                .frame(minHeight: 36)
        }
    }

    private func toolRowLabel(_ entry: ToolEntry) -> some View {
        let tokensPct = subagentShare(Double(entry.report.tokens), of: Double(entry.toolTokens))
        let costText: String = {
            if entry.report.tokens == 0 && (entry.report.cost?.unpricedTokens ?? 0) == 0 {
                return usd(0)
            }
            return subagentCostText(entry.report.cost)
        }()
        let pctText = tokensPct.map { subagentShareText($0) } ?? "0%"
        return HStack(alignment: .center, spacing: 10) {
            BrandIcon(name: entry.id, kind: .tool, size: 16)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(entry.name)
                    .fontWeight(.medium)
                    .foregroundStyle(WorkspaceStyle.text)
                Text(LF("subagents.started_value", entry.report.starts.formatted(.number.locale(Localization.locale))))
                    .font(.caption)
                    .foregroundStyle(WorkspaceStyle.subtext)
                    .monospacedDigit()
            }
            Spacer(minLength: 8)
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(compactTokens(entry.report.tokens))
                    .monospacedDigit()
                    .foregroundStyle(WorkspaceStyle.text)
                    .frame(minWidth: 74, alignment: .trailing)
                Text(costText)
                    .monospacedDigit()
                    .foregroundStyle(WorkspaceStyle.subtext)
                    .frame(minWidth: 64, alignment: .trailing)
                Text(pctText)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(WorkspaceStyle.subtext)
                    .frame(minWidth: 44, alignment: .trailing)
            }
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
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

    private var mainContextSummary: String? {
        var parts: [String] = []
        if let tokens = conversation.mainTokens {
            parts.append(compactTokens(tokens))
        }
        if let turns = conversation.mainTurns {
            parts.append(LF("subagents.main_turns", turns.formatted(.number.locale(Localization.locale))))
        }
        guard !parts.isEmpty else { return nil }
        return L("subagents.main") + " " + parts.joined(separator: " · ")
    }

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 9) {
                ForEach(conversation.agents) { agent in
                    agentRows(agent)
                }
            }
            .padding(.vertical, 5)
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title).lineLimit(1).truncationMode(.middle)
                    if let mainContextSummary {
                        Text(mainContextSummary)
                            .font(.caption)
                            .foregroundStyle(WorkspaceStyle.subtext)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Text(LF("subagents.started_value", conversation.starts.formatted(.number.locale(Localization.locale))))
                        .font(.caption)
                        .foregroundStyle(WorkspaceStyle.subtext)
                        .monospacedDigit()
                }
                HStack(alignment: .top, spacing: 20) {
                    let convCostText = (conversation.tokens == 0 && (conversation.cost?.unpricedTokens ?? 0) == 0)
                        ? usd(0)
                        : subagentCostText(conversation.cost)
                    conversationMetric(
                        title: L("usage.tokens"),
                        value: conversation.tokens.formatted(.number.locale(Localization.locale)),
                        share: tokensShare ?? 0,
                        partial: false,
                        color: WorkspaceStyle.localUsage
                    )
                    conversationMetric(
                        title: L("cost.estimate"),
                        value: convCostText,
                        share: costShare ?? (conversation.tokens == 0 && (conversation.cost?.unpricedTokens ?? 0) == 0 ? 0 : nil),
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
        let cleaned = agent.name?.trimmingCharacters(in: CharacterSet(charactersIn: "\" \t\n"))
        let name = cleaned.flatMap { $0.isEmpty ? nil : $0 } ?? LF("subagents.unnamed", String(agent.id.prefix(8)))
        if agent.models.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(name).fontWeight(.medium).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 8)
                Text("0").monospacedDigit().fixedSize()
                Text(usd(0)).monospacedDigit().foregroundStyle(WorkspaceStyle.subtext).fixedSize()
            }
            .font(.caption)
        } else {
            ForEach(agent.models) { model in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(name).fontWeight(.medium).lineLimit(1).truncationMode(.tail)
                    Text(model.model).foregroundStyle(WorkspaceStyle.subtext).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(model.tokens.formatted(.number.locale(Localization.locale))).monospacedDigit().fixedSize()
                    Text(subagentCostText(model.cost)).monospacedDigit().foregroundStyle(WorkspaceStyle.subtext).fixedSize()
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
            + remoteReports.map { id, report in
                row("remote:" + id, store.deviceName(id), report)
            }
    }
    private var reportFilter: UsageFilter { store.reportFilter ?? store.filter }
    private var range: DashboardDateSpan? {
        isActive ? DashboardDateSpan(from: reportFilter.from, to: reportFilter.to) : nil
    }

    private var annualCalendar: UsageActivity? {
        localOnly ? store.activityCalendar : (store.combinedActivityCalendar ?? store.activityCalendar)
    }

    private var reportingCalendar: Calendar {
        var calendar = Localization.reportingCalendar
        if multiDevice { calendar.timeZone = TimeZone(identifier: DeviceUsageSnapshot.reportingTimezone)! }
        return calendar
    }

    private var antigravityToolTokens: Int64 {
        overview.clients.filter { $0.key == "antigravity" || $0.key == "antigravity-cli" }
            .reduce(0) { $0 + $1.summary.tokens }
    }

    private func localSubagentDetails(_ field: KeyPath<UsageReport, CodexSubagentReport?>) -> CodexSubagentReport? {
        if multiDevice { return store.cloud.matchingSubagentDetails(in: report, for: reportFilter, field: field) }
        return report[keyPath: field]
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        Color.clear.frame(height: 0).id("overview-top")
                        LazyVStack(alignment: .leading, spacing: 20) {
                            if previousRange != nil {
                                Button { restoreRange() } label: {
                                    Label(L("overview.back"), systemImage: "arrow.left")
                                        .padding(.horizontal, 6).padding(.vertical, 3)
                                }
                                .buttonStyle(WorkspaceHoverStyle()).foregroundStyle(WorkspaceStyle.selection).font(.caption)
                            }
                            if !localOnly, let notice = store.cloud.compatibilityNotice {
                                Label(notice, systemImage: "icloud.slash").font(.callout).foregroundStyle(.secondary)
                            }
                            WorkspacePanel {
                                VStack(alignment: .leading, spacing: 20) {
                                    totals(wide: geometry.size.width >= 660)
                                    TokenMixView(tokens: overview.summary.tokenBreakdown, range: range)
                                        .padding(.bottom, 14)
                                    UsageTrendChart(report: overview, localReport: localAtSync,
                                                    remoteReports: remoteReports,
                                                    localName: store.localDeviceName, deviceName: store.deviceName,
                                                    filter: reportFilter, animateRangeChanges: isActive, openDatePicker: openDatePicker)
                                }
                            }
                            let layout = geometry.size.width >= 720
                                ? AnyLayout(HStackLayout(alignment: .top, spacing: 18))
                                : AnyLayout(VStackLayout(alignment: .leading, spacing: 18))
                            WorkspacePanel {
                                VStack(alignment: .leading, spacing: 16) {
                                    OverviewCardTitle(title: L("overview.tools_models"), symbol: "square.grid.2x2")
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
                                        UsageRankingView(groups: overview.clients, remoteGroups: Dictionary(grouping: remoteReports.values.flatMap(\.clients), by: \.key), kind: .tool, metric: rankingMetric, range: range,
                                                         childModels: overview.clientModels ?? [:], toolReport: overview)
                                        UsageRankingView(groups: overview.models, remoteGroups: Dictionary(grouping: remoteReports.values.flatMap(\.models), by: \.key), kind: .model, metric: rankingMetric, range: range,
                                                         codexSubagents: localSubagentDetails(\.codexSubagents),
                                                         antigravitySubagents: localSubagentDetails(\.antigravitySubagents))
                                    }
                                }
                            }
                            let subagentEntries: [SubagentsCardView.ToolEntry] = {
                                var list: [SubagentsCardView.ToolEntry] = []
                                if let codex = overview.codexSubagents, codex.hasActivity {
                                    list.append(.init(
                                        id: "codex",
                                        name: clientName("codex"),
                                        report: codex,
                                        local: localSubagentDetails(\.codexSubagents),
                                        remote: remoteReports.values.compactMap(\.codexSubagents),
                                        toolTokens: overview.clients.first { $0.key == "codex" }?.summary.tokens ?? 0
                                    ))
                                }
                                if let agy = overview.antigravitySubagents, agy.hasActivity {
                                    list.append(.init(
                                        id: "antigravity",
                                        name: clientName("antigravity"),
                                        report: agy,
                                        local: localSubagentDetails(\.antigravitySubagents),
                                        remote: remoteReports.values.compactMap(\.antigravitySubagents),
                                        toolTokens: antigravityToolTokens
                                    ))
                                }
                                return list
                            }()
                            if !subagentEntries.isEmpty {
                                SubagentsCardView(
                                    entries: subagentEntries,
                                    hasRemote: multiDevice && subagentEntries.contains { !$0.remote.isEmpty },
                                    overallSummary: overview.summary
                                )
                            }
                            let activity = localOnly ? store.activity : (store.combinedActivity ?? store.activity)
                            let hasRemote = !localOnly && store.combinedActivity != nil && !store.remoteActivityReports.isEmpty
                            if let activity, !activity.daily.isEmpty, let calendar = annualCalendar {
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
                            }
                            if overview.summary.tokens > 0 || (annualCalendar?.activeDays ?? 0) > 0 {
                                OverviewInsightsView(
                                    insights: OverviewInsights(summary: overview.summary, filter: reportFilter, calendar: reportingCalendar),
                                    streak: annualCalendar.flatMap { $0.activeDays > 0 ? $0.streak : nil },
                                    wide: geometry.size.width >= 790
                                )
                            }
                            if let activity, !activity.daily.isEmpty, let calendar = annualCalendar {
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
    @ViewBuilder
    private func totals(wide: Bool) -> some View {
        let fields = totalFields
        Group {
            if wide {
                totalsGrid(fields)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    totalsGrid(Array(fields.prefix(2)))
                    totalsGrid(Array(fields.dropFirst(2)))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private struct TotalField: Identifiable {
        let id: String
        let titleKey: String
        let value: String
        let amount: Double?
        let local: String?
        var primary = false
        var explainsCost = false
    }

    private var totalFields: [TotalField] {
        let summary = overview.summary
        var fields = [
            TotalField(id: "usage.tokens", titleKey: "usage.tokens", value: compactTokens(summary.tokens), amount: Double(summary.tokens),
                       local: compactTokens(localAtSync.summary.tokens), primary: true),
            TotalField(id: "cost", titleKey: summary.costStatus == "partial" ? "cost.known" : "cost.estimate",
                       value: usd(summary.knownEstimatedCostUsd), amount: summary.knownEstimatedCostUsd,
                       local: usd(localAtSync.summary.knownEstimatedCostUsd), primary: true, explainsCost: true)
        ]
        if reportFilter.from == nil || reportFilter.from != reportFilter.to {
            fields.append(TotalField(id: "overview.active_days", titleKey: "overview.active_days", value: summary.activeDays.formatted(),
                                     amount: Double(summary.activeDays), local: nil))
        }
        let count = overview.overviewModelCount
        fields.append(TotalField(id: "overview.models", titleKey: "overview.models", value: count.formatted(), amount: Double(count),
                                 local: localAtSync.overviewModelCount.formatted()))
        return fields
    }

    private var reservesLocalRow: Bool { !localOnly && !store.cloud.sources.isEmpty }

    private func totalsGrid(_ fields: [TotalField]) -> some View {
        let fast = overview.summary.fastTokens ?? 0
        let showsFast = fast > 0
        return Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 5) {
            GridRow(alignment: .firstTextBaseline) {
                ForEach(fields) { field in
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(L(field.titleKey)).font(.subheadline).foregroundStyle(WorkspaceStyle.subtext)
                        if field.explainsCost { costInfo }
                    }
                }
            }
            GridRow(alignment: .firstTextBaseline) {
                ForEach(fields) { field in
                    DashboardRollingValue(text: field.value, value: field.amount, range: range,
                                          style: .displayNumber(field.primary ? 32 : 23), themed: true)
                        .fixedSize()
                        .cursorTooltip(enabled: multiDevice && field.local != nil) {
                            OverviewDeviceReadout(rows: totalRows)
                        }
                        .frame(maxWidth: field.primary ? .infinity : nil, alignment: .leading)
                        .accessibilityLabel(L(field.titleKey) + " " + field.value)
                }
            }
            if reservesLocalRow {
                GridRow(alignment: .firstTextBaseline) {
                    ForEach(fields) { field in
                        if let local = field.local {
                            if field.id == "overview.models" {
                                Text(local).font(.caption).monospacedDigit().foregroundStyle(WorkspaceStyle.subtext)
                                    .opacity(multiDevice ? 1 : 0)
                                    .cursorTooltip(enabled: multiDevice) { OverviewDeviceReadout(rows: totalRows) }
                                    .accessibilityLabel(LF("cloud.overview.localValue", local))
                                    .accessibilityHidden(!multiDevice)
                            } else {
                                totalDetail(icon: "desktopcomputer", label: L("cloud.overview.local"), value: local, showsDevices: multiDevice)
                                    .opacity(multiDevice ? 1 : 0)
                                    .accessibilityLabel(LF("cloud.overview.localValue", local))
                                    .accessibilityHidden(!multiDevice)
                            }
                        } else { Color.clear.frame(width: 1, height: 1).accessibilityHidden(true) }
                    }
                }
            }
            if fields.contains(where: { $0.id == "usage.tokens" }) {
                GridRow(alignment: .firstTextBaseline) {
                    totalDetail(icon: "bolt.fill", label: L("fast.title"), value: compactTokens(fast))
                        .opacity(showsFast ? 1 : 0)
                        .allowsHitTesting(showsFast)
                        .accessibilityLabel(LF("fast.value_accessibility", compactTokens(fast)))
                        .accessibilityHint(L("fast.tokens_help"))
                        .accessibilityHidden(!showsFast)
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

private struct OverviewInsightsView: View {
    let insights: OverviewInsights
    let streak: (current: Int, longest: Int)?
    let wide: Bool

    var body: some View {
        let count = [streak != nil, insights.monthlyPace != nil, insights.activeDayTokens != nil, insights.cachedInputShare != nil]
            .filter { $0 }.count
        if count > 0 {
            WorkspacePanel {
                VStack(alignment: .leading, spacing: 14) {
                    OverviewCardTitle(title: L("overview.insights"), symbol: "lightbulb")
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 18, alignment: .leading),
                                             count: min(wide ? 4 : 2, count)), alignment: .leading, spacing: 16) {
                        if let streak {
                            metric("insight.streak", LF("insight.days", streak.current),
                                   detail: LF("insight.longest", streak.longest))
                        }
                        if let pace = insights.monthlyPace, let days = insights.periodDays {
                            metric("insight.monthly_pace", usd(pace), detail: LF("insight.pace_basis", days))
                        }
                        if let average = insights.activeDayTokens {
                            metric("insight.active_day", compactTokens(average) + " Tokens",
                                   detail: insights.activeDayCost.map { LF("insight.active_day_cost", usd($0)) })
                        }
                        if let share = insights.cachedInputShare {
                            metric("insight.cached_input", share.formatted(.percent.precision(.fractionLength(0...1)).locale(Localization.locale)),
                                   detail: insights.costPerMillion.map { LF("insight.cost_per_million", usd($0)) })
                        }
                    }
                }
            }
        }
    }

    private func metric(_ title: String, _ reading: String, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L(title)).font(.caption).foregroundStyle(WorkspaceStyle.subtext)
            Text(reading).font(DisplayNumberFont.font(for: .title3)).foregroundStyle(WorkspaceStyle.text)
            if let detail { Text(detail).font(.caption2).foregroundStyle(WorkspaceStyle.subtext) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
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
        let fractions: [Double] = total > 0 ? parts.map { Double($0.1) / Double(total) } : [0, 0, 0, 0, 0]
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                Capsule().fill(WorkspaceStyle.localUsage.opacity(0.08))
                TokenMixBar(
                    f0: fractions[0], f1: fractions[1], f2: fractions[2], f3: fractions[3], f4: fractions[4],
                    colors: parts.map { $0.2.opacity(0.8) }
                )
                .animation(reduceMotion || range == nil ? nil : DashboardMotion.grow, value: range)
            }
            .frame(height: 5)
            .clipShape(Capsule())
            .accessibilityHidden(true)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 142), alignment: .leading)], alignment: .leading, spacing: 7) {
                ForEach(parts.indices, id: \.self) { i in
                    HStack(spacing: 5) {
                        Circle().fill(parts[i].2).frame(width: 5, height: 5)
                        Text(L(parts[i].0)).foregroundStyle(WorkspaceStyle.subtext)
                        DashboardRollingValue(text: compactTokens(parts[i].1), value: Double(parts[i].1),
                                              range: range, style: .caption2, themed: true)
                    }.font(.caption2)
                        .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private struct TokenMixBar: View, Animatable {
        var f0: Double
        var f1: Double
        var f2: Double
        var f3: Double
        var f4: Double
        let colors: [Color]

        nonisolated var animatableData: AnimatablePair<AnimatablePair<Double, Double>, AnimatablePair<AnimatablePair<Double, Double>, Double>> {
            get { AnimatablePair(AnimatablePair(f0, f1), AnimatablePair(AnimatablePair(f2, f3), f4)) }
            set {
                f0 = newValue.first.first
                f1 = newValue.first.second
                f2 = newValue.second.first.first
                f3 = newValue.second.first.second
                f4 = newValue.second.second
            }
        }

        var body: some View {
            Canvas { context, size in
                let values = [max(0, f0), max(0, f1), max(0, f2), max(0, f3), max(0, f4)]
                let sum = values.reduce(0, +)
                guard sum > 0, size.width > 0, size.height > 0 else { return }
                var x: CGFloat = 0
                for (index, value) in values.enumerated() where value > 0 {
                    let width = size.width * CGFloat(value / sum)
                    context.fill(Path(CGRect(x: x, y: 0, width: width + 0.5, height: size.height)),
                                 with: .color(colors[index]))
                    x += width
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
    var childModels: [String: [UsageGroup]] = [:]
    var toolReport: UsageReport? = nil
    var codexSubagents: CodexSubagentReport? = nil
    var antigravitySubagents: CodexSubagentReport? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false
    @State private var expandedTools: Set<String> = []
    private var sorted: [UsageGroup] {
        groups.sorted {
            let a = metric.amount(in: $0.summary) ?? -1
            let b = metric.amount(in: $1.summary) ?? -1
            return a == b ? $0.key < $1.key : a > b
        }
    }

    private struct SubagentBadgeSummary {
        let starts: Int64
        let tokens: Int64
        let cost: CodexSubagentCost?
    }

    private var modelSubagentSummaries: [String: SubagentBadgeSummary] {
        guard kind == .model else { return [:] }
        let conversations = [codexSubagents, antigravitySubagents]
            .compactMap { $0 }
            .flatMap(\.conversations)
        guard !conversations.isEmpty else { return [:] }
        var totals: [String: (starts: Int64, tokens: Int64, cost: Double, hasCost: Bool, unpriced: Int64)] = [:]
        for conversation in conversations {
            for agent in conversation.agents {
                for item in agent.models where item.tokens > 0 || (item.cost?.knownEstimatedCostUsd ?? 0) > 0 {
                    var entry = totals[item.model] ?? (0, 0, 0, false, 0)
                    entry.starts += agent.starts
                    entry.tokens += item.tokens
                    if let usd = item.cost?.knownEstimatedCostUsd {
                        entry.cost += usd
                        entry.hasCost = true
                    }
                    entry.unpriced += item.cost?.unpricedTokens ?? 0
                    totals[item.model] = entry
                }
            }
        }
        return totals.mapValues { entry in
            SubagentBadgeSummary(
                starts: entry.starts,
                tokens: entry.tokens,
                cost: entry.hasCost || entry.unpriced > 0
                    ? CodexSubagentCost(knownEstimatedCostUsd: entry.hasCost ? entry.cost : nil, unpricedTokens: entry.unpriced)
                    : nil
            )
        }
    }

    private func subagentReport(for group: UsageGroup) -> CodexSubagentReport? {
        guard kind == .tool else { return nil }
        return toolReport?.subagents(forTool: group.key)
    }

    private func subagentTitle(for group: UsageGroup) -> String {
        if kind == .tool && (group.key == "antigravity" || group.key == "antigravity-cli") {
            return L("subagents.antigravity_title")
        }
        return L("subagents.title")
    }

    private func subagentSummary(for group: UsageGroup, modelMap: [String: SubagentBadgeSummary]) -> SubagentBadgeSummary? {
        if let report = subagentReport(for: group) {
            return SubagentBadgeSummary(starts: report.starts, tokens: report.tokens, cost: report.cost)
        }
        if kind == .model, let modelSummary = modelMap[group.key] {
            return modelSummary
        }
        return nil
    }

    private func subagentShare(_ summary: SubagentBadgeSummary, in group: UsageGroup) -> Double? {
        switch metric {
        case .tokens:
            return subagentShareValue(Double(summary.tokens), of: Double(group.summary.tokens))
        case .cost:
            return subagentShareValue(summary.cost?.knownEstimatedCostUsd, of: group.summary.knownEstimatedCostUsd)
        }
    }

    private func subagentShareValue(_ amount: Double?, of total: Double?) -> Double? {
        guard let amount, let total, amount.isFinite, total.isFinite, total > 0 else { return nil }
        return amount / total
    }

    private func subagentMetricText(_ subagents: CodexSubagentReport) -> String {
        switch metric {
        case .tokens: compactTokens(subagents.tokens)
        case .cost: subagentCostText(subagents.cost)
        }
    }

    var body: some View {
        let total = groups.reduce(0.0) { $0 + (metric.amount(in: $1.summary) ?? 0) }
        let modelMap = modelSubagentSummaries
        VStack(alignment: .leading, spacing: kind == .tool ? 6 : 16) {
            Text(L(kind == .tool ? "field.tool" : "field.model"))
                .font(.headline).foregroundStyle(WorkspaceStyle.text).frame(height: 24)
            ForEach(expanded ? sorted : Array(sorted.prefix(5))) { group in
                let models = childModels[group.key] ?? []
                let subagents = subagentReport(for: group)
                let badgeSummary = subagentSummary(for: group, modelMap: modelMap)
                Group {
                    if !models.isEmpty || subagents != nil {
                        DisclosureGroup(isExpanded: Binding(
                            get: { expandedTools.contains(group.key) },
                            set: { if $0 { expandedTools.insert(group.key) } else { expandedTools.remove(group.key) } }
                        )) {
                            VStack(alignment: .leading, spacing: 8) {
                                if let subagents {
                                    subagentSummaryRow(subagents, in: group)
                                    if !models.isEmpty { Divider() }
                                }
                                if !models.isEmpty {
                                    modelRows(models)
                                }
                            }
                            .padding(.vertical, 8)
                        } label: {
                            rankingRow(group, total: total, badgeSummary: badgeSummary)
                        }
                        .disclosureGroupStyle(WorkspaceDisclosureStyle())
                    } else {
                        rankingRow(group, total: total, badgeSummary: badgeSummary)
                    }
                }
                .transition(.opacity)
            }
            if groups.count > 5 {
                Button {
                    DashboardMotion.withAnimation(DashboardMotion.disclosure, reduceMotion: reduceMotion) {
                        expanded.toggle()
                    }
                } label: {
                    Text(L(expanded ? "action.show_less" : "action.show_all"))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                }
                .buttonStyle(WorkspaceHoverStyle()).font(.caption).foregroundStyle(WorkspaceStyle.selection)
            }
            if groups.isEmpty { Text(L("usage.empty")).foregroundStyle(WorkspaceStyle.subtext).padding(.vertical, 24) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func modelRows(_ models: [UsageGroup]) -> some View {
        let ranked = models.sorted {
            let a = metric.amount(in: $0.summary) ?? -1, b = metric.amount(in: $1.summary) ?? -1
            return a == b ? $0.key < $1.key : a > b
        }
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(ranked) { model in
                let summary = model.summary
                let partial = metric == .cost && summary.costStatus == "partial"
                let text = metric == .tokens ? compactTokens(summary.tokens) : (partial ? "≈ " : "") + usd(metric.amount(in: summary))
                HStack(spacing: 8) {
                    BrandIcon(name: model.key, kind: .model, size: 14)
                    Text(model.key).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 5)
                    Text(text).monospacedDigit().fixedSize()
                }
                .font(.caption)
                .foregroundStyle(WorkspaceStyle.subtext)
                .accessibilityElement(children: .combine)
                .accessibilityHint(partial ? L("cost.known") : "")
            }
        }
    }

    private func subagentBadge(_ subagents: SubagentBadgeSummary, in group: UsageGroup) -> some View {
        let title = subagentTitle(for: group)
        let share = subagentShare(subagents, in: group)
        let partial = metric == .cost && ((subagents.cost?.unpricedTokens ?? 0) > 0 || group.summary.unpricedTokens > 0)
        let label = share.map { subagentShareText($0, partial: partial) }
            ?? subagents.starts.formatted(.number.locale(Localization.locale))
        return HStack(spacing: 3) {
            Image(systemName: "arrow.triangle.branch").font(.system(size: 9, weight: .semibold))
            Text(label).monospacedDigit()
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(WorkspaceStyle.selection)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(WorkspaceStyle.selection.opacity(0.11), in: Capsule())
        .fixedSize()
        .cursorTooltip(enabled: true) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch").foregroundStyle(WorkspaceStyle.selection)
                    Text(title).fontWeight(.semibold).foregroundStyle(WorkspaceStyle.text)
                    Spacer(minLength: 10)
                    Text(LF("subagents.started_value", subagents.starts.formatted(.number.locale(Localization.locale))))
                        .foregroundStyle(WorkspaceStyle.subtext)
                }
                HStack(spacing: 12) {
                    Text(compactTokens(subagents.tokens) + " Tokens").monospacedDigit().foregroundStyle(WorkspaceStyle.text)
                    Text(subagentCostText(subagents.cost)).monospacedDigit().foregroundStyle(WorkspaceStyle.subtext)
                    if let share {
                        Text(subagentShareText(share, partial: partial)).monospacedDigit().foregroundStyle(WorkspaceStyle.selection)
                    }
                }
            }
            .font(.caption)
            .fixedSize()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title + " " + label)
    }

    private func subagentSummaryRow(_ subagents: CodexSubagentReport, in group: UsageGroup) -> some View {
        let title = subagentTitle(for: group)
        let badge = SubagentBadgeSummary(starts: subagents.starts, tokens: subagents.tokens, cost: subagents.cost)
        let share = subagentShare(badge, in: group)
        let partial = metric == .cost && ((subagents.cost?.unpricedTokens ?? 0) > 0 || group.summary.unpricedTokens > 0)
        return HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(WorkspaceStyle.selection)
                .frame(width: 14, alignment: .center)
            Text(title)
                .foregroundStyle(WorkspaceStyle.text)
                .fontWeight(.medium)
            Text(LF("subagents.started_value", subagents.starts.formatted(.number.locale(Localization.locale))))
                .foregroundStyle(WorkspaceStyle.subtext)
            Spacer(minLength: 5)
            Text(subagentMetricText(subagents)).monospacedDigit().fixedSize()
                .foregroundStyle(WorkspaceStyle.text)
            if let share {
                Text(subagentShareText(share, partial: partial))
                    .monospacedDigit().fixedSize()
                    .foregroundStyle(WorkspaceStyle.subtext)
            }
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }

    private func rankingRow(_ group: UsageGroup, total: Double, badgeSummary: SubagentBadgeSummary?) -> some View {
        let summary = group.summary
        let amount = metric.amount(in: summary)
        let share = amount.map { total > 0 ? $0 / total : 0 }
        let remote = remoteGroups[group.key] ?? []
        let other = remote.reduce(0.0) { $0 + (metric.amount(in: $1.summary) ?? 0) }
        let otherFast = remote.reduce(0.0) { $0 + metric.fastAmount(in: $1.summary) }
        let fastText = metric.fastReadout(in: summary)
        return HStack(spacing: 10) {
            BrandIcon(name: group.key, kind: kind, size: 18)
            VStack(spacing: 7) {
                HStack(spacing: 6) {
                    Text(kind == .tool ? clientName(group.key) : group.key).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(WorkspaceStyle.text)
                    if let badgeSummary {
                        subagentBadge(badgeSummary, in: group)
                    }
                    Spacer(minLength: 8)
                    DashboardRollingValue(text: metric == .tokens ? compactTokens(summary.tokens) : usd(amount),
                                          value: amount, range: range, style: .callout, themed: true)
                }.font(.callout)
                OverviewShareBar(total: total, amount: amount ?? 0, other: other,
                                 fast: metric.fastAmount(in: summary), otherFast: otherFast, height: 5, range: range,
                                 formatValue: metric == .tokens ? { compactTokens(Int64($0.rounded())) } : { usd($0) })
            }
            DashboardRollingValue(text: share?.formatted(.percent.precision(.fractionLength(0))) ?? "—",
                                  value: share, range: range, style: .caption2, secondary: true, themed: true)
                .foregroundStyle(WorkspaceStyle.subtext).frame(width: 35, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(fastText ?? "")
    }

}
