// [INPUT]: Typed usage summaries and today-only turn statistics.
// [OUTPUT]: Locale-aware formats and compact units, device legend and focus-aware toolbar switch, source and Fast shares, a three-column menu summary and dismissible warning panel.
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title ?? L("fast.title"))
        .accessibilityHint(helpText)
    }
}

extension InferenceSpeed {
    var fastHelp: String { L(source == "selected" ? "fast.selected_help" : "fast.reported_help") }
}

func compactUsageUnits(locale: Locale) -> [(divisor: Double, suffix: String)] {
    locale.identifier.hasPrefix("zh")
        ? [(1e12, "万亿"), (1e8, "亿"), (1e4, "万")]
        : [(1e12, "T"), (1e9, "B"), (1e6, "M"), (1e3, "K")]
}

func compactTokens(_ value: Int64, locale: Locale = Localization.locale) -> String {
    let unit = compactUsageUnits(locale: locale).first { Double(value) >= $0.divisor } ?? (1, "")
    return (Double(value) / unit.divisor).formatted(.number.precision(.fractionLength(0...2)).locale(Locale(identifier: "en_US"))) + unit.suffix
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
                metric(L("menubar.cost"), usd(summary.knownEstimatedCostUsd))
                metric(L("menubar.speed"), (turns?.containsEstimates == true ? "≈ " : "") + TurnFormat.number(turns?.averageSpeed), unit: turns?.averageSpeed == nil ? "" : "tokens/s")
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
            (Text(value).font(DisplayNumberFont.font(size: 25)) + Text(unit.isEmpty ? "" : " " + unit).font(.caption).foregroundColor(.secondary))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
    }
}
struct ErrorBanner: View {
    @Environment(UsageStore.self) private var store

    var body: some View {
        if let error = store.error, let action = store.errorAction {
            WorkspacePanel(surface: WorkspaceStyle.warningSurface) {
                WorkspaceErrorMessage(title: title(for: action), detail: error) {
                    Group {
                        switch action {
                        case .refresh:
                            Button(L("action.refresh"), action: store.scan)
                                .disabled(store.scanInProgress)
                        case .reconnect:
                            Button(L("action.reconnect"), action: store.start)
                        case .acknowledge:
                            Button(L("action.got_it"), action: store.dismissError)
                        }
                    }
                    .buttonStyle(.bordered)
                    .settingsActionForeground()
                }
            }
        }
    }

    private func title(for action: UsageStore.ErrorAction) -> String {
        switch action {
        case .refresh: L("error.refresh_failed")
        case .reconnect: L("status.stopped")
        case .acknowledge: L("error.operation")
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
    private enum Segment: Int, CaseIterable {
        case localStandard, localFast, otherStandard, otherFast
    }

    let total: Double
    let amount: Double
    let other: Double
    var fast: Double = 0
    var otherFast: Double = 0
    var height: CGFloat = 4
    var range: DashboardDateSpan? = nil
    var formatValue: ((Double) -> String)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @State private var hovered: Segment?
    @State private var pointer = TooltipPointer()

    private var segmentValues: [Segment: Double] {
        let clampedAmount = max(amount, 0)
        let remote = min(max(other, 0), clampedAmount)
        let local = clampedAmount - remote
        let remoteFast = min(max(otherFast, 0), remote)
        let localFastVal = min(max(fast - otherFast, 0), local)
        return [
            .localStandard: max(0, local - localFastVal),
            .localFast: localFastVal,
            .otherStandard: max(0, remote - remoteFast),
            .otherFast: remoteFast
        ]
    }

    private func segmentColor(_ segment: Segment) -> Color {
        switch segment {
        case .localStandard: WorkspaceStyle.localUsage
        case .localFast, .otherFast: WorkspaceStyle.fastUsage(scheme)
        case .otherStandard: WorkspaceStyle.otherDevices(scheme)
        }
    }

    private func segmentLabel(_ segment: Segment, hasOther: Bool) -> String {
        switch segment {
        case .localStandard: L("cloud.overview.local")
        case .localFast: hasOther ? L("cloud.overview.local") + " · " + L("fast.title") : L("fast.title")
        case .otherStandard: L("cloud.overview.others")
        case .otherFast: L("cloud.overview.others") + " · " + L("fast.title")
        }
    }

    private func hitSegment(at x: CGFloat, width: CGFloat, shares: OverviewShareSegments) -> (Segment, CGRect)? {
        guard width > 0 else { return nil }
        let ordered: [(Segment, Double)] = [
            (.localStandard, shares.localStandard),
            (.localFast, shares.localFast),
            (.otherStandard, shares.otherStandard),
            (.otherFast, shares.otherFast)
        ]
        var cursor: CGFloat = 0
        for (segment, fraction) in ordered where fraction > 0 {
            let segWidth = width * CGFloat(fraction)
            let end = cursor + segWidth
            let hitEnd = max(end, cursor + 4)
            if x >= cursor && x <= hitEnd {
                return (segment, CGRect(x: cursor, y: 0, width: max(segWidth, 4), height: height))
            }
            cursor = end
        }
        return nil
    }

    private func segmentRect(_ segment: Segment, width: CGFloat, shares: OverviewShareSegments) -> CGRect? {
        let ordered: [(Segment, Double)] = [
            (.localStandard, shares.localStandard),
            (.localFast, shares.localFast),
            (.otherStandard, shares.otherStandard),
            (.otherFast, shares.otherFast)
        ]
        var cursor: CGFloat = 0
        for (item, fraction) in ordered where fraction > 0 {
            let segWidth = width * CGFloat(fraction)
            if item == segment {
                return CGRect(x: cursor, y: 0, width: max(segWidth, 4), height: height)
            }
            cursor += segWidth
        }
        return nil
    }

    var body: some View {
        let shares = OverviewShareSegments(total: total, amount: amount, other: other, fast: fast, otherFast: otherFast)
        let values = segmentValues
        let hasOther = (values[.otherStandard] ?? 0) + (values[.otherFast] ?? 0) > 0
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(WorkspaceStyle.localUsage.opacity(0.08))
                ShareBarCanvas(
                    localStandard: shares.localStandard,
                    localFast: shares.localFast,
                    otherStandard: shares.otherStandard,
                    otherFast: shares.otherFast,
                    localColor: WorkspaceStyle.localUsage,
                    otherColor: WorkspaceStyle.otherDevices(scheme),
                    fastColor: WorkspaceStyle.fastUsage(scheme),
                    highlightedIndex: hovered?.rawValue
                )
                .clipShape(Capsule())
                .animation(reduceMotion || range == nil ? nil : DashboardMotion.grow, value: range)
                .animation(DashboardMotion.animation(DashboardMotion.hover, reduceMotion: reduceMotion), value: hovered)
            }
            .overlay {
                if let formatValue {
                    let activeRect = hovered.flatMap { segmentRect($0, width: width, shares: shares) }
                    Color.clear
                        .frame(height: max(height, 14))
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                pointer.move(to: location)
                                let hit = hitSegment(at: location.x, width: width, shares: shares)?.0
                                if hovered != hit { hovered = hit }
                            case .ended:
                                if hovered != nil { hovered = nil }
                            }
                        }
                        .selectedTooltip(avoiding: activeRect, pointer: pointer) {
                            if let segment = hovered, let segValue = values[segment], segValue > 0 {
                                let rowTotal = max(amount, 0)
                                let pct = rowTotal > 0
                                    ? (segValue / rowTotal).formatted(.percent.precision(.fractionLength(0...1)).locale(Localization.locale))
                                    : "0%"
                                HStack(spacing: 8) {
                                    Circle().fill(segmentColor(segment)).frame(width: 6, height: 6)
                                    Text(segmentLabel(segment, hasOther: hasOther))
                                        .foregroundStyle(WorkspaceStyle.subtext)
                                    Text(formatValue(segValue))
                                        .fontWeight(.medium)
                                        .foregroundStyle(WorkspaceStyle.text)
                                        .monospacedDigit()
                                    Text(pct)
                                        .foregroundStyle(WorkspaceStyle.subtext)
                                        .monospacedDigit()
                                }
                                .font(.caption)
                                .fixedSize()
                            }
                        }
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }

    private struct ShareBarCanvas: View, Animatable {
        var localStandard: Double
        var localFast: Double
        var otherStandard: Double
        var otherFast: Double
        let localColor: Color
        let otherColor: Color
        let fastColor: Color
        let highlightedIndex: Int?

        nonisolated var animatableData: AnimatablePair<AnimatablePair<Double, Double>, AnimatablePair<Double, Double>> {
            get { AnimatablePair(AnimatablePair(localStandard, localFast), AnimatablePair(otherStandard, otherFast)) }
            set {
                localStandard = newValue.first.first
                localFast = newValue.first.second
                otherStandard = newValue.second.first
                otherFast = newValue.second.second
            }
        }

        var body: some View {
            Canvas { context, size in
                guard size.width > 0, size.height > 0 else { return }
                let segments: [(Int, Double, Color)] = [
                    (0, max(0, localStandard), localColor),
                    (1, max(0, localFast), fastColor),
                    (2, max(0, otherStandard), otherColor),
                    (3, max(0, otherFast), fastColor)
                ]
                var x: CGFloat = 0
                for (index, fraction, color) in segments where fraction > 0 {
                    let width = size.width * CGFloat(fraction)
                    let dimmed = highlightedIndex != nil && highlightedIndex != index
                    context.fill(Path(CGRect(x: x, y: 0, width: width, height: size.height)),
                                 with: .color(dimmed ? color.opacity(0.35) : color))
                    x += width
                }
            }
        }
    }
}
