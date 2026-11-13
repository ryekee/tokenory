// [INPUT]: Selected-range report and independently loaded annual activity.
// [OUTPUT]: Compact overview, token mix, rankings, calendar and model history.
// [POS]: Native overview composition; disclosure keeps detailed caveats off the canvas.
// [PROTOCOL]: Update this header on change, then check AGENTS.md
import SwiftUI

struct OverviewView: View {
    let report: UsageReport
    @Environment(UsageStore.self) private var store
    @State private var rankingMetric: UsageMetric = .tokens
    @State private var previousRange: (UsageDateRange, String?, String?)?

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    Color.clear.frame(height: 0).id("overview-top")
                    if previousRange != nil {
                        Button { restoreRange() } label: { Label(L("overview.back"), systemImage: "arrow.left") }
                            .buttonStyle(.plain).foregroundStyle(Color.accentColor).font(.caption)
                    }
                    WorkspacePanel {
                        VStack(alignment: .leading, spacing: 20) {
                            totals
                            TokenMixView(tokens: report.summary.tokenBreakdown)
                            Divider()
                            UsageTrendChart(report: report, filter: store.reportFilter ?? store.filter)
                        }
                    }
                    let layout = geometry.size.width >= 720
                        ? AnyLayout(HStackLayout(alignment: .top, spacing: 18))
                        : AnyLayout(VStackLayout(alignment: .leading, spacing: 18))
                    WorkspacePanel {
                        VStack(alignment: .leading, spacing: 16) {
                            Picker(L("overview.sort"), selection: $rankingMetric) {
                                ForEach(UsageMetric.allCases, id: \.self) { Text($0.title).tag($0) }
                            }.labelsHidden().pickerStyle(.segmented).fixedSize()
                            Divider()
                            layout {
                                UsageRankingView(groups: report.clients, kind: .tool, metric: rankingMetric)
                                UsageRankingView(groups: report.models, kind: .model, metric: rankingMetric)
                            }
                        }
                    }
                    if let activity = store.activity, let calendar = store.activityCalendar {
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
            }.onChange(of: store.filter.from) { _, _ in proxy.scrollTo("overview-top", anchor: .top) }
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
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 28) { mainTotals; secondaryTotals }
            VStack(alignment: .leading, spacing: 18) { mainTotals; secondaryTotals }
        }
    }
    private var mainTotals: some View {
        HStack(alignment: .top, spacing: 28) {
            metric(L("usage.tokens"), compactTokens(report.summary.tokens), large: true)
                .help(report.summary.tokens.formatted(.number.locale(Localization.locale)))
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Text(L(report.summary.costStatus == "partial" ? "cost.known" : "cost.estimate"))
                        .font(.subheadline).foregroundStyle(.secondary)
                    if report.summary.unpricedTokens > 0 || (report.summary.partialDays ?? 0) > 0 {
                        Image(systemName: "info.circle").foregroundStyle(.secondary)
                            .help([report.summary.unpricedTokens > 0 ? LF("usage.unpriced", compactTokens(report.summary.unpricedTokens)) : nil,
                                   (report.summary.partialDays ?? 0) > 0 ? LF("usage.partial_days", report.summary.partialDays!) : nil]
                                .compactMap { $0 }.joined(separator: "\n"))
                    }
                }
                Text(usd(report.summary.knownEstimatedCostUsd)).font(.system(size: 32, weight: .semibold)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.7)
            }.frame(maxWidth: .infinity, alignment: .leading).help(L("overview.cost_help"))
        }
    }
    private var secondaryTotals: some View {
        HStack(spacing: 24) {
            metric(L("overview.active_days"), report.summary.activeDays.formatted(), large: false)
            metric(L("overview.models"), report.models.filter { $0.summary.tokens > 0 }.count.formatted(), large: false)
        }.fixedSize(horizontal: true, vertical: false)
    }
    private func metric(_ label: String, _ value: String, large: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            Text(value).font(.system(size: large ? 32 : 23, weight: .semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
        }.frame(maxWidth: large ? .infinity : nil, alignment: .leading).accessibilityElement(children: .combine)
    }
}

private struct TokenMixView: View {
    let tokens: TokenBreakdown
    private var parts: [(String, Int64, Color)] {
        [("token.input", tokens.input, .blue), ("token.output", tokens.output, .teal),
         ("token.cache_read", tokens.cacheRead, .orange), ("token.cache_write", tokens.cacheWrite, .purple),
         ("token.reasoning", tokens.reasoning, .gray)]
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
                }.clipShape(Capsule())
            }.frame(height: 5).accessibilityHidden(true)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 142), alignment: .leading)], alignment: .leading, spacing: 7) {
                ForEach(parts.indices, id: \.self) { i in
                    HStack(spacing: 5) {
                        Circle().fill(parts[i].2).frame(width: 5, height: 5)
                        Text(L(parts[i].0)).foregroundStyle(.secondary)
                        Text(compactTokens(parts[i].1)).monospacedDigit()
                    }.font(.caption2).help(total > 0 ? (Double(parts[i].1) / Double(total)).formatted(.percent.precision(.fractionLength(1))) : "0%")
                        .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

private struct UsageRankingView: View {
    let groups: [UsageGroup]
    let kind: BrandKind
    let metric: UsageMetric
    @State private var expanded = false
    private var sorted: [UsageGroup] {
        groups.sorted {
            let a = metric == .tokens ? Double($0.summary.tokens) : $0.summary.knownEstimatedCostUsd ?? -1
            let b = metric == .tokens ? Double($1.summary.tokens) : $1.summary.knownEstimatedCostUsd ?? -1
            return a == b ? $0.key < $1.key : a > b
        }
    }
    var body: some View {
        let total = groups.reduce(0.0) { $0 + (metric == .tokens ? Double($1.summary.tokens) : $1.summary.knownEstimatedCostUsd ?? 0) }
        VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(L(kind == .tool ? "usage.by_tool" : "usage.by_model")).font(.headline)
                    Spacer()

                }.frame(height: 24)
                ForEach(expanded ? sorted : Array(sorted.prefix(5))) { group in
                    let amount = metric == .tokens ? Double(group.summary.tokens) : group.summary.knownEstimatedCostUsd
                    HStack(spacing: 10) {
                        BrandIcon(name: group.key, kind: kind, size: 18)
                        VStack(spacing: 7) {
                            HStack {
                                Text(kind == .tool ? clientName(group.key) : group.key).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 8)
                                Text(metric == .tokens ? compactTokens(group.summary.tokens) : usd(amount)).monospacedDigit()
                            }.font(.callout)
                            GeometryReader { geometry in
                                Capsule().fill(Color.accentColor.opacity(0.08))
                                Capsule().fill(Color.accentColor.opacity(0.65))
                                    .frame(width: total > 0 ? geometry.size.width * (amount ?? 0) / total : 0)
                            }.frame(height: 3).accessibilityHidden(true)
                        }
                        Text(amount == nil ? "—" : (total > 0 ? (amount! / total).formatted(.percent.precision(.fractionLength(0))) : "0%"))
                            .font(.caption2).foregroundStyle(.secondary).monospacedDigit().frame(width: 35, alignment: .trailing)
                    }.help(group.key + "\n" + L(group.summary.costStatus == "partial" ? "cost.known" : "cost.estimate") + ": " + usd(group.summary.knownEstimatedCostUsd))
                        .accessibilityElement(children: .combine)
                }
                if groups.count > 5 {
                    Button(L(expanded ? "action.show_less" : "action.show_all")) { expanded.toggle() }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(Color.accentColor)
                }
                if groups.isEmpty { Text(L("usage.empty")).foregroundStyle(.secondary).padding(.vertical, 24) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
