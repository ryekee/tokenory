import SwiftUI

func compactTokens(_ value: Int64) -> String { value.formatted(.number.notation(.compactName).precision(.fractionLength(0...2)).locale(Localization.locale)) }
func usd(_ value: Double?, detailed: Bool = false) -> String {
    value.map { $0.formatted(.currency(code: "USD").precision(.fractionLength(detailed ? 2...6 : 2...2)).locale(Localization.locale)) } ?? L("cost.unavailable")
}
func clientName(_ value: String) -> String { ["claude": "Claude Code", "codex": "Codex", "micode": "MiCode", "copilot": "Copilot", "cline": "Cline"][value] ?? value }

struct SummaryView: View {
    let summary: UsageSummary
    var compact = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: compact ? 20 : 36) {
                metric(L("usage.tokens"), compactTokens(summary.tokens))
                    .help(summary.tokens.formatted(.number.locale(Localization.locale)))
                if !compact { Divider().frame(height: 50) }
                metric(L(summary.costStatus == "partial" ? "cost.known" : "cost.estimate"), usd(summary.knownEstimatedCostUsd))
                if !compact { Spacer(minLength: 0) }
            }
            if let partial = summary.partialDays, partial > 0 {
                Label(LF("usage.partial_days", partial), systemImage: "clock.badge.exclamationmark").font(.caption).foregroundStyle(.secondary)
            }
            if summary.unpricedTokens > 0 {
                Label(LF("usage.unpriced", compactTokens(summary.unpricedTokens)), systemImage: "circle.dotted").font(.caption).foregroundStyle(.secondary)
            }
        }.accessibilityElement(children: .contain)
    }
    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Text(value).font(.system(size: compact ? 25 : 30, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }.accessibilityElement(children: .combine)
    }
}
struct UsageGroupList: View {
    let title: String
    let groups: [UsageGroup]
    var isClient = false
    @State private var expanded = false
    private var visible: [UsageGroup] { expanded ? groups : Array(groups.prefix(8)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.headline).padding(.bottom, 12)
            ForEach(visible) { group in
                HStack(spacing: 12) {
                    Text(isClient ? clientName(group.key) : group.key).lineLimit(1).truncationMode(.middle).help(group.key)
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(compactTokens(group.summary.tokens)).monospacedDigit()
                        Text(usd(group.summary.knownEstimatedCostUsd)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }.padding(.vertical, 10)
                Divider()
            }
            if groups.count > 8 {
                Button(L(expanded ? "action.show_less" : "action.show_all")) { expanded.toggle() }.buttonStyle(.link).padding(.top, 12)
            }
            if groups.isEmpty { Text(L("usage.empty")).foregroundStyle(.secondary).padding(.vertical, 20) }
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
struct ErrorBanner: View {
    @Environment(UsageStore.self) private var store
    var body: some View {
        if let error = store.error {
            HStack(alignment: .top) {
                Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("error.operation")).font(.callout)
                    DisclosureGroup(L("error.details")) { Text(error).font(.caption).textSelection(.enabled) }
                }
                Spacer()
                Button { store.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel(L("action.dismiss_error"))
            }.padding(12).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8)).padding(.top, 8)
        }
    }
}
