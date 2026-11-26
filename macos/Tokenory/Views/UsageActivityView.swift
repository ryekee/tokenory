// [INPUT]: Combined annual activity, per-device calendars and day navigation callback.
// [OUTPUT]: Width-fitting YlGnBu calendar with immediate spring-loaded hover emphasis, delayed readouts and inline day details.
// [POS]: Native overview history section; no palette customization.
// [PROTOCOL]: Update this header on change, then check AGENTS.md
import AppKit
import SwiftUI

struct UsageActivityView: View {
    let report: ActivityReport
    let activity: UsageActivity
    var showsDeviceBreakdown = true
    let selectDay: (String) -> Void
    @Environment(UsageStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var inspectedDay: String?
    @State private var hover = HoverDwell<Int>(delay: HoverDwell<Int>.calendarDelay)
    @State private var tooltipPointer = TooltipPointer()
    private var palette: [Color] {
        (scheme == .dark ? [0x5965ae, 0x2c7fb8, 0x41b6c4, 0xa1dab4] : [0xa1dab4, 0x41b6c4, 0x2c7fb8, 0x253494]).map {
            Color(red: Double(($0 >> 16) & 255) / 255, green: Double(($0 >> 8) & 255) / 255, blue: Double($0 & 255) / 255)
        }
    }
    var body: some View {
        WorkspacePanel {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text(L("activity.title")).font(.headline).accessibilityAddTraits(.isHeader)
                    Text(L("activity.year")).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(LF("activity.days", activity.activeDays)).font(.caption).foregroundStyle(.secondary)
                }
                calendar(activity).zIndex(1)
                HStack(spacing: 4) {
                    Text(Localization.dateRange(report.from, report.to))
                    Spacer()
                    Text(L("activity.low"))
                    ForEach(0..<4) { i in RoundedRectangle(cornerRadius: 2).fill(palette[i]).frame(width: 9, height: 9) }
                    Text(L("activity.high"))
                }.font(.caption2).foregroundStyle(.secondary)
                if let inspectedDay, let day = activity.days.first(where: { $0.key == inspectedDay }) {
                    VStack(alignment: .leading, spacing: 18) {
                        Divider()
                        dayDetail(day)
                    }
                    .transition(.opacity)
                }
            }
            .clipped()
        }
    }
    private func calendar(_ activity: UsageActivity) -> some View {
        let weeks = (activity.leadingDays + activity.days.count + 6) / 7
        let maxTokens = activity.days.map(\.tokens).max() ?? 0
        let palette = palette
        let fill: (ActivityDay) -> Color = { day in
            guard day.tokens > 0 else { return Color.primary.opacity(0.045) }
            let level = min(3, Int(Double(day.tokens) / Double(max(1, maxTokens)) * 4))
            return palette[level]
        }
        let partial = activity.days.contains { ($0.summary?.unpricedTokens ?? 0) > 0 }
        let names = showsDeviceBreakdown ? [L("cloud.overview.total"), store.localDeviceName] + store.remoteActivityCalendars.keys.map(store.deviceName) : []
        let width = CursorTooltipLayout.summaryWidth(names: names, tokens: maxTokens, cost: activity.days.compactMap(\.cost).max(), partial: partial)
        return GeometryReader { geometry in
            let layout = ActivityCalendarLayout(width: geometry.size.width, weeks: weeks)
            let months = ActivityMonthLabelLayout.months(activity: activity, weeks: weeks, cell: layout.cellWidth,
                                                        columnGap: layout.columnGap)
            HStack(alignment: .bottom, spacing: ActivityCalendarLayout.weekdayGap) {
                VStack(spacing: ActivityCalendarLayout.rowGap) {
                    ForEach(0..<7) { weekday in
                        Text(weekday % 2 == 0 ? weekdayName(weekday, short: true) : "")
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                            .frame(width: ActivityCalendarLayout.weekdayWidth, height: ActivityCalendarLayout.cellHeight)
                    }
                }
                .padding(.bottom, ActivityCalendarLayout.verticalExpansion)
                HStack(alignment: .bottom, spacing: layout.columnGap) {
                    ForEach(0..<weeks, id: \.self) { week in
                        VStack(spacing: ActivityCalendarLayout.rowGap) {
                            Color.clear.frame(width: layout.cellWidth, height: ActivityCalendarLayout.monthHeight)
                                .overlay(alignment: .leading) {
                                    if let month = months[week] {
                                        Text(month.title).font(.system(size: 9)).foregroundStyle(.secondary)
                                            .fixedSize().offset(x: month.offset)
                                    }
                                }
                                .padding(.bottom, ActivityCalendarLayout.verticalExpansion)
                                .accessibilityHidden(true)
                            ForEach(0..<7) { weekday in
                                let position = week * 7 + weekday
                                let index = position - activity.leadingDays
                                if activity.days.indices.contains(index) {
                                    dayButton(activity.days[index], position: position, layout: layout,
                                              fill: fill(activity.days[index]))
                                } else {
                                    Color.clear.frame(width: layout.cellWidth, height: ActivityCalendarLayout.cellHeight)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, layout.horizontalExpansion)
                .padding(.bottom, ActivityCalendarLayout.verticalExpansion)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        let next = layout.position(at: point, retaining: hover.target).flatMap { position in
                            activity.days.indices.contains(position - activity.leadingDays) ? position : nil
                        }
                        hover.update(next)
                        tooltipPointer.move(to: point, reposition: hover.readoutTarget != nil)
                    case .ended: hover.update(nil)
                    }
                }
                .onChange(of: report.from) { _, _ in hover.update(nil) }
                .onDisappear { hover.update(nil) }
                .overlay {
                    ActivityHoverReadout(hover: hover, pointer: tooltipPointer, activity: activity, layout: layout,
                                         inspectedDay: inspectedDay, showsDeviceBreakdown: showsDeviceBreakdown,
                                         width: width, reservesPendingLine: partial)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
        }.frame(height: ActivityCalendarLayout.height)
    }

    private func dayButton(_ day: ActivityDay, position: Int, layout: ActivityCalendarLayout, fill: Color) -> some View {
        let inspected = day.key == inspectedDay
        return Button {
            DashboardMotion.withAnimation(DashboardMotion.disclosure, reduceMotion: reduceMotion) {
                inspectedDay = inspected ? nil : day.key
            }
        } label: {
            Color.clear.frame(width: layout.cellWidth, height: ActivityCalendarLayout.cellHeight)
                .contentShape(Rectangle())
                .background {
                    ActivityCalendarDayMark(position: position, layout: layout, hover: hover,
                                            fill: fill, hasUsage: day.tokens > 0, inspected: inspected)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(day.label)
        .accessibilityValue(day.tokens.formatted() + " tokens")
        .accessibilityAddTraits(inspected ? .isSelected : [])
    }

    private func dayDetail(_ day: ActivityDay) -> some View {
        let toolTokens = report.modelDays.lazy.filter { $0.date == day.key }.reduce(into: [String: Int64]()) {
            $0[$1.client, default: 0] += $1.summary.tokens
        }
        let topTools = toolTokens.filter { $0.value > 0 }.sorted {
            $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
        }.prefix(3)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(day.label).font(.headline).foregroundStyle(WorkspaceStyle.text)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if day.summary != nil {
                    Button(L("activity.open_day")) { selectDay(day.key) }
                }
                Button {
                    DashboardMotion.withAnimation(DashboardMotion.disclosure, reduceMotion: reduceMotion) {
                        inspectedDay = nil
                    }
                } label: {
                    Image(systemName: "xmark").frame(width: 22, height: 22)
                }
                .buttonStyle(WorkspaceHoverStyle())
                .accessibilityLabel(L("activity.close_day"))
            }
            if let summary = day.summary {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 22) { dayMetrics(day, summary: summary) }.fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 5) { dayMetrics(day, summary: summary) }
                }
                if !topTools.isEmpty {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 18) { toolMetrics(Array(topTools)) }.fixedSize(horizontal: true, vertical: false)
                        VStack(alignment: .leading, spacing: 5) { toolMetrics(Array(topTools)) }
                    }
                }
            } else {
                Text(L("activity.no_day_usage")).font(.caption).foregroundStyle(WorkspaceStyle.subtext)
            }
        }
    }

    @ViewBuilder private func dayMetrics(_ day: ActivityDay, summary: UsageSummary) -> some View {
        dayMetric("usage.tokens", compactTokens(day.tokens))
        dayMetric(summary.costStatus == "partial" ? "cost.known" : "cost.estimate", usd(day.cost))
        if let requests = summary.requests {
            dayMetric("overview.requests", requests.formatted(.number.locale(Localization.locale)))
        }
        if let average = activity.averageActiveDayTokens {
            let multiple = (Double(day.tokens) / average).formatted(.number.precision(.fractionLength(0...2)).locale(Localization.locale))
            Text(LF("activity.vs_average", multiple)).font(.caption).foregroundStyle(WorkspaceStyle.subtext)
        }
    }

    @ViewBuilder private func toolMetrics(_ tools: [(key: String, value: Int64)]) -> some View {
        ForEach(tools, id: \.key) { tool in
            HStack(spacing: 5) {
                BrandIcon(name: tool.key, kind: .tool, size: 14).accessibilityHidden(true)
                Text(clientName(tool.key))
                Text(compactTokens(tool.value)).monospacedDigit()
            }
            .font(.caption).foregroundStyle(WorkspaceStyle.subtext)
            .accessibilityElement(children: .combine)
        }
    }

    private func dayMetric(_ title: String, _ value: String) -> some View {
        HStack(spacing: 5) {
            Text(L(title)).foregroundStyle(WorkspaceStyle.subtext)
            Text(value).foregroundStyle(WorkspaceStyle.text).monospacedDigit()
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }

    private func weekdayName(_ day: Int, short: Bool) -> String {
        let calendar = Localization.reportingCalendar
        return (short ? calendar.veryShortWeekdaySymbols : calendar.weekdaySymbols)[(day + 1) % 7]
    }
}

struct ActivityCalendarLayout {
    static let weekdayWidth: CGFloat = 18
    static let weekdayGap: CGFloat = 8
    static let monthHeight: CGFloat = 16
    static let cellHeight: CGFloat = 11
    static let rowGap: CGFloat = 3
    private static let expansionRatio: CGFloat = 0.4 // Six points on the iOS 15-point cell.
    static let verticalExpansion = cellHeight * expansionRatio
    private static let rowStride = cellHeight + rowGap
    private static let dayTop = monthHeight + rowGap + verticalExpansion
    static let height = dayTop + 7 * cellHeight + 6 * rowGap + verticalExpansion

    let weeks: Int
    let columnGap: CGFloat
    let cellWidth: CGFloat
    let plot: CGRect
    var horizontalExpansion: CGFloat { cellWidth * Self.expansionRatio }

    init(width: CGFloat, weeks: Int) {
        self.weeks = weeks
        let gridWidth = max(0, width - Self.weekdayWidth - Self.weekdayGap)
        let columns = CGFloat(max(1, weeks))
        columnGap = min(Self.rowGap, gridWidth / columns * 0.25)
        cellWidth = (gridWidth - CGFloat(max(0, weeks - 1)) * columnGap) / (columns + 2 * Self.expansionRatio)
        let top = Self.dayTop - Self.verticalExpansion
        plot = CGRect(x: 0, y: top, width: gridWidth, height: Self.height - top)
    }

    func cellFrame(at position: Int) -> CGRect {
        CGRect(x: horizontalExpansion + CGFloat(position / 7) * (cellWidth + columnGap),
               y: Self.dayTop + CGFloat(position % 7) * Self.rowStride,
               width: cellWidth, height: Self.cellHeight)
    }

    func position(at point: CGPoint, retaining hovered: Int? = nil) -> Int? {
        guard cellWidth > 0, plot.contains(point) else { return nil }
        // Once expanded, the painted cell owns its new bounds. Crossing the original
        // edge must not make it shrink back beneath a pointer that is still over it.
        if let hovered, focusFrame(at: hovered).contains(point) { return hovered }
        let column = Int(floor((point.x - horizontalExpansion) / (cellWidth + columnGap)))
        let row = Int(floor((point.y - Self.dayTop) / Self.rowStride))
        guard (0..<weeks).contains(column), (0..<7).contains(row) else { return nil }
        let position = 7 * column + row
        return insets(at: position, selected: hovered).frame(in: cellFrame(at: position)).contains(point) ? position : nil
    }

    func focusFrame(at position: Int) -> CGRect {
        insets(at: position, selected: position).frame(in: cellFrame(at: position))
    }

    func insets(at position: Int, selected: Int?) -> ActivityCalendarCellInsets {
        guard let selected else { return .zero }
        let column = position / 7 - selected / 7
        let row = position % 7 - selected % 7
        guard abs(column) <= 1, abs(row) <= 1 else { return .zero }
        if column == 0, row == 0 {
            return .init(top: -Self.verticalExpansion, leading: -horizontalExpansion,
                         bottom: -Self.verticalExpansion, trailing: -horizontalExpansion)
        }
        return .init(top: row == 1 ? Self.verticalExpansion : 0,
                     leading: column == 1 ? horizontalExpansion : 0,
                     bottom: row == -1 ? Self.verticalExpansion : 0,
                     trailing: column == -1 ? horizontalExpansion : 0)
    }
}

struct ActivityCalendarCellInsets: Equatable {
    var top: CGFloat
    var leading: CGFloat
    var bottom: CGFloat
    var trailing: CGFloat

    static let zero = Self(top: 0, leading: 0, bottom: 0, trailing: 0)

    func frame(in rect: CGRect) -> CGRect {
        CGRect(x: rect.minX + leading, y: rect.minY + top,
               width: rect.width - leading - trailing, height: rect.height - top - bottom)
    }
}

private struct ActivityCalendarCellShape: InsettableShape {
    var edges: ActivityCalendarCellInsets
    var outlineInset: CGFloat = 0

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { .init(.init(edges.top, edges.leading), .init(edges.bottom, edges.trailing)) }
        set { edges = .init(top: newValue.first.first, leading: newValue.first.second,
                            bottom: newValue.second.first, trailing: newValue.second.second) }
    }

    func path(in rect: CGRect) -> Path {
        let frame = edges.frame(in: rect).insetBy(dx: outlineInset, dy: outlineInset)
        guard frame.width > 0, frame.height > 0 else { return Path() }
        return RoundedRectangle(cornerRadius: max(0, 2 - outlineInset), style: .continuous).path(in: frame)
    }

    func inset(by amount: CGFloat) -> Self {
        .init(edges: edges, outlineInset: outlineInset + amount)
    }
}

private struct ActivityCalendarDayMark: View {
    let position: Int
    let layout: ActivityCalendarLayout
    let hover: HoverDwell<Int>
    let fill: Color
    let hasUsage: Bool
    let inspected: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let focused = hover.target == position
        let edges = layout.insets(at: position, selected: hover.target)
        let shape = ActivityCalendarCellShape(edges: edges)
        shape.fill(fill)
            .overlay {
                shape.fill(hasUsage ? WorkspaceStyle.chartHighlight : WorkspaceStyle.selection.opacity(0.22))
                    .opacity(focused ? 1 : 0)
            }
            .overlay {
                shape.strokeBorder(WorkspaceStyle.selection, lineWidth: inspected ? 2 : 1)
                    .opacity(focused || inspected ? 1 : 0)
            }
            .animation(DashboardMotion.animation(DashboardMotion.calendarCell, reduceMotion: reduceMotion), value: edges)
            .allowsHitTesting(false)
    }
}

enum ActivityMonthLabelLayout {
    struct Candidate {
        let week: Int
        let title: String
        let width: CGFloat
        let partial: Bool
    }

    struct Label {
        let title: String
        let offset: CGFloat
    }

    static func months(activity: UsageActivity, weeks: Int, cell: CGFloat, columnGap: CGFloat) -> [Int: Label] {
        let calendar = Localization.reportingCalendar
        let formatter = DateFormatter()
        formatter.locale = Localization.locale
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("MMM")
        let font = NSFont.systemFont(ofSize: 9)
        let candidates = (0..<weeks).compactMap { week -> Candidate? in
            let index = week * 7 - activity.leadingDays
            guard let date = activity.days.indices.contains(index) ? activity.days[index].date : (week == 0 ? activity.days.first?.date : nil) else { return nil }
            let firstWeek = calendar.component(.day, from: date) <= 7
            guard week == 0 || firstWeek else { return nil }
            let title = formatter.string(from: date)
            let width = ceil((title as NSString).size(withAttributes: [.font: font]).width)
            return Candidate(week: week, title: title, width: width, partial: week == 0 && !firstWeek)
        }
        return resolve(candidates, weeks: weeks, cell: cell, columnGap: columnGap)
    }

    static func resolve(_ candidates: [Candidate], weeks: Int, cell: CGFloat, columnGap: CGFloat = 3) -> [Int: Label] {
        let stride = cell + columnGap
        let availableWidth = CGFloat(weeks) * stride - columnGap
        let gap: CGFloat = 4
        var placed: [(candidate: Candidate, x: CGFloat)] = []
        for candidate in candidates.filter({ !$0.partial }) {
            let x = max(0, min(CGFloat(candidate.week) * stride, availableWidth - candidate.width))
            guard x + candidate.width <= availableWidth,
                  placed.last.map({ x >= $0.x + $0.candidate.width + gap }) ?? true else { continue }
            placed.append((candidate, x))
        }
        if let partial = candidates.first(where: \.partial),
           partial.width <= availableWidth,
           placed.first.map({ partial.width + gap <= $0.x }) ?? true {
            placed.insert((partial, 0), at: 0)
        }
        return Dictionary(uniqueKeysWithValues: placed.map {
            ($0.candidate.week, Label(title: $0.candidate.title, offset: $0.x - CGFloat($0.candidate.week) * stride))
        })
    }
}

private struct ActivityHoverReadout: View {
    let hover: HoverDwell<Int>
    let pointer: TooltipPointer
    let activity: UsageActivity
    let layout: ActivityCalendarLayout
    let inspectedDay: String?
    let showsDeviceBreakdown: Bool
    let width: CGFloat
    let reservesPendingLine: Bool
    @Environment(UsageStore.self) private var store

    var body: some View {
        if let position = hover.readoutTarget {
            let index = position - activity.leadingDays
            if activity.days.indices.contains(index) {
                let day = activity.days[index]
                let mark = layout.focusFrame(at: position)
                Color.clear
                    .selectedTooltip(avoiding: day.key == inspectedDay ? nil : mark, pointer: pointer) {
                        UsageBucketReadout(title: day.label, summary: day.summary, tokens: day.tokens, cost: day.cost,
                                           rows: showsDeviceBreakdown ? rows(for: day, at: index) : [], width: width, reservesPendingLine: reservesPendingLine)
                    }
            }
        }
    }
    private func rows(for day: ActivityDay, at index: Int) -> [OverviewDeviceRow] {
        // Device calendars use the same annual window, including empty days.
        func summary(_ calendar: UsageActivity?) -> UsageSummary? {
            guard let calendar, calendar.days.indices.contains(index), calendar.days[index].key == day.key else { return nil }
            return calendar.days[index].summary
        }
        let local = summary(store.cloudLocalActivityCalendar ?? store.activityCalendar)
        return [OverviewDeviceRow(id: "total", name: L("cloud.overview.total"), summary: day.summary),
                OverviewDeviceRow(id: "local", name: store.localDeviceName, summary: local)]
            + store.remoteActivityCalendars.map { id, calendar in
                OverviewDeviceRow(id: "remote:" + id, name: store.deviceName(id), summary: summary(calendar))
            }
    }

}
