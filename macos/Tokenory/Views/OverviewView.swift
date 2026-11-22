// [INPUT]: Selected-range report and independently loaded annual activity.
// [OUTPUT]: Rolling totals, tool and model rankings with Fast segments, range charts, and annual activity.
// [POS]: Native overview composition; disclosure keeps detailed caveats off the canvas.
// [PROTOCOL]: Update this header on change, then check AGENTS.md
import SwiftUI

struct OverviewView: View {
    let report: UsageReport
    let isActive: Bool
    let openDatePicker: () -> Void
    @Environment(UsageStore.self) private var store
    @Environment(\.colorScheme) private var colorScheme
    @State private var rankingMetric: UsageMetric = .tokens
    @State private var previousRange: (UsageDateRange, String?, String?)?
    @State private var scrolledAwayFromTop = false

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
                                    .buttonStyle(.plain).foregroundStyle(Color.accentColor).font(.caption)
                            }
                            WorkspacePanel {
                                VStack(alignment: .leading, spacing: 20) {
                                    if report.summary.recordCount > 0 {
                                        totals
                                        TokenMixView(tokens: report.summary.tokenBreakdown, range: range)
                                        Divider()
                                    }
                                    UsageTrendChart(report: report, filter: reportFilter,
                                                    animateRangeChanges: isActive, openDatePicker: openDatePicker)
                                }
                            }
                            if report.summary.recordCount > 0 {
                                let layout = geometry.size.width >= 720
                                    ? AnyLayout(HStackLayout(alignment: .top, spacing: 18))
                                    : AnyLayout(VStackLayout(alignment: .leading, spacing: 18))
                                WorkspacePanel {
                                    VStack(alignment: .leading, spacing: 16) {
                                        HStack(spacing: 12) {
                                            Picker(L("overview.sort"), selection: $rankingMetric) {
                                                ForEach(UsageMetric.allCases, id: \.self) { Text($0.title).tag($0) }
                                            }.labelsHidden().pickerStyle(.segmented).fixedSize()
                                            Spacer()
                                            if rankingMetric.fastAmount(in: report.summary) > 0 {
                                                HStack(spacing: 5) {
                                                    Capsule().fill(WorkspaceStyle.fastUsage(colorScheme)).frame(width: 10, height: 3)
                                                        .accessibilityHidden(true)
                                                    Text(L("fast.title")).font(.caption).foregroundStyle(.secondary)
                                                }
                                            }
                                        }
                                        Divider()
                                        layout {
                                            UsageRankingView(groups: report.clients, kind: .tool, metric: rankingMetric, range: range)
                                            UsageRankingView(groups: report.models, kind: .model, metric: rankingMetric, range: range)
                                        }
                                    }
                                }
                            }
                            if let activity = store.activity, !activity.daily.isEmpty, let calendar = store.activityCalendar {
                                UsageActivityView(report: activity, activity: calendar) { day in
                                    if previousRange == nil { previousRange = (store.dateRange, store.filter.from, store.filter.to) }
                                    store.dateRange = .custom
                                    var filter = store.filter; filter.from = day; filter.to = day; filter.offset = 0
                                    store.filter = filter
                                }
                                UsageHabitsView(report: activity, activity: calendar, horizontal: geometry.size.width >= 760)
                                UsageHistoryChart(report: activity)
                            }
                        }.padding(.horizontal, 22).padding(.bottom, 22).padding(.top, 4)
                    }
                }
                .onScrollGeometryChange(for: Bool.self) {
                    $0.contentOffset.y + $0.contentInsets.top > 8
                } action: { _, away in
                    scrolledAwayFromTop = away
                }
                .onChange(of: reportFilter) { old, new in
                    if scrolledAwayFromTop, old.from != new.from || old.to != new.to {
                        proxy.scrollTo("overview-top", anchor: .top)
                    }
                }
            }
        }
    }
    private func restoreRange() {
        guard let previousRange else { return }
        store.dateRange = previousRange.0
        var filter = store.filter; filter.from = previousRange.1; filter.to = previousRange.2; filter.offset = 0
        store.filter = filter; store.updateDateRange(); self.previousRange = nil
    }
    private var totals: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 28) { mainTotals; secondaryTotals }
                VStack(alignment: .leading, spacing: 18) { mainTotals; secondaryTotals }
            }
            if let fastTokens = report.summary.fastTokens, fastTokens > 0 {
                FastModeMark(title: LF("fast.tokens", compactTokens(fastTokens)), helpText: L("fast.tokens_help"))
            }
        }
    }
    private var mainTotals: some View {
        HStack(alignment: .top, spacing: 28) {
            metric(L("usage.tokens"), compactTokens(report.summary.tokens), amount: report.summary.tokens, large: true)
                .help(report.summary.tokens.formatted(.number.locale(Localization.locale)))
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 3) {
                    Text(L(report.summary.costStatus == "partial" ? "cost.known" : "cost.estimate"))
                        .font(.subheadline).foregroundStyle(.secondary)
                    WorkspaceInfoPopover(title: L("overview.cost_info")) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L("overview.cost_help"))
                            if report.summary.unpricedTokens > 0 {
                                Text(LF("usage.unpriced", compactTokens(report.summary.unpricedTokens)))
                            }
                            if let partialDays = report.summary.partialDays, partialDays > 0 {
                                Text(LF("usage.partial_days", partialDays))
                            }
                        }
                        .padding(16)
                        .frame(width: 280, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                DashboardRollingValue(text: usd(report.summary.knownEstimatedCostUsd), value: report.summary.knownEstimatedCostUsd,
                                      range: range, style: .semibold(32))
                    .lineLimit(1).minimumScaleFactor(0.7)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var secondaryTotals: some View {
        HStack(spacing: 24) {
            let filter = reportFilter
            if filter.from == nil || filter.from != filter.to {
                metric(L("overview.active_days"), report.summary.activeDays.formatted(), amount: report.summary.activeDays, large: false)
            }
            let modelsUsed = Int64(report.models.filter { $0.summary.tokens > 0 }.count)
            metric(L("overview.models"), modelsUsed.formatted(), amount: modelsUsed, large: false)
        }.fixedSize(horizontal: true, vertical: false)
    }
    private func metric(_ label: String, _ value: String, amount: Int64, large: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            DashboardRollingValue(text: value, value: Double(amount), range: range, style: .semibold(large ? 32 : 23))
                .lineLimit(1).minimumScaleFactor(0.7)
        }.frame(maxWidth: large ? .infinity : nil, alignment: .leading).accessibilityElement(children: .combine)
    }
}

private struct TokenMixView: View {
    let tokens: TokenBreakdown
    let range: DashboardDateSpan?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var parts: [(String, Int64, Color)] {
        [("token.input", tokens.input, .blue), ("token.output", tokens.output, WorkspaceStyle.outputTokens),
         ("token.cache_read", tokens.cacheRead, .orange), ("token.cache_write", tokens.cacheWrite, .purple),
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
                        Text(L(parts[i].0)).foregroundStyle(.secondary)
                        DashboardRollingValue(text: compactTokens(parts[i].1), value: Double(parts[i].1),
                                              range: range, style: .caption2)
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
    let kind: BrandKind
    let metric: UsageMetric
    let range: DashboardDateSpan?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                .font(.headline).frame(height: 24)
            ForEach(expanded ? sorted : Array(sorted.prefix(5))) { group in
                rankingRow(group, total: total)
            }
            if groups.count > 5 {
                Button(L(expanded ? "action.show_less" : "action.show_all")) { expanded.toggle() }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(Color.accentColor)
            }
            if groups.isEmpty { Text(L("usage.empty")).foregroundStyle(.secondary).padding(.vertical, 24) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rankingRow(_ group: UsageGroup, total: Double) -> some View {
        let summary = group.summary
        let amount = metric.amount(in: summary)
        let share = amount.map { total > 0 ? $0 / total : 0 }
        let fastShare = total > 0 ? metric.fastAmount(in: summary) / total : 0
        let fastText = metric.fastReadout(in: summary)
        let costText = L(summary.costStatus == "partial" ? "cost.known" : "cost.estimate") + ": " + usd(summary.knownEstimatedCostUsd)
        return HStack(spacing: 10) {
            BrandIcon(name: group.key, kind: kind, size: 18)
            VStack(spacing: 7) {
                HStack {
                    Text(kind == .tool ? clientName(group.key) : group.key).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    DashboardRollingValue(text: metric == .tokens ? compactTokens(summary.tokens) : usd(amount),
                                          value: amount, range: range, style: .callout)
                }.font(.callout)
                rankingBar(share: share ?? 0, fastShare: fastShare)
            }
            DashboardRollingValue(text: share?.formatted(.percent.precision(.fractionLength(0))) ?? "—",
                                  value: share, range: range, style: .caption2, secondary: true)
                .foregroundStyle(.secondary).frame(width: 35, alignment: .trailing)
        }
        .help([group.key, costText, fastText].compactMap { $0 }.joined(separator: "\n"))
        .accessibilityElement(children: .combine)
        .accessibilityValue(fastText ?? "")
    }

    private func rankingBar(share: Double, fastShare: Double) -> some View {
        let filled = min(max(share, 0), 1)
        let highlighted = min(max(fastShare, 0), filled)
        return GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.accentColor.opacity(0.08))
                HStack(spacing: 0) {
                    Rectangle().fill(Color.accentColor.opacity(0.65))
                        .frame(width: geometry.size.width * (filled - highlighted))
                    Rectangle().fill(WorkspaceStyle.fastUsage(colorScheme))
                        .frame(width: geometry.size.width * highlighted)
                }
                .clipShape(Capsule())
                .animation(reduceMotion || range == nil ? nil : DashboardMotion.grow, value: range)
            }
        }.frame(height: 3).accessibilityHidden(true)
    }
}
