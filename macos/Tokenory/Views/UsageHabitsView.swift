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
                    Text(L("habits.title")).font(.headline)
                    Spacer()
                    Text(L("activity.year")).font(.caption).foregroundStyle(.secondary)
                }
                if let peak = activity.peak, let weekday = activity.topWeekday {
                    let total = activity.weekdayTokens.reduce(0, +)
                    HStack(alignment: .top, spacing: 24) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L("activity.weekday")).font(.caption).foregroundStyle(.secondary)
                            Text(weekdayName(weekday)).font(.title3.weight(.medium))
                            Text(compactTokens(activity.weekdayTokens[weekday]) + " tokens · " + LF("habits.share", (Double(activity.weekdayTokens[weekday]) / Double(total)).formatted(.percent.precision(.fractionLength(0)))))
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L("activity.peak")).font(.caption).foregroundStyle(.secondary)
                            Text(compactTokens(peak.tokens) + " tokens").font(.title3.weight(.medium)).monospacedDigit()
                            Text(Localization.day(peak.key) + " · " + usd(peak.cost)).font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
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
                            Text(L("usage.no_hourly")).font(.caption).foregroundStyle(.secondary)
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
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Chart(values.indices, id: \.self) { index in
                RectangleMark(xStart: .value("Period", Double(index) - 0.36),
                              xEnd: .value("Period", Double(index) + 0.36),
                              yStart: .value("Tokens", 0), yEnd: .value("Tokens", values[index]))
                    .foregroundStyle(Color.accentColor.opacity(selected == index || values[index] == values.max() ? 0.8 : 0.35))
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
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let location):
                                    if frame.contains(location), let x: Double = proxy.value(atX: location.x - frame.minX) {
                                        let index = Int(x.rounded())
                                        selected = values.indices.contains(index) ? index : nil
                                    } else { selected = nil }
                                case .ended: selected = nil
                                }
                            }
                        if let selected {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(fullLabels[selected]).fontWeight(.medium)
                                HStack { Text("Tokens").foregroundStyle(.secondary); Spacer(); Text(values[selected].formatted(.number.locale(Localization.locale))).monospacedDigit() }
                            }.font(.caption).padding(12).frame(width: 220)
                                .background(WorkspaceStyle.surface(scheme), in: RoundedRectangle(cornerRadius: 8))
                                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.1), lineWidth: 0.5) }
                                .offset(x: min(max(0, (proxy.position(forX: selected) ?? 0) - 110), max(0, geometry.size.width - 220)), y: -15)
                                .allowsHitTesting(false)
                        }
                    }
                }
            }.frame(height: 85)
        }
    }
}
