// [INPUT]: Annual effective-ledger days and timestamp-qualified hour totals.
// [OUTPUT]: Coding patterns with weekday share, biggest day and hour distribution.
// [POS]: Independent overview panel; daily-only imports remain unallocated by hour.
// [PROTOCOL]: Update this header on change, then check AGENTS.md
import SwiftUI
import Charts

struct UsageHabitsView: View {
    let report: ActivityReport
    let activity: UsageActivity
    let horizontal: Bool
    var body: some View {
        WorkspacePanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(L("habits.title")).font(.headline).accessibilityAddTraits(.isHeader).foregroundStyle(WorkspaceStyle.text)
                    Spacer()
                    Text(L("activity.year")).font(.caption).foregroundStyle(WorkspaceStyle.subtext)
                }
                if let peak = activity.peak, let weekday = activity.topWeekday {
                    let total = activity.weekdayTokens.reduce(0, +)
                    HStack(alignment: .top, spacing: 24) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L("activity.weekday")).font(.caption).foregroundStyle(WorkspaceStyle.subtext)
                            Text(weekdayName(weekday)).font(.title3.weight(.medium))
                            Text(compactTokens(activity.weekdayTokens[weekday]) + " tokens · " + LF("habits.share", (Double(activity.weekdayTokens[weekday]) / Double(total)).formatted(.percent.precision(.fractionLength(0)))))
                                .font(.caption).foregroundStyle(WorkspaceStyle.subtext).monospacedDigit()
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L("activity.peak")).font(.caption).foregroundStyle(WorkspaceStyle.subtext)
                            Text("\(Text(compactTokens(peak.tokens)).font(DisplayNumberFont.font(for: .title3))) tokens")
                                .font(.title3.weight(.medium))
                            Text(Localization.day(peak.key) + " · " + usd(peak.cost)).font(.caption).foregroundStyle(WorkspaceStyle.subtext)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.foregroundStyle(WorkspaceStyle.text)
                }
                Divider()
                let layout = horizontal
                    ? AnyLayout(HStackLayout(alignment: .top, spacing: 24))
                    : AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
                layout {
                    HabitsDistribution(title: L("habits.weekdays"), values: [6, 0, 1, 2, 3, 4, 5].map { activity.weekdayTokens[$0] },
                                       labels: Localization.reportingCalendar.veryShortWeekdaySymbols,
                                       fullLabels: Localization.reportingCalendar.weekdaySymbols)
                        .frame(maxWidth: .infinity)
                    if let hourly = report.hourly {
                        if hourly.buckets.isEmpty {
                            Text(L("usage.no_hourly")).font(.caption).foregroundStyle(WorkspaceStyle.subtext)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            let lookup = Dictionary(uniqueKeysWithValues: hourly.buckets.map { ($0.key, $0.summary.tokens) })
                            HabitsDistribution(title: L("habits.hours"), values: (0..<24).map { lookup[String(format: "%02d", $0), default: 0] },
                                               labels: (0..<24).map { String(format: "%02d", $0) },
                                               fullLabels: (0..<24).map { String(format: "%02d:00–%02d:00", $0, $0 + 1) })
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
    }
    private func weekdayName(_ weekday: Int) -> String {
        Localization.reportingCalendar.weekdaySymbols[(weekday + 1) % 7]
    }
}

private struct HabitsDistribution: View {
    let title: String
    let values: [Int64]
    let labels: [String]
    let fullLabels: [String]
    @State private var selected: Int?
    @State private var tooltipPointer = TooltipPointer()
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption).foregroundStyle(WorkspaceStyle.subtext)
            Chart(values.indices, id: \.self) { index in
                RectangleMark(xStart: .value("Period", Double(index) - 0.36),
                              xEnd: .value("Period", Double(index) + 0.36),
                              yStart: .value("Tokens", 0), yEnd: .value("Tokens", values[index]))
                    .foregroundStyle(WorkspaceStyle.localUsage.opacity(selected == index || values[index] == values.max() ? 1 : 0.35))
                    .cornerRadius(2)
                    .accessibilityLabel(fullLabels[index])
                    .accessibilityValue(values[index].formatted(.number.locale(Localization.locale)) + " tokens")
            }
            .chartXScale(domain: -0.5...Double(values.count - 1) + 0.5)
            .chartXAxis {
                AxisMarks(preset: .aligned, values: Array(values.indices)) { axis in
                    AxisValueLabel(centered: false) { if let index = axis.as(Int.self) { Text(labels[index]).font(.system(size: 9)) } }
                }
            }
            .chartYAxis(.hidden)
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    if let plot = proxy.plotFrame {
                        let frame = geometry[plot]
                        let mark = selected.flatMap { index -> CGRect? in
                            guard let center = proxy.position(forX: Double(index)) else { return nil }
                            let bar = frame.width / CGFloat(values.count) * 0.72
                            return CGRect(x: frame.minX + center - bar / 2, y: frame.minY, width: bar, height: frame.height)
                        }
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let location):
                                    tooltipPointer.move(to: location)
                                    if frame.contains(location), let x: Double = proxy.value(atX: location.x - frame.minX) {
                                        let index = Int(x.rounded())
                                        selected = values.indices.contains(index) ? index : nil
                                    } else { selected = nil }
                                case .ended: selected = nil
                                }
                            }
                            .selectedTooltip(avoiding: mark, pointer: tooltipPointer) {
                                if let selected {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(fullLabels[selected]).fontWeight(.medium)
                                        HStack(spacing: 8) {
                                            Text("Tokens").foregroundStyle(WorkspaceStyle.subtext)
                                            Spacer(minLength: 0)
                                            Text(values[selected].formatted(.number.locale(Localization.locale))).monospacedDigit()
                                        }
                                    }.font(.caption).lineLimit(1).frame(width: max(87,
                                        CursorTooltipLayout.textWidth((values.max() ?? 0).formatted(.number.locale(Localization.locale))) + 51))
                                }
                            }
                    }
                }
            }.frame(height: 85)
        }
    }
}
