// [INPUT]: Combined annual activity, per-device calendars and day navigation callback.
// [OUTPUT]: Fixed YlGnBu calendar with isolated hover readout and direct day navigation.
// [POS]: Native overview history section; no palette customization.
// [PROTOCOL]: Update this header on change, then check AGENTS.md
import AppKit
import SwiftUI
import Observation

struct UsageActivityView: View {
    let report: ActivityReport
    let activity: UsageActivity
    var showsDeviceBreakdown = true
    let selectDay: (String) -> Void
    @Environment(UsageStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @State private var hover = ActivityHover()
    @State private var tooltipPointer = TooltipPointer()
    private var palette: [Color] {
        (scheme == .dark ? [0x5965ae, 0x2c7fb8, 0x41b6c4, 0xa1dab4] : [0xa1dab4, 0x41b6c4, 0x2c7fb8, 0x253494]).map {
            Color(red: Double(($0 >> 16) & 255) / 255, green: Double(($0 >> 8) & 255) / 255, blue: Double($0 & 255) / 255)
        }
    }
    var body: some View {
        WorkspacePanel(preservesCalendarAppearance: true) {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text(L("activity.title")).font(.headline)
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

            }
        }
    }
    private func calendar(_ activity: UsageActivity) -> some View {
        let weeks = (activity.leadingDays + activity.days.count + 6) / 7
        let maxTokens = activity.days.map(\.tokens).max() ?? 0
        let partial = activity.days.contains { ($0.summary?.unpricedTokens ?? 0) > 0 }
        let names = showsDeviceBreakdown ? [L("cloud.overview.total"), store.localDeviceName] + store.remoteActivityCalendars.keys.map(store.deviceName) : []
        let width = CursorTooltipLayout.summaryWidth(names: names, tokens: maxTokens, cost: activity.days.compactMap(\.cost).max(), partial: partial)
        return GeometryReader { geometry in
            let cell = max(7, (geometry.size.width - 26 - CGFloat(weeks - 1) * 3) / CGFloat(max(1, weeks)))
            let months = ActivityMonthLabelLayout.months(activity: activity, weeks: weeks, cell: cell)
            ScrollView(.horizontal) {
                HStack(alignment: .bottom, spacing: 8) {
                    VStack(spacing: 3) {
                        ForEach(0..<7) { weekday in
                            Text(weekday % 2 == 0 ? weekdayName(weekday, short: true) : "")
                                .font(.system(size: 9)).foregroundStyle(.secondary).frame(width: 18, height: 11)
                        }
                    }
                    HStack(alignment: .bottom, spacing: 3) {
                        ForEach(0..<weeks, id: \.self) { week in
                            VStack(spacing: 3) {
                                Text("")
                                    .font(.system(size: 9)).foregroundStyle(.secondary)
                                    .frame(width: cell, height: 16, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                                    .overlay(alignment: .leading) {
                                        if let month = months[week] {
                                            Text(month.title).font(.system(size: 9)).foregroundStyle(.secondary)
                                                .fixedSize().offset(x: month.offset)
                                        }
                                    }
                                    .accessibilityHidden(true)
                                ForEach(0..<7) { weekday in
                                    let i = week * 7 + weekday - activity.leadingDays
                                    if activity.days.indices.contains(i) {
                                        let day = activity.days[i]
                                        Button { hover.index = nil; selectDay(day.key) } label: {
                                            RoundedRectangle(cornerRadius: 2)
                                                .fill(day.tokens == 0 ? Color.primary.opacity(0.045) : palette[min(3, Int(Double(day.tokens) / Double(max(1, maxTokens)) * 4))])
                                                .frame(width: cell, height: 11)
                                        }.buttonStyle(.plain)
                                            .accessibilityLabel(day.label)
                                            .accessibilityValue(day.tokens.formatted() + " tokens")
                                    } else { Color.clear.frame(width: cell, height: 11) }
                                }
                            }
                        }
                    }
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point):
                            tooltipPointer.move(to: point)
                            let column = Int(floor(point.x / (cell + 3)))
                            let row = Int(floor((point.y - 19) / 14))
                            let index = column * 7 + row - activity.leadingDays
                            let box = CGRect(x: CGFloat(column) * (cell + 3), y: 19 + CGFloat(row) * 14, width: cell, height: 11)
                            let next = (0..<7).contains(row) && activity.days.indices.contains(index) && box.contains(point) ? index : nil
                            if hover.index != next { hover.index = next }
                        case .ended: hover.index = nil
                        }
                    }
                    .background {
                        ActivityTooltip(hover: hover, pointer: tooltipPointer, activity: activity, cell: cell, showsDeviceBreakdown: showsDeviceBreakdown,
                                        width: width, reservesPendingLine: partial)
                    }
                }
            }.scrollIndicators(.hidden)
        }.frame(height: 114)
    }
    private func weekdayName(_ day: Int, short: Bool) -> String {
        let calendar = Localization.reportingCalendar
        return (short ? calendar.veryShortWeekdaySymbols : calendar.weekdaySymbols)[(day + 1) % 7]
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

    static func months(activity: UsageActivity, weeks: Int, cell: CGFloat) -> [Int: Label] {
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
        return resolve(candidates, weeks: weeks, cell: cell)
    }

    static func resolve(_ candidates: [Candidate], weeks: Int, cell: CGFloat) -> [Int: Label] {
        let stride = cell + 3
        let availableWidth = CGFloat(weeks) * stride - 3
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

@Observable private final class ActivityHover {
    var index: Int?
}

private struct ActivityTooltip: View {
    let hover: ActivityHover
    let pointer: TooltipPointer
    let activity: UsageActivity
    let cell: CGFloat
    let showsDeviceBreakdown: Bool
    let width: CGFloat
    let reservesPendingLine: Bool
    @Environment(UsageStore.self) private var store

    var body: some View {
        if let index = hover.index, activity.days.indices.contains(index) {
            let day = activity.days[index]
            let offset = index + activity.leadingDays
            let mark = CGRect(x: CGFloat(offset / 7) * (cell + 3), y: 19 + CGFloat(offset % 7) * 14, width: cell, height: 11)
            Color.clear.selectedTooltip(avoiding: mark, pointer: pointer) {
                UsageBucketReadout(title: day.label, summary: day.summary, tokens: day.tokens, cost: day.cost,
                                   rows: showsDeviceBreakdown ? rows(for: day, at: index) : [], width: width, reservesPendingLine: reservesPendingLine)
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
            + store.remoteActivityCalendars.keys.sorted().map { id in
                OverviewDeviceRow(id: "remote:" + id, name: store.deviceName(id), summary: summary(store.remoteActivityCalendars[id]))
            }
    }

}
