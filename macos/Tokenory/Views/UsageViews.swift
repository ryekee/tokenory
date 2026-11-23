// [INPUT]: Typed usage summaries and today-only turn statistics.
// [OUTPUT]: Locale-aware formats, device legend and focus-aware toolbar switch, source and Fast shares, and three-column menu summary.
// [POS]: Shared native usage presentation; speed does not depend on dashboard filters.
// [PROTOCOL]: Update this header on change, then check AGENTS.md
import SwiftUI

struct FastModeMark: View {
    var title: String? = nil
    let helpText: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "bolt.fill")
            if let title { Text(title).monospacedDigit() }
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .fixedSize()
        .help(helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title ?? L("fast.title"))
        .accessibilityHint(helpText)
    }
}

extension InferenceSpeed {
    var fastHelp: String { L(source == "selected" ? "fast.selected_help" : "fast.reported_help") }
}

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
     "trae": "Trae", "trae-cli": "TRAE CLI", "warp": "Warp", "workbuddy": "WorkBuddy", "zcode": "ZCode", "zed": "Zed Agent"][value] ?? value
}

struct MenuBarSummary: View {
    let summary: UsageSummary
    let turns: TurnPresentation?
    let speedError: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                metric(L("usage.tokens"), compactTokens(summary.tokens))
                    .help(summary.tokens.formatted(.number.locale(Localization.locale)))
                metric(L("menubar.cost"), usd(summary.knownEstimatedCostUsd))
                    .help(L(summary.costStatus == "partial" ? "cost.known" : "cost.estimate"))
                metric(L("menubar.speed"), (turns?.containsEstimates == true ? "≈ " : "") + TurnFormat.number(turns?.averageSpeed), unit: turns?.averageSpeed == nil ? "" : "tokens/s")
                    .help(speedError ?? L("turns.average_speed_help"))
            }
            if let partial = summary.partialDays, partial > 0 {
                Label(LF("usage.partial_days", partial), systemImage: "clock.badge.exclamationmark").font(.caption).foregroundStyle(.secondary)
            }
            if summary.unpricedTokens > 0 {
                Label(LF("usage.unpriced", compactTokens(summary.unpricedTokens)), systemImage: "circle.dotted").font(.caption).foregroundStyle(.secondary)
            }
        }.accessibilityElement(children: .contain)
    }
    private func metric(_ title: String, _ value: String, unit: String = "") -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            (Text(value).font(.system(size: 25, weight: .semibold)) + Text(unit.isEmpty ? "" : " " + unit).font(.caption).foregroundColor(.secondary))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
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

extension UsageReport {
    var overviewModelCount: Int {
        Set(models.lazy.filter { $0.summary.tokens > 0 }.map(\.key)).count
    }
}

// IDs come from the device registry. Different Macs can share the same display name.
struct OverviewDeviceRow: Identifiable {
    let id: String
    let name: String
    let summary: UsageSummary?
    var models: Int?

    var tokens: String { (summary?.tokens ?? 0).formatted(.number.locale(Localization.locale)) }
    var cost: String {
        guard let summary, summary.tokens != 0 || summary.knownEstimatedCostUsd != nil || summary.unpricedTokens > 0 else { return usd(0) }
        return (summary.unpricedTokens > 0 && summary.knownEstimatedCostUsd != nil ? "≈ " : "") + usd(summary.knownEstimatedCostUsd)
    }
}

struct OverviewDeviceReadout: View {
    let rows: [OverviewDeviceRow]

    init(rows: [OverviewDeviceRow]) {
        self.rows = rows.sorted { left, right in
            (Self.position(left.id), left.name, left.id) < (Self.position(right.id), right.name, right.id)
        }
    }

    private static func position(_ id: String) -> Int {
        switch id {
        case "total": 0
        case "local": 1
        default: 2
        }
    }

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
            GridRow {
                Color.clear.frame(width: 1, height: 1)
                Text("Tokens").gridColumnAlignment(.trailing)
                Text("USD").gridColumnAlignment(.trailing)
                if rows.first?.models != nil { Text(L("overview.models")).gridColumnAlignment(.trailing) }
            }.font(.caption2).foregroundStyle(WorkspaceStyle.subtext)
            ForEach(rows) { row in
                GridRow {
                    Text(row.name).lineLimit(1).truncationMode(.middle)
                    Text(row.tokens)
                    Text(row.cost)
                    if let models = row.models { Text(models.formatted(.number.locale(Localization.locale))) }
                }
                .fontWeight(row.id == "total" ? .semibold : .regular)
                .accessibilityElement(children: .combine)
            }
        }.monospacedDigit().font(.caption)
    }
}

struct OverviewDeviceLegend: View {
    static let swatchWidth: CGFloat = 8
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        HStack(spacing: 10) {
            swatch(WorkspaceStyle.localUsage, "cloud.overview.local")
            swatch(WorkspaceStyle.otherDevices(scheme), "cloud.overview.others")
        }
    }
    private func swatch(_ color: Color, _ key: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1).fill(color).frame(width: Self.swatchWidth, height: Self.swatchWidth)
            Text(L(key))
        }.font(.caption).foregroundStyle(WorkspaceStyle.subtext)
    }
}

struct OverviewLocalToggle: View {
    @Environment(\.appearsActive) private var appearsActive
    @Binding var localOnly: Bool
    var body: some View {
        HStack(spacing: 6) {
            Text(L("cloud.overview.localOnly")).font(.callout)
                .foregroundStyle(appearsActive ? Color.primary : Color(nsColor: .disabledControlTextColor))
                .onTapGesture { localOnly.toggle() }
                .accessibilityHidden(true)
            Toggle(L("cloud.overview.localOnly"), isOn: $localOnly)
                .toggleStyle(.switch).labelsHidden().controlSize(.small)
        }
        .padding(.horizontal, 10)
        .fixedSize()
    }
}

// Disjoint fractions of one ranking total, ordered by device and then service mode.
struct OverviewShareSegments: Equatable {
    let localStandard: Double
    let localFast: Double
    let otherStandard: Double
    let otherFast: Double

    init(total: Double, amount: Double, other: Double, fast: Double = 0, otherFast: Double = 0) {
        let divisor = total > 0 ? total : 1
        let used = min(max(0, amount), max(0, total))
        let remote = min(max(0, other), used)
        let local = used - remote
        let allFast = min(max(0, fast), used)
        let reportedRemoteFast = min(max(0, otherFast), allFast)
        let remoteFast = min(reportedRemoteFast, remote)
        let localFast = min(allFast - reportedRemoteFast, local)
        localStandard = (local - localFast) / divisor
        self.localFast = localFast / divisor
        otherStandard = (remote - remoteFast) / divisor
        self.otherFast = remoteFast / divisor
    }
}

struct OverviewShareBar: View {
    let total: Double
    let amount: Double
    let other: Double
    var fast: Double = 0
    var otherFast: Double = 0
    var height: CGFloat = 4
    var range: DashboardDateSpan? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shares = OverviewShareSegments(total: total, amount: amount, other: other, fast: fast, otherFast: otherFast)
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(WorkspaceStyle.localUsage.opacity(0.08))
                HStack(spacing: 0) {
                    Rectangle().fill(WorkspaceStyle.localUsage).frame(width: width * shares.localStandard)
                    Rectangle().fill(WorkspaceStyle.fastUsage(scheme)).frame(width: width * shares.localFast)
                    Rectangle().fill(WorkspaceStyle.otherDevices(scheme)).frame(width: width * shares.otherStandard)
                    Rectangle().fill(WorkspaceStyle.fastUsage(scheme)).frame(width: width * shares.otherFast)
                }.clipShape(Capsule())
                    .animation(reduceMotion || range == nil ? nil : DashboardMotion.grow, value: shares)
            }
        }.frame(height: height).accessibilityHidden(true)
    }
}
