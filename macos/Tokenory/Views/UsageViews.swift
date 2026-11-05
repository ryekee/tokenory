import SwiftUI

func compactTokens(_ value: Int64) -> String { value.formatted(.number.notation(.compactName).precision(.fractionLength(0...2))) }
func usd(_ value: Double?) -> String { value.map { $0.formatted(.currency(code: "USD").precision(.fractionLength(2...4))) } ?? "待计价" }
func clientName(_ value: String) -> String { ["claude": "Claude Code", "codex": "Codex", "micode": "MiCode", "copilot": "Copilot", "cline": "Cline"][value] ?? value }

struct SummaryView: View {
    let summary: UsageSummary
    var compact = false
    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 12 : 20) {
            HStack(alignment: .firstTextBaseline, spacing: 24) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Tokens").font(.subheadline).foregroundStyle(.secondary)
                    Text(compactTokens(summary.tokens)).font(compact ? .system(size: 32, weight: .semibold, design: .rounded) : .system(size: 38, weight: .semibold, design: .rounded)).monospacedDigit().help(summary.tokens.formatted())
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 5) {
                    Text(summary.costStatus == "partial" ? "已知估算" : "API 估算").font(.subheadline).foregroundStyle(.secondary)
                    Text(usd(summary.knownEstimatedCostUsd)).font(compact ? .title2 : .title).monospacedDigit()
                }
            }
            if let partial = summary.partialDays, partial > 0 { Label("\(partial) 天只包含部分记录", systemImage: "clock.badge.exclamationmark").font(.caption).foregroundStyle(.secondary) }
            if summary.unpricedTokens > 0 {
                Label("\(compactTokens(summary.unpricedTokens)) tokens 待计价", systemImage: "circle.dotted").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
struct UsageGroupList: View {
    let title: String
    let groups: [UsageGroup]
    var isClient = false
    var body: some View {
        GroupBox(title) {
            VStack(spacing: 12) {
                ForEach(groups) { group in
                    HStack {
                        Text(isClient ? clientName(group.key) : group.key).lineLimit(2).textSelection(.enabled)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 3) {
                            Text(compactTokens(group.summary.tokens)).monospacedDigit()
                            Text(usd(group.summary.knownEstimatedCostUsd)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if groups.isEmpty { Text("此范围暂无记录").foregroundStyle(.secondary).frame(maxWidth: .infinity) }
            }.padding(10)
        }
    }
}
struct ErrorBanner: View {
    @Environment(UsageStore.self) private var store
    var body: some View {
        if let error = store.error {
            HStack(alignment: .top) {
                Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                Text(error).font(.callout).textSelection(.enabled)
                Spacer()
                Button { store.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("关闭错误提示")
            }.padding(12).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}
