import SwiftUI
import Charts

struct OverviewView: View {
    let report: UsageReport
    @Environment(UsageStore.self) private var store

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    WorkspacePanel {
                        VStack(alignment: .leading, spacing: 16) {
                            totals
                            Divider().opacity(0.6)
                            UsageTrendChart(report: report, filter: store.reportFilter ?? store.filter)
                        }
                    }
                    let layout = geometry.size.width >= 720
                        ? AnyLayout(HStackLayout(alignment: .top, spacing: 14))
                        : AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
                    layout {
                        ToolDistributionView(groups: report.clients)
                            .frame(maxWidth: geometry.size.width >= 720 ? 310 : .infinity)
                        ModelRankingView(groups: report.models)
                    }
                }
                .padding(.horizontal, 22).padding(.bottom, 22).padding(.top, 4)
            }
        }
    }

    private var totals: some View {
        HStack(alignment: .top, spacing: 32) {
            VStack(alignment: .leading, spacing: 7) {
                Text(L("usage.tokens")).font(.subheadline).foregroundStyle(.secondary)
                Text(compactTokens(report.summary.tokens))
                    .font(.system(size: 32, weight: .semibold)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.75)
                    .help(report.summary.tokens.formatted(.number.locale(Localization.locale)))
                if let partial = report.summary.partialDays, partial > 0 {
                    Label(LF("usage.partial_days", partial), systemImage: "clock.badge.exclamationmark")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 7) {
                Text(L(report.summary.costStatus == "partial" ? "cost.known" : "cost.estimate"))
                    .font(.subheadline).foregroundStyle(.secondary)
                Text(usd(report.summary.knownEstimatedCostUsd))
                    .font(.system(size: 32, weight: .semibold)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.75)
                if report.summary.unpricedTokens > 0 {
                    Label(LF("usage.unpriced", compactTokens(report.summary.unpricedTokens)), systemImage: "circle.dotted")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ToolDistributionView: View {
    let groups: [UsageGroup]
    private var total: Double { groups.reduce(0) { $0 + Double($1.summary.tokens) } }

    var body: some View {
        WorkspacePanel {
            VStack(alignment: .leading, spacing: 18) {
                Text(L("usage.by_tool")).font(.headline)
                if total > 0 {
                    HStack(spacing: 18) {
                        Chart(groups) { group in
                            SectorMark(angle: .value(L("usage.tokens"), group.summary.tokens),
                                       innerRadius: .ratio(0.78), angularInset: groups.count > 1 ? 3 : 0)
                                .cornerRadius(3)
                                .foregroundStyle(WorkspaceStyle.toolColor(group.key))
                                .accessibilityLabel(clientName(group.key))
                                .accessibilityValue(compactTokens(group.summary.tokens))
                        }
                        .frame(width: 96, height: 96)
                        .accessibilityLabel(L("usage.by_tool"))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(compactTokens(Int64(total))).font(.system(size: 20, weight: .semibold)).monospacedDigit()
                            Text(L("usage.tokens")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    VStack(spacing: 14) {
                        ForEach(groups) { group in
                            HStack(alignment: .top, spacing: 8) {
                                BrandIcon(name: group.key, kind: .tool).foregroundStyle(WorkspaceStyle.toolColor(group.key)).padding(.top, 2)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(clientName(group.key)).font(.callout)
                                    Text(usd(group.summary.knownEstimatedCostUsd))
                                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                }
                                Spacer(minLength: 4)
                                VStack(alignment: .trailing, spacing: 4) {
                                    Text((Double(group.summary.tokens) / total).formatted(.percent.precision(.fractionLength(0...1)).locale(Localization.locale)))
                                        .font(.callout).monospacedDigit()
                                    Text(compactTokens(group.summary.tokens)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                }
                            }.accessibilityElement(children: .combine)
                        }
                    }
                } else {
                    Text(L("usage.empty")).foregroundStyle(.secondary).padding(.vertical, 30)
                }
            }
        }
    }
}

private struct ModelRankingView: View {
    let groups: [UsageGroup]
    @State private var expanded = false
    private var sorted: [UsageGroup] { groups.sorted { $0.summary.tokens > $1.summary.tokens } }
    private var total: Double { groups.reduce(0) { $0 + Double($1.summary.tokens) } }

    var body: some View {
        WorkspacePanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(L("usage.by_model")).font(.headline)
                    Spacer()
                    if groups.count > 5 {
                        Button(L(expanded ? "action.show_less" : "action.show_all")) { expanded.toggle() }
                            .buttonStyle(.plain).font(.caption).foregroundStyle(Color.accentColor)
                    }
                }
                ForEach(expanded ? sorted : Array(sorted.prefix(5))) { group in
                    VStack(spacing: 6) {
                        HStack {
                            BrandLabel(name: group.key, kind: .model).lineLimit(1).truncationMode(.middle).help(group.key)
                            Spacer(minLength: 8)
                            Text(compactTokens(group.summary.tokens)).monospacedDigit()
                        }.font(.callout)
                        HStack(spacing: 16) {
                            GeometryReader { geometry in
                                Capsule().fill(Color.accentColor.opacity(0.09))
                                Capsule().fill(Color.accentColor.opacity(0.65))
                                    .frame(width: total > 0 ? geometry.size.width * Double(group.summary.tokens) / total : 0)
                            }.frame(height: 4).accessibilityHidden(true)
                            Text(usd(group.summary.knownEstimatedCostUsd))
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                .frame(minWidth: 72, alignment: .trailing)
                        }
                    }.accessibilityElement(children: .combine)
                }
                if groups.isEmpty {
                    Text(L("usage.empty")).foregroundStyle(.secondary).padding(.vertical, 30)
                }
            }
        }
    }
}
