// [INPUT]: 当前用量筛选范围与日历交互。
// [OUTPUT]: 在工具栏及无记录状态打开共用日期浮层，并支持移动日期范围。
// [POS]: 统计窗口的日期工具栏控件与原生弹窗。
// [PROTOCOL]: Update this header on change, then check AGENTS.md
import SwiftUI

struct UsageDatePicker: View {
    @Environment(UsageStore.self) private var store
    @Binding var presentation: DateRangeDraft?

    private var title: String {
        if store.dateRange == .custom, let from = store.filter.from, let to = store.filter.to { return Localization.dateRange(from, to) }
        return store.dateRange.title
    }

    var body: some View {
        ControlGroup {
            calendarButton
            stepButton(.earlier, icon: "chevron.left", title: L("calendar.previous_range"))
            stepButton(.later, icon: "chevron.right", title: L("calendar.next_range"))
        }
    }

    private var calendarButton: some View {
        let title = title
        return Button {
            guard presentation == nil else { return }
            presentation = DateRangeDraft(filter: store.filter, selectedRange: store.dateRange)
        } label: {
            Label(title, systemImage: "calendar").lineLimit(1)
        }
        .labelStyle(.titleAndIcon).help(title)
        .accessibilityLabel(L("field.date")).accessibilityValue(title)
        .popover(item: $presentation, arrowEdge: .bottom) { draft in
            DateRangePopover(
                draft: draft,
                selectPreset: { range in
                    presentation = nil
                    store.selectDateRange(range)
                },
                cancel: { presentation = nil },
                apply: { start, end in
                    presentation = nil
                    store.selectCustomDateRange(start...end)
                }
            )
        }
    }

    private func stepButton(_ step: UsageStore.DateStep, icon: String, title: String) -> some View {
        Button {
            presentation = nil
            store.stepDateRange(step)
        } label: {
            Label(title, systemImage: icon).labelStyle(.iconOnly)
        }
        .accessibilityLabel(title)
        .help(title)
        .disabled(store.steppedDateRange(step) == nil)
    }
}

private struct DateRangePopover: View {
    // Editing the draft locally keeps the presentation item stable until dismissal.
    @State var draft: DateRangeDraft
    let selectPreset: (UsageDateRange) -> Void
    let cancel: () -> Void
    let apply: (Date, Date) -> Void

    private static let presets = UsageDateRange.allCases.filter { $0 != .custom }
    private static let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)

    var body: some View {
        let today = draft.calendar.startOfDay(for: .now)
        VStack(spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 3) {
                    ForEach(Self.presets, id: \.self) { range in
                        let selected = draft.selectedRange == range
                        Button { selectPreset(range) } label: {
                            HStack {
                                Text(range.title)
                                Spacer(minLength: 3)
                                if selected { Image(systemName: "checkmark").font(.caption) }
                            }
                            .padding(.horizontal, 10).frame(height: 32).contentShape(Rectangle())
                            .background(selected ? WorkspaceStyle.selection.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
                        }.buttonStyle(WorkspaceHoverStyle())
                    }
                }.frame(width: 115).padding(.top, 35)
                Divider()
                VStack(spacing: 8) {
                    HStack {
                        Button { draft.moveMonth(-1) } label: { Image(systemName: "chevron.left").frame(width: 20, height: 20) }
                            .help(L("calendar.previous_month")).accessibilityLabel(L("calendar.previous_month"))
                        Spacer()
                        Text(L("range.custom")).font(.headline)
                        Spacer()
                        Button { draft.moveMonth(1) } label: { Image(systemName: "chevron.right").frame(width: 20, height: 20) }
                            .help(L("calendar.next_month")).accessibilityLabel(L("calendar.next_month"))
                    }.buttonStyle(.borderless)
                    HStack(alignment: .top, spacing: 18) {
                        monthGrid(draft.firstMonth, today: today)
                        monthGrid(draft.secondMonth, today: today)
                    }
                }
            }.fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack(spacing: 10) {
                Text(draft.rangeLabel ?? L("calendar.choose_end"))
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button(L("action.cancel"), action: cancel).keyboardShortcut(.cancelAction)
                Button(L("action.apply")) {
                    guard let end = draft.end else { return }
                    apply(draft.start, end)
                }.buttonStyle(.borderedProminent).disabled(draft.end == nil).keyboardShortcut(.defaultAction)
            }
        }.padding(18).frame(width: 660)
    }

    private func monthGrid(_ month: CalendarMonth, today: Date) -> some View {
        VStack(spacing: 8) {
            Text(month.label)
                .font(.callout.weight(.medium)).frame(height: 24)
            HStack(spacing: 0) {
                ForEach(draft.weekdays.indices, id: \.self) { offset in
                    Text(draft.weekdays[offset])
                        .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: Self.columns, spacing: 3) {
                ForEach(month.cells.indices, id: \.self) { cell in
                    if let day = month.cells[cell] {
                        dayButton(day, today: today)
                    } else { Color.clear.frame(height: 30).accessibilityHidden(true) }
                }
            }
        }.frame(maxWidth: .infinity)
    }

    private func dayButton(_ day: CalendarMonth.Day, today: Date) -> some View {
        let endpoint = day.date == draft.start || day.date == draft.end
        let included = draft.end.map { day.date >= draft.start && day.date <= $0 } ?? false
        let isToday = day.date == today
        return Button { draft.selectDay(day.date) } label: {
            Text("\(day.number)").font(.system(size: 12, weight: isToday ? .bold : .regular)).monospacedDigit()
                .foregroundStyle(endpoint ? WorkspaceStyle.onSelection : Color.primary)
                .frame(width: 30, height: 30)
                .background(endpoint ? WorkspaceStyle.selection : .clear, in: RoundedRectangle(cornerRadius: 6))
                .overlay { if isToday && !endpoint { RoundedRectangle(cornerRadius: 6).strokeBorder(WorkspaceStyle.selection, lineWidth: 1) } }
                .frame(maxWidth: .infinity).contentShape(Rectangle())
                .background(included ? WorkspaceStyle.selection.opacity(0.12) : .clear)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(day.label)
        .accessibilityAddTraits(endpoint || included ? [.isSelected] : [])
    }
}

struct DateRangeDraft: Identifiable {
    let id = UUID()
    let selectedRange: UsageDateRange
    let calendar: Calendar
    let weekdays: [String]
    private(set) var start: Date
    private(set) var end: Date?
    fileprivate var firstMonth: CalendarMonth
    fileprivate var secondMonth: CalendarMonth
    private let dayFormatter: DateFormatter
    private let monthFormatter: DateFormatter
    private let rangeFormatter: DateIntervalFormatter

    init(filter: UsageFilter, selectedRange: UsageDateRange) {
        let calendar = Localization.reportingCalendar
        self.calendar = calendar
        self.selectedRange = selectedRange
        let weekdaySymbols = calendar.veryShortStandaloneWeekdaySymbols
        weekdays = weekdaySymbols.indices.map { weekdaySymbols[(calendar.firstWeekday - 1 + $0) % 7] }

        let finish = filter.to.flatMap(Localization.date) ?? calendar.startOfDay(for: .now)
        let start = filter.from.flatMap(Localization.date) ?? calendar.date(byAdding: .day, value: -29, to: finish)!
        self.start = calendar.startOfDay(for: start)
        end = calendar.startOfDay(for: finish)

        let dayFormatter = DateFormatter()
        dayFormatter.locale = calendar.locale
        dayFormatter.timeZone = calendar.timeZone
        dayFormatter.dateStyle = .medium
        self.dayFormatter = dayFormatter

        let monthFormatter = DateFormatter()
        monthFormatter.locale = calendar.locale
        monthFormatter.timeZone = calendar.timeZone
        monthFormatter.setLocalizedDateFormatFromTemplate("yMMMM")
        self.monthFormatter = monthFormatter

        rangeFormatter = DateIntervalFormatter()
        rangeFormatter.locale = calendar.locale
        rangeFormatter.timeZone = calendar.timeZone
        rangeFormatter.dateStyle = .medium
        rangeFormatter.timeStyle = .none

        let first = calendar.dateInterval(of: .month, for: start)!.start
        firstMonth = CalendarMonth(first: first, calendar: calendar, monthFormatter: monthFormatter, dayFormatter: dayFormatter)
        let next = calendar.date(byAdding: .month, value: 1, to: first)!
        secondMonth = CalendarMonth(first: next, calendar: calendar, monthFormatter: monthFormatter, dayFormatter: dayFormatter)
    }

    var rangeLabel: String? { end.map { rangeFormatter.string(from: start, to: $0) } }

    mutating func moveMonth(_ delta: Int) {
        if delta < 0 {
            let date = calendar.date(byAdding: .month, value: -1, to: firstMonth.first)!
            secondMonth = firstMonth
            firstMonth = CalendarMonth(first: date, calendar: calendar, monthFormatter: monthFormatter, dayFormatter: dayFormatter)
        } else {
            let date = calendar.date(byAdding: .month, value: 1, to: secondMonth.first)!
            firstMonth = secondMonth
            secondMonth = CalendarMonth(first: date, calendar: calendar, monthFormatter: monthFormatter, dayFormatter: dayFormatter)
        }
    }

    mutating func selectDay(_ date: Date) {
        if end != nil {
            start = date
            end = nil
        } else if date < start {
            end = start
            start = date
        } else {
            end = date
        }
    }
}

fileprivate struct CalendarMonth {
    struct Day {
        let date: Date
        let number: Int
        let label: String
    }

    let first: Date
    let label: String
    let cells: [Day?]

    init(first: Date, calendar: Calendar, monthFormatter: DateFormatter, dayFormatter: DateFormatter) {
        self.first = calendar.dateInterval(of: .month, for: first)!.start
        label = monthFormatter.string(from: first)
        let leading = (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
        let count = calendar.range(of: .day, in: .month, for: first)!.count
        cells = (0..<42).map { cell in
            let offset = cell - leading
            guard (0..<count).contains(offset) else { return nil }
            let date = calendar.startOfDay(for: calendar.date(byAdding: .day, value: offset, to: first)!)
            return Day(date: date, number: offset + 1, label: dayFormatter.string(from: date))
        }
    }
}
