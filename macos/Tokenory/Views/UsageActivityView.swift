// [INPUT]: Annual effective-ledger activity and day navigation callback.
// [OUTPUT]: Fixed YlGnBu calendar with isolated hover readout and direct day navigation.
// [POS]: Native overview history section; no palette customization.
// [PROTOCOL]: Update this header on change, then check AGENTS.md
import SwiftUI
import Observation

struct UsageActivityView: View {
    let report: ActivityReport
    let activity: UsageActivity
    let selectDay: (String) -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var hover = ActivityHover()
    private var palette: [Color] {
        (scheme == .dark ? [0x5965ae, 0x2c7fb8, 0x41b6c4, 0xa1dab4] : [0xa1dab4, 0x41b6c4, 0x2c7fb8, 0x253494]).map {
            Color(red: Double(($0 >> 16) & 255) / 255, green: Double(($0 >> 8) & 255) / 255, blue: Double($0 & 255) / 255)
        }
    }
    var body: some View {
        WorkspacePanel {
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
        return GeometryReader { geometry in
            let cell = max(7, (geometry.size.width - 26 - CGFloat(weeks - 1) * 3) / CGFloat(max(1, weeks)))
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
                                let index = week * 7 - activity.leadingDays
                                let date = activity.days.indices.contains(index) ? activity.days[index].date : activity.days.first?.date
                                let showMonth = week == 0 || (date.map { Localization.reportingCalendar.component(.day, from: $0) <= 7 } ?? false)
                                Text("")
                                    .font(.system(size: 9)).foregroundStyle(.secondary)
                                    .frame(width: cell, height: 16, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                                    .overlay(alignment: .leading) { if showMonth, let date { Text(monthName(date)).font(.system(size: 9)).foregroundStyle(.secondary).fixedSize() } }
                                    .accessibilityHidden(true)
                                ForEach(0..<7) { weekday in
                                    let i = week * 7 + weekday - activity.leadingDays
                                    if activity.days.indices.contains(i) {
                                        let day = activity.days[i]
                                        Button { hover.day = nil; selectDay(day.key) } label: {
                                            RoundedRectangle(cornerRadius: 2)
                                                .fill(day.tokens == 0 ? Color.primary.opacity(0.045) : palette[min(3, Int(Double(day.tokens) / Double(max(1, maxTokens)) * 4))])
                                                .frame(width: cell, height: 11)
                                        }.buttonStyle(.plain)
                                            .onHover { hovering in
                                                if hovering { hover.day = day }
                                                else if hover.day?.id == day.id { hover.day = nil }
                                            }
                                            .accessibilityLabel(day.label)
                                            .accessibilityValue(day.tokens.formatted() + " tokens")
                                    } else { Color.clear.frame(width: cell, height: 11) }
                                }
                            }
                        }
                    }
                }
            }.scrollIndicators(.hidden)
                .overlay(alignment: .topLeading) {
                    ActivityTooltip(hover: hover, activity: activity, cell: cell, width: geometry.size.width)

                }
        }.frame(height: 114)
    }
    private func weekdayName(_ day: Int, short: Bool) -> String {
        let calendar = Localization.reportingCalendar
        return (short ? calendar.veryShortWeekdaySymbols : calendar.weekdaySymbols)[(day + 1) % 7]
    }
    private func monthName(_ date: Date) -> String {
        let f = DateFormatter(); f.locale = Localization.locale; f.timeZone = Localization.reportingCalendar.timeZone
        f.setLocalizedDateFormatFromTemplate("MMM"); return f.string(from: date)
    }
}

@Observable private final class ActivityHover {
    var day: ActivityDay?
}

private struct ActivityTooltip: View {
    let hover: ActivityHover
    let activity: UsageActivity
    let cell: CGFloat
    let width: CGFloat
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        if let day = hover.day, let index = activity.days.firstIndex(where: { $0.id == day.id }) {
            let column = (index + activity.leadingDays) / 7
            readout(day).padding(12).frame(width: 248)
                .background(WorkspaceStyle.surface(scheme), in: RoundedRectangle(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.1), lineWidth: 0.5) }
                .offset(x: min(max(0, 26 + CGFloat(column) * (cell + 3) - 124), max(0, width - 248)), y: -75)
                .allowsHitTesting(false)
        }
    }
    private func readout(_ day: ActivityDay) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(day.label).fontWeight(.medium)
            HStack { Text("Tokens").foregroundStyle(.secondary); Spacer(); Text(day.tokens.formatted(.number.locale(Localization.locale))).monospacedDigit() }
            HStack { Text(L(day.summary?.costStatus == "partial" ? "cost.known" : "cost.estimate")).foregroundStyle(.secondary); Spacer(); Text(usd(day.cost)).monospacedDigit() }
            if let summary = day.summary, summary.unpricedTokens > 0 {
                Text(LF("usage.unpriced", compactTokens(summary.unpricedTokens))).foregroundStyle(.secondary)
            }
        }.font(.caption)
    }
}
