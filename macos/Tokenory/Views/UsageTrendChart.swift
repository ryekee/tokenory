// [INPUT]: Local and combined daily/hourly reports and device-specific bucket indexes.
// [OUTPUT]: Dual-axis trend in the local or device snapshot time zone, with a shared hover readout.
// [POS]: Upper overview chart; preserves unknown prices and unallocated hours.
// [PROTOCOL]: Update this header on change, then check AGENTS.md
import AppKit
import SwiftUI
import Charts

struct ChartInspection<Mark: Equatable> {
    var hovered: Mark?
    var pinned: Mark?
    var selection: Mark? { pinned ?? hovered }

    mutating func togglePin(_ mark: Mark?) {
        pinned = pinned == mark ? nil : mark
        hovered = nil
    }

    mutating func clear() {
        hovered = nil
        pinned = nil
    }
}

struct UsageTrendChart: View {
    let report: UsageReport
    private let sources: [DeviceBuckets]
    private let trend: UsageTrend
    private let readoutWidth: CGFloat
    private let reservesPendingLine: Bool
    private let timeZone: TimeZone
    let filter: UsageFilter
    let animateRangeChanges: Bool
    let openDatePicker: () -> Void
    @State private var inspection = ChartInspection<Date>()
    @State private var tooltipPointer = TooltipPointer()
    @State private var transition = DashboardPlotTransition()
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var range: DashboardDateSpan { DashboardDateSpan(from: filter.from, to: filter.to) }
    private var canAnimateRange: Bool { animateRangeChanges && !reduceMotion }
    private var costColor: Color { WorkspaceStyle.costColor(scheme) }
    private var calendar: Calendar {
        var calendar = Localization.reportingCalendar
        calendar.timeZone = timeZone
        return calendar
    }
    private var axisDateFormat: Date.FormatStyle {
        Date.FormatStyle(locale: Localization.locale, calendar: calendar, timeZone: timeZone).month(.abbreviated).day()
    }

    init(report: UsageReport, localReport: UsageReport, remoteReports: [String: UsageReport],
         localName: String, deviceName: (String) -> String, filter: UsageFilter,
         animateRangeChanges: Bool, openDatePicker: @escaping () -> Void) {
        self.report = report
        self.filter = filter
        self.animateRangeChanges = animateRangeChanges
        self.openDatePicker = openDatePicker
        timeZone = remoteReports.isEmpty ? .autoupdatingCurrent : TimeZone(identifier: DeviceUsageSnapshot.reportingTimezone)!
        trend = UsageTrend(report: report, filter: filter, timeZone: timeZone)
        sources = Self.deviceBuckets(localReport: localReport, localName: localName, remoteReports: remoteReports,
                                     deviceName: deviceName, hourly: report.hourly != nil, timeZone: timeZone)
        reservesPendingLine = trend.points.contains { ($0.summary?.unpricedTokens ?? 0) > 0 }
        readoutWidth = CursorTooltipLayout.summaryWidth(names: sources.isEmpty ? [] : [L("cloud.overview.total")] + sources.map(\.name),
            tokens: trend.points.compactMap(\.tokens).max() ?? 0, cost: trend.points.compactMap(\.cost).max(), partial: reservesPendingLine)
    }

    var body: some View {
        let hourly = report.hourly != nil
        let hasHourlyData = report.hourly?.buckets.isEmpty != true
        let presence = DashboardPlotPresence(range: range, hasData: report.summary.recordCount > 0 && hasHourlyData)
        let unallocatedTokens = report.hourly?.unallocated.tokens ?? 0
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(L(hourly ? "usage.hourly" : "usage.trend")).font(.headline).foregroundStyle(WorkspaceStyle.text)
                    .accessibilityAddTraits(.isHeader)
                if unallocatedTokens > 0 {
                    Text(LF("usage.hourly_unallocated", compactTokens(unallocatedTokens)))
                        .font(.caption).foregroundStyle(WorkspaceStyle.subtext)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if !sources.isEmpty { OverviewDeviceLegend() } else {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).fill(WorkspaceStyle.localUsage)
                            .frame(width: OverviewDeviceLegend.swatchWidth, height: 12)
                        Text("Tokens")
                    }
                }
                HStack(spacing: 6) {
                    Capsule().fill(costColor).frame(width: OverviewDeviceLegend.swatchWidth, height: 2)
                    Text(L(report.summary.costStatus == "partial" ? "cost.known" : "cost.estimate"))
                }.padding(.leading, 10)
            }.font(.caption)
            HStack {
                Text("Tokens").foregroundStyle(WorkspaceStyle.subtext)
                Spacer()
                Text("USD").foregroundStyle(WorkspaceStyle.subtext)
            }.font(.caption2).monospacedDigit()
            if hasHourlyData {
                let selected = inspection.selection.flatMap { trend.point(containing: $0) }
                plot(trend, sources: sources, selected: selected, presence: presence).frame(height: 210)
                if let selected, inspection.pinned == selected.id {
                    PinnedChartReadout(clear: {
                        DashboardMotion.withAnimation(DashboardMotion.disclosure, reduceMotion: reduceMotion) {
                            inspection.clear()
                        }
                    }) {
                        readout(selected, hourly: trend.hourly, sources: sources)
                    }
                    .transition(.opacity)
                }
            } else {
                ZStack {
                    plot(trend, sources: sources, selected: nil, presence: presence).allowsHitTesting(false)
                    if report.summary.recordCount > 0 {
                        Text(L("usage.no_hourly")).font(.callout).foregroundStyle(WorkspaceStyle.subtext)
                    }
                }
                .frame(height: 210)
            }
        }
        .onChange(of: presence, initial: true) { _, next in transition.commit(next) }
        .onChange(of: filter) { _, _ in inspection.clear() }
        .onChange(of: timeZone) { _, _ in inspection.clear() }
    }

    private struct DeviceBuckets {
        let id: String
        let name: String
        let values: [Date: UsageSummary]
    }
    private static func deviceBuckets(localReport: UsageReport, localName: String, remoteReports: [String: UsageReport],
                                      deviceName: (String) -> String, hourly: Bool, timeZone: TimeZone) -> [DeviceBuckets] {
        guard !remoteReports.isEmpty else { return [] }
        let parser = ISO8601DateFormatter()
        func index(_ report: UsageReport) -> [Date: UsageSummary] {
            let groups = hourly ? report.hourly?.buckets ?? [] : report.daily
            return Dictionary(uniqueKeysWithValues: groups.compactMap { group in
                let date = hourly ? parser.date(from: group.key) : Localization.date(group.key, timeZone: timeZone)
                return date.map { ($0, group.summary) }
            })
        }
        return [DeviceBuckets(id: "local", name: localName, values: index(localReport))]
            + remoteReports.map { id, report in
                DeviceBuckets(id: "remote:" + id, name: deviceName(id), values: index(report))
            }
    }

    private func plot(_ trend: UsageTrend, sources: [DeviceBuckets], selected: UsageTrendPoint?, presence: DashboardPlotPresence) -> some View {
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
                            .font(.system(size: 10)).monospacedDigit().foregroundStyle(WorkspaceStyle.subtext)
                            .frame(minWidth: 44, alignment: .trailing)
                    }
                }
            }
            AxisMarks(position: .trailing, values: [0.0, 0.25, 0.5, 0.75, 1]) { value in
                AxisValueLabel {
                    if let fraction = value.as(Double.self) {
                        Text(!trend.hasPricedUsage ? "—" : usd(fraction * trend.costMaximum))
                            .font(.system(size: 10)).monospacedDigit().foregroundStyle(WorkspaceStyle.subtext)
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
                        chartMarks(trend, sources: sources, proxy: proxy, size: frame.size, presence: presence, selectedDate: selected?.id)
                            .frame(width: frame.width, height: frame.height)
                            .offset(x: frame.minX, y: frame.minY)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                        let mark = selected.flatMap { point in
                            proxy.position(forX: point.center).map {
                                let mid = frame.minX + $0
                                let left = frame.minX + (proxy.position(forX: point.start.addingTimeInterval(point.duration * 0.16)) ?? $0)
                                return CGRect(x: left, y: frame.minY, width: max(1, (mid - left) * 2), height: frame.height)
                            }
                        }
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let location):
                                    tooltipPointer.move(to: location)
                                    let next = bucket(at: location, frame: frame, proxy: proxy, trend: trend)
                                    if inspection.hovered != next { inspection.hovered = next }
                                case .ended: inspection.hovered = nil
                                }
                            }
                            .onTapGesture { location in
                                DashboardMotion.withAnimation(DashboardMotion.disclosure, reduceMotion: reduceMotion) {
                                    inspection.togglePin(bucket(at: location, frame: frame, proxy: proxy, trend: trend))
                                }
                            }
                            .selectedTooltip(avoiding: inspection.pinned == nil ? mark : nil, pointer: tooltipPointer) {
                                if let selected {
                                    readout(selected, hourly: trend.hourly, sources: sources)
                                }
                            }
                        if let selected, let x = proxy.position(forX: selected.center) {
                            ChartHoverRule(x: frame.minX + x, plot: frame, opacity: inspection.pinned == nil ? 0.5 : 0.95)
                        }
                    }
                }
            }
        }
        .focusable()
        .onKeyPress(.leftArrow) { moveSelection(-1, trend: trend); return .handled }
        .onKeyPress(.rightArrow) { moveSelection(1, trend: trend); return .handled }
        .onKeyPress(.escape) {
            guard inspection.selection != nil else { return .ignored }
            DashboardMotion.withAnimation(DashboardMotion.disclosure, reduceMotion: reduceMotion) {
                inspection.clear()
            }
            return .handled
        }
        .accessibilityRepresentation {
            VStack {
                ForEach(trend.points.filter { !$0.isFuture }) { point in
                    readout(point, hourly: trend.hourly, sources: sources)
                        .accessibilityElement(children: .combine)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L("usage.combined_chart"))
        }
    }

    private func chartMarks(_ trend: UsageTrend, sources: [DeviceBuckets], proxy: ChartProxy, size: CGSize,
                            presence: DashboardPlotPresence, selectedDate: Date?) -> some View {
        let baseline = proxy.position(forY: 0.0) ?? size.height
        var series: [[CGPoint]] = []
        var dots: [DashboardChartMarks.Dot] = []
        var lastSegment: Int?
        var bars: [DashboardChartMarks.Bar] = []
        for point in trend.points {
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
            let highlighted = selectedDate == nil || point.id == selectedDate
            let width = max(0, right - left)
            let remote = point.isFuture ? 0 : sources.dropFirst().reduce(Int64(0)) { $0 + ($1.values[point.start]?.tokens ?? 0) }
            let local = max(0, (point.tokens ?? 0) - remote)
            let split = proxy.position(forY: Double(local) / trend.tokenMaximum) ?? baseline
            bars.append(.init(frame: CGRect(x: left, y: split, width: width, height: max(0, baseline - split)), emphasized: highlighted))
            if !sources.isEmpty {
                bars.append(.init(frame: CGRect(x: left, y: top, width: width, height: max(0, split - top)), emphasized: highlighted, otherDevice: true))
            }
        }
        return DashboardChartMarks(bars: bars, series: series, dots: dots, frameSize: size,
                                   range: range, animateRangeChanges: canAnimateRange,
                                   takeEntrance: { [transition] in transition.takeEntrance(presence) },
                                   barColor: NSColor(WorkspaceStyle.localUsage), lineColor: NSColor(costColor),
                                   otherDeviceColor: NSColor(WorkspaceStyle.otherDevices(scheme)))
    }

    private func bucket(at location: CGPoint, frame: CGRect, proxy: ChartProxy, trend: UsageTrend) -> Date? {
        guard frame.contains(location), let date: Date = proxy.value(atX: location.x - frame.minX) else { return nil }
        return trend.point(containing: date)?.id
    }

    private func moveSelection(_ delta: Int, trend: UsageTrend) {
        let points = trend.points.filter { !$0.isFuture }
        guard !points.isEmpty else { return }
        let current = points.firstIndex { $0.id == inspection.selection } ?? (delta > 0 ? -1 : points.count)
        DashboardMotion.withAnimation(DashboardMotion.disclosure, reduceMotion: reduceMotion) {
            inspection.pinned = points[min(max(current + delta, 0), points.count - 1)].id
        }
    }
    private func hour(_ date: Date) -> String {
        Date.VerbatimFormatStyle(format: "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
                                 locale: Locale(identifier: "en_US_POSIX"), timeZone: timeZone, calendar: calendar).format(date)
    }
    private func label(_ point: UsageTrendPoint, hourly: Bool) -> String {
        if hourly { return "\(hour(point.start))–\(hour(point.start.addingTimeInterval(point.duration)))" }
        return point.start.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: Localization.locale,
                                                      calendar: calendar, timeZone: calendar.timeZone))
    }
    private func readout(_ point: UsageTrendPoint, hourly: Bool, sources: [DeviceBuckets]) -> some View {
        let rows = sources.isEmpty ? [] : [OverviewDeviceRow(id: "total", name: L("cloud.overview.total"), summary: point.summary)]
            + sources.map { OverviewDeviceRow(id: $0.id, name: $0.name, summary: $0.values[point.start]) }
        return UsageBucketReadout(title: label(point, hourly: hourly), summary: point.summary, tokens: point.tokens ?? 0, cost: point.cost,
                                  rows: rows, width: readoutWidth, reservesPendingLine: reservesPendingLine)
    }
}

private extension UsageTrend {
    func point(containing date: Date) -> UsageTrendPoint? {
        // Daily data can skip inactive days. Locate the last bucket that has already begun.
        var low = 0, high = points.count
        while low < high {
            let mid = low + (high - low) / 2
            if points[mid].start <= date { low = mid + 1 } else { high = mid }
        }
        guard low > 0 else { return nil }
        let point = points[low - 1]
        return !point.isFuture && date < point.start.addingTimeInterval(point.duration) ? point : nil
    }
}

struct PinnedChartReadout<Content: View>: View {
    let clear: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Divider()
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "pin.fill").foregroundStyle(WorkspaceStyle.selection).accessibilityHidden(true)
                content
                Spacer(minLength: 0)
                Button(action: clear) {
                    Image(systemName: "xmark").frame(width: 22, height: 22)
                }
                .buttonStyle(WorkspaceHoverStyle())
                .accessibilityLabel(L("overview.clear_chart_selection"))
            }.font(.caption)
        }
    }
}

/// Daily, hourly and calendar readouts keep the same columns and pending-price slot for the whole range.
struct UsageBucketReadout: View {
    let title: String
    let summary: UsageSummary?
    let tokens: Int64
    let cost: Double?
    let rows: [OverviewDeviceRow]
    let width: CGFloat
    let reservesPendingLine: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).fontWeight(.medium)
            if rows.isEmpty {
                HStack { Text("Tokens").foregroundStyle(.secondary); Spacer(); Text(tokens.formatted(.number.locale(Localization.locale))).monospacedDigit() }
                HStack { Text(L(summary?.costStatus == "partial" ? "cost.known" : "cost.estimate")).foregroundStyle(.secondary); Spacer(); Text(usd(cost)).monospacedDigit() }
            } else {
                OverviewDeviceReadout(rows: rows)
            }
            if reservesPendingLine {
                let pending = summary?.unpricedTokens ?? 0
                Text(LF("usage.unpriced", compactTokens(pending))).foregroundStyle(.secondary)
                    .opacity(pending > 0 ? 1 : 0).accessibilityHidden(pending == 0)
            }
        }.font(.caption).lineLimit(1).frame(width: width, alignment: .leading)
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
