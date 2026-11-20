// [INPUT]: Committed daily/hourly report and dashboard visibility.
// [OUTPUT]: Dual-axis Tokens bars and cost line with range transitions and a shared hover readout.
// [POS]: Upper overview chart; preserves unknown prices and unallocated hours.
// [PROTOCOL]: Update this header on change, then check AGENTS.md
import AppKit
import SwiftUI
import Charts

struct UsageTrendChart: View {
    let report: UsageReport
    let filter: UsageFilter
    let animateRangeChanges: Bool
    let openDatePicker: () -> Void
    @State private var selectedDate: Date?
    @State private var transition = DashboardPlotTransition()
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var range: DashboardDateSpan { DashboardDateSpan(from: filter.from, to: filter.to) }
    private var canAnimateRange: Bool { animateRangeChanges && !reduceMotion }
    private var costColor: Color { WorkspaceStyle.costColor(scheme) }
    private var axisDateFormat: Date.FormatStyle {
        Date.FormatStyle(locale: Localization.locale, calendar: Localization.reportingCalendar,
                         timeZone: Localization.reportingCalendar.timeZone).month(.abbreviated).day()
    }

    var body: some View {
        let hourly = report.hourly != nil
        let hasHourlyData = report.hourly?.buckets.isEmpty != true
        let presence = DashboardPlotPresence(range: range, hasData: report.summary.recordCount > 0 && hasHourlyData)
        let unallocatedTokens = report.hourly?.unallocated.tokens ?? 0
        VStack(alignment: .leading, spacing: 12) {
            if report.summary.recordCount > 0 {
                HStack {
                    Text(L(hourly ? "usage.hourly" : "usage.trend")).font(.headline)
                    Spacer()
                    if hasHourlyData {
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 2).fill(Color.accentColor).frame(width: 8, height: 12)
                            Text("Tokens")
                        }
                        HStack(spacing: 6) {
                            Capsule().fill(costColor).frame(width: 18, height: 2)
                            Text(L(report.summary.costStatus == "partial" ? "cost.known" : "cost.estimate"))
                        }.padding(.leading, 10)
                    }
                }.font(.caption)
                if hasHourlyData {
                    HStack {
                        Text("Tokens").foregroundStyle(Color.accentColor)
                        Spacer()
                        Text("USD").foregroundStyle(costColor)
                    }.font(.caption2).monospacedDigit()
                    let trend = UsageTrend(report: report, filter: filter)
                    let selected = trend.points.first { $0.id == selectedDate && !$0.isFuture }
                    plot(trend, selected: selected, presence: presence).frame(height: 210)
                } else {
                    Text(L("usage.no_hourly")).font(.callout).foregroundStyle(.secondary)
                }
            } else {
                ContentUnavailableView {
                    Label(L("usage.empty"), systemImage: "chart.bar.xaxis")
                } actions: {
                    Button(L("record.change_dates"), action: openDatePicker)
                }
                .frame(maxWidth: .infinity, minHeight: 210)
            }
            if unallocatedTokens > 0 {
                Text(LF("usage.hourly_unallocated", compactTokens(unallocatedTokens)))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onChange(of: presence, initial: true) { _, next in transition.commit(next) }
        .onChange(of: filter) { _, _ in selectedDate = nil }
    }

    private func plot(_ trend: UsageTrend, selected: UsageTrendPoint?, presence: DashboardPlotPresence) -> some View {
        let ticks = trend.axisPoints
        return Chart {
            // Swift Charts owns the scales and axes; the plot layer owns only the marks.
            RuleMark(y: .value("Tokens", 0.0)).foregroundStyle(.clear).accessibilityHidden(true)
        }
        .chartXScale(domain: trend.domain)
        .chartYScale(domain: 0...1)
        .chartXAxis {
            // The automatic date-axis preset leads with the label after each tick.
            AxisMarks(preset: .aligned, position: .bottom, values: ticks.map(\.center)) { value in
                AxisValueLabel(centered: false, collisionResolution: .greedy) {
                    if let point = ticks.first(where: { $0.center == value.as(Date.self) }) {
                        Text(trend.hourly ? hour(point.start) : point.start.formatted(axisDateFormat))
                            .font(.system(size: 10)).monospacedDigit()
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: [0.0, 0.25, 0.5, 0.75, 1]) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 4])).foregroundStyle(.secondary.opacity(0.2))
                AxisValueLabel {
                    if let fraction = value.as(Double.self) {
                        Text(compactTokens(Int64((fraction * trend.tokenMaximum).rounded())))
                            .font(.system(size: 10)).monospacedDigit().foregroundStyle(Color.accentColor)
                            .frame(minWidth: 44, alignment: .trailing)
                    }
                }
            }
            AxisMarks(position: .trailing, values: [0.0, 0.25, 0.5, 0.75, 1]) { value in
                AxisValueLabel {
                    if let fraction = value.as(Double.self) {
                        Text(!trend.hasPricedUsage ? "—" : usd(fraction * trend.costMaximum))
                            .font(.system(size: 10)).monospacedDigit().foregroundStyle(costColor)
                            .frame(minWidth: 48, alignment: .trailing)
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if let plot = proxy.plotFrame {
                    let frame = geometry[plot]
                    ZStack(alignment: .topLeading) {
                        chartMarks(trend, proxy: proxy, size: frame.size, presence: presence)
                            .frame(width: frame.width, height: frame.height)
                            .offset(x: frame.minX, y: frame.minY)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let location): select(at: location, frame: frame, proxy: proxy, trend: trend)
                                case .ended: selectedDate = nil
                                }
                            }
                            .onTapGesture { select(at: $0, frame: frame, proxy: proxy, trend: trend) }
                        if let selected, let x = proxy.position(forX: selected.center) {
                            ChartHoverRule(x: frame.minX + x, plot: frame, opacity: 0.5)
                            readout(selected, hourly: trend.hourly)
                                .padding(12).frame(width: 248)
                                .background(WorkspaceStyle.surface(scheme), in: RoundedRectangle(cornerRadius: 8))
                                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.1), lineWidth: 0.5) }
                                .offset(x: min(max(frame.minX + x - 124, 0), max(0, geometry.size.width - 248)), y: 4)
                                .allowsHitTesting(false)
                        }
                    }
                }
            }
        }
        .focusable()
        .onKeyPress(.leftArrow) { moveSelection(-1, trend: trend); return .handled }
        .onKeyPress(.rightArrow) { moveSelection(1, trend: trend); return .handled }
        .onKeyPress(.escape) { selectedDate = nil; return .handled }
        .accessibilityRepresentation {
            VStack {
                ForEach(trend.points.filter { !$0.isFuture }) { point in
                    readout(point, hourly: trend.hourly)
                        .accessibilityElement(children: .combine)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L("usage.combined_chart"))
        }
    }

    private func chartMarks(_ trend: UsageTrend, proxy: ChartProxy, size: CGSize, presence: DashboardPlotPresence) -> some View {
        let baseline = proxy.position(forY: 0.0) ?? size.height
        var series: [[CGPoint]] = []
        var dots: [DashboardChartMarks.Dot] = []
        var lastSegment: Int?
        let bars = trend.points.map { point in
            let left = proxy.position(forX: point.start.addingTimeInterval(point.duration * 0.16)) ?? 0
            let right = proxy.position(forX: point.start.addingTimeInterval(point.duration * 0.84)) ?? left
            let top = proxy.position(forY: Double(point.tokens ?? 0) / trend.tokenMaximum) ?? baseline
            if trend.hasPricedUsage, let cost = point.cost,
               let x = proxy.position(forX: point.center), let y = proxy.position(forY: cost / trend.costMaximum) {
                if lastSegment != point.costSegment {
                    series.append([])
                    lastSegment = point.costSegment
                }
                let center = CGPoint(x: x, y: y)
                series[series.count - 1].append(center)
                if trend.hourly || trend.points.count <= 7 || selectedDate == point.id {
                    dots.append(.init(center: center, diameter: 4.5))
                }
            }
            return DashboardChartMarks.Bar(frame: CGRect(x: left, y: top, width: max(0, right - left),
                                                         height: max(0, baseline - top)),
                                           emphasized: selectedDate == nil || point.id == selectedDate)
        }
        return DashboardChartMarks(bars: bars, series: series, dots: dots, frameSize: size,
                                   range: range, animateRangeChanges: canAnimateRange,
                                   takeEntrance: { [transition] in transition.takeEntrance(presence) },
                                   barColor: NSColor(Color.accentColor), lineColor: NSColor(costColor))
    }

    private func select(at location: CGPoint, frame: CGRect, proxy: ChartProxy, trend: UsageTrend) {
        guard frame.contains(location), let date: Date = proxy.value(atX: location.x - frame.minX) else {
            selectedDate = nil; return
        }
        let bucket = trend.points.first { date >= $0.start && date < $0.start.addingTimeInterval($0.duration) && !$0.isFuture }?.id
        if selectedDate != bucket { selectedDate = bucket }
    }
    private func moveSelection(_ delta: Int, trend: UsageTrend) {
        let points = trend.points.filter { !$0.isFuture }
        guard !points.isEmpty else { return }
        let current = points.firstIndex { $0.id == selectedDate } ?? (delta > 0 ? -1 : points.count)
        selectedDate = points[min(max(current + delta, 0), points.count - 1)].id
    }
    private static let hourFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
    private func hour(_ date: Date) -> String { Self.hourFormatter.string(from: date) }
    private func label(_ point: UsageTrendPoint, hourly: Bool) -> String {
        if hourly { return "\(hour(point.start))–\(hour(point.start.addingTimeInterval(3600)))" }
        let calendar = Localization.reportingCalendar
        return point.start.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: Localization.locale,
                                                      calendar: calendar, timeZone: calendar.timeZone))
    }
    private func readout(_ point: UsageTrendPoint, hourly: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label(point, hourly: hourly)).fontWeight(.medium)
            HStack { Text("Tokens").foregroundStyle(.secondary); Spacer(); Text((point.tokens ?? 0).formatted(.number.locale(Localization.locale))).monospacedDigit() }
            HStack { Text(L(point.summary?.costStatus == "partial" ? "cost.known" : "cost.estimate")).foregroundStyle(.secondary); Spacer(); Text(usd(point.cost)).monospacedDigit() }
            if let pending = point.summary?.unpricedTokens, pending > 0 {
                Text(LF("usage.unpriced", compactTokens(pending))).foregroundStyle(.secondary)
            }
        }.font(.caption)
    }
}

struct ChartHoverRule: View {
    let x: CGFloat
    let plot: CGRect
    let opacity: Double

    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: x, y: plot.minY))
            path.addLine(to: CGPoint(x: x, y: plot.maxY))
        }
        .stroke(.secondary.opacity(opacity), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
