import SwiftUI
import Charts

struct UsageTrendChart: View {
    let report: UsageReport
    let filter: UsageFilter
    @State private var selectedDate: Date?
    @Environment(\.colorScheme) private var scheme
    private var costColor: Color { WorkspaceStyle.costColor(scheme) }
    private var axisDateFormat: Date.FormatStyle {
        Date.FormatStyle(locale: Localization.locale, calendar: Localization.reportingCalendar,
                         timeZone: Localization.reportingCalendar.timeZone).month(.abbreviated).day()
    }

    var body: some View {
        let trend = UsageTrend(report: report, filter: filter)
        let selected = trend.points.first { $0.id == selectedDate && !$0.isFuture }
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L(trend.hourly ? "usage.hourly" : "usage.trend")).font(.headline)
                Spacer()
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.accentColor).frame(width: 8, height: 12)
                    Text("Tokens")
                }
                HStack(spacing: 6) {
                    Capsule().fill(costColor).frame(width: 18, height: 2)
                    Text(L(report.summary.costStatus == "partial" ? "cost.known" : "cost.estimate"))
                }.padding(.leading, 10)
            }.font(.caption)
            if report.summary.recordCount == 0 {
                ContentUnavailableView(L("usage.empty"), systemImage: "chart.bar.xaxis").frame(height: 210)
            } else if trend.hourly && report.hourly?.buckets.isEmpty == true {
                ContentUnavailableView(L("usage.no_hourly"), systemImage: "clock").frame(height: 210)
            } else {
                HStack {
                    Text("Tokens").foregroundStyle(Color.accentColor)
                    Spacer()
                    Text("USD").foregroundStyle(costColor)
                }.font(.caption2).monospacedDigit()
                plot(trend, selected: selected).frame(height: 210)
            }
            if trend.unallocatedTokens > 0 {
                Text(LF("usage.hourly_unallocated", compactTokens(trend.unallocatedTokens)))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onChange(of: filter) { _, _ in selectedDate = nil }
    }

    private func plot(_ trend: UsageTrend, selected: UsageTrendPoint?) -> some View {
        Chart {
            ForEach(trend.points) { point in
                if let tokens = point.tokens {
                    RectangleMark(xStart: .value("Time", point.start.addingTimeInterval(point.duration * 0.16)),
                            xEnd: .value("Time", point.start.addingTimeInterval(point.duration * 0.84)),
                            yStart: .value("Tokens", 0),
                            yEnd: .value("Tokens", Double(tokens) / trend.tokenMaximum))
                    .foregroundStyle(Color.accentColor.opacity(selectedDate == nil || point.id == selectedDate ? 0.7 : 0.25))
                    .cornerRadius(2)
                    .accessibilityLabel(label(point, hourly: trend.hourly))
                    .accessibilityValue(tokens.formatted(.number.locale(Localization.locale)))
                }
            }
            ForEach(trend.points) { point in
                if let cost = point.cost, trend.hasPricedUsage {
                    LineMark(x: .value("Time", point.center), y: .value("USD", cost / trend.costMaximum),
                             series: .value("Cost segment", point.costSegment))
                    .foregroundStyle(costColor).lineStyle(StrokeStyle(lineWidth: 2))
                    .interpolationMethod(.monotone)
                    .accessibilityLabel(label(point, hourly: trend.hourly))
                    .accessibilityValue(usd(cost))
                    if trend.hourly || trend.points.count <= 7 || selectedDate == point.id {
                        PointMark(x: .value("Time", point.center), y: .value("USD", cost / trend.costMaximum))
                            .foregroundStyle(costColor).symbolSize(16).accessibilityHidden(true)
                    }
                }
            }
            if let selected {
                RuleMark(x: .value("Time", selected.center))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3])).accessibilityHidden(true)
            }
        }
        .chartXScale(domain: trend.domain)
        .chartYScale(domain: 0...1)
        .chartXAxis {
            if trend.hourly {
                AxisMarks(values: stride(from: 0, to: trend.points.count, by: 4).map { trend.points[$0].start }) { value in
                    AxisValueLabel {
                        if let date = value.as(Date.self) { Text(hour(date)).font(.system(size: 10)).monospacedDigit() }
                    }
                }
            } else if trend.points.count <= 7 {
                AxisMarks(values: trend.points.map(\.center)) { value in
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(date.formatted(axisDateFormat))
                        }
                    }
                }
            } else {
                AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                    AxisValueLabel(format: axisDateFormat)
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
                    }
                }
            }
            AxisMarks(position: .trailing, values: [0.0, 0.25, 0.5, 0.75, 1]) { value in
                AxisValueLabel {
                    if let fraction = value.as(Double.self) {
                        Text(!trend.hasPricedUsage ? "—" : usd(fraction * trend.costMaximum))
                            .font(.system(size: 10)).monospacedDigit().foregroundStyle(costColor)
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if let plot = proxy.plotFrame {
                    let frame = geometry[plot]
                    ZStack(alignment: .topLeading) {
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let location): select(at: location, frame: frame, proxy: proxy, trend: trend)
                                case .ended: selectedDate = nil
                                }
                            }
                            .onTapGesture { select(at: $0, frame: frame, proxy: proxy, trend: trend) }
                        if let selected, let x = proxy.position(forX: selected.center) {
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

    private func select(at location: CGPoint, frame: CGRect, proxy: ChartProxy, trend: UsageTrend) {
        guard frame.contains(location), let date: Date = proxy.value(atX: location.x - frame.minX) else {
            selectedDate = nil; return
        }
        selectedDate = trend.points.first { date >= $0.start && date < $0.start.addingTimeInterval($0.duration) && !$0.isFuture }?.id
    }
    private func moveSelection(_ delta: Int, trend: UsageTrend) {
        let points = trend.points.filter { !$0.isFuture }
        guard !points.isEmpty else { return }
        let current = points.firstIndex { $0.id == selectedDate } ?? (delta > 0 ? -1 : points.count)
        selectedDate = points[min(max(current + delta, 0), points.count - 1)].id
    }
    private func hour(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.timeZone = TimeZone(identifier: "Asia/Shanghai"); formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
    private func label(_ point: UsageTrendPoint, hourly: Bool) -> String {
        hourly ? "\(hour(point.start))–\(hour(point.start.addingTimeInterval(3600)))" : Localization.day(UsageStore.day(point.start))
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
