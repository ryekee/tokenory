import SwiftUI

func compactTokens(_ value: Int64, locale: Locale = Localization.locale) -> String {
    // Compact notation suppresses grouping in Chinese (1740.69万). Keep the
    // familiar units while formatting their numeric part with comma separators.
    let units: [(Double, String)] = locale.identifier.hasPrefix("zh")
        ? [(1e12, "万亿"), (1e8, "亿"), (1e4, "万")]
        : [(1e12, "T"), (1e9, "B"), (1e6, "M"), (1e3, "K")]
    let unit = units.first { Double(value) >= $0.0 } ?? (1, "")
    return (Double(value) / unit.0).formatted(.number.precision(.fractionLength(0...2)).locale(Locale(identifier: "en_US"))) + unit.1
}
func usd(_ value: Double?) -> String {
    value.map { "$" + $0.formatted(.number.precision(.fractionLength(2)).locale(Locale(identifier: "en_US"))) } ?? L("cost.unavailable")
}
func clientName(_ value: String) -> String {
    ["amp": "Amp", "antigravity": "Antigravity", "antigravity-cli": "Antigravity CLI",
     "claude": "Claude Code", "cline": "Cline", "codebuddy": "CodeBuddy", "codebuff": "Codebuff",
     "codex": "Codex", "commandcode": "Command Code", "copilot": "Copilot", "crush": "Crush", "cursor": "Cursor",
     "devin-cli": "Devin CLI", "devin-desktop": "Devin Desktop", "droid": "Droid", "fx": "Fx",
     "gemini": "Gemini CLI", "goose": "Goose", "grok": "Grok Build", "hermes": "Hermes Agent",
     "jcode": "Jcode", "junie": "Junie", "kilocode": "Kilo", "kilo": "Kilo CLI", "kimi": "Kimi", "kiro": "Kiro",
     "micode": "MiMo Code", "mux": "Mux", "openclaw": "OpenClaw", "opencode": "OpenCode", "opencodereview": "OpenCodeReview",
     "pi": "Pi", "qwen": "Qwen", "reasonix": "Reasonix", "roocode": "Roo Code", "paseo": "Paseo", "orca": "Orca",
     "trae": "Trae", "warp": "Warp", "workbuddy": "WorkBuddy", "zcode": "ZCode", "zed": "Zed Agent"][value] ?? value
}

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
