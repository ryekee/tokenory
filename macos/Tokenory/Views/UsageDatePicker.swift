import SwiftUI

struct UsageDatePicker: View {
    @Environment(UsageStore.self) private var store
    @State private var isPresented = false
    @State private var start = Date()
    @State private var end: Date? = Date()
    @State private var month = Date()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var calendar: Calendar { Localization.reportingCalendar }
    private var title: String {
        if store.dateRange == .custom, let from = store.filter.from, let to = store.filter.to { return Localization.dateRange(from, to) }
        return store.dateRange.title
    }
    var body: some View {
        Button { isPresented = true } label: { Label(title, systemImage: "calendar").lineLimit(1) }
            .labelStyle(.titleAndIcon).help(title)
            .accessibilityLabel(L("field.date")).accessibilityValue(title)
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                VStack(spacing: 16) {
                    HStack(alignment: .top, spacing: 16) {
                        VStack(spacing: 3) {
                            ForEach(UsageDateRange.allCases.filter { $0 != .custom }, id: \.self) { range in
                                Button {
                                    store.dateRange = range
                                    store.updateDateRange(); store.filter.offset = 0
                                    isPresented = false
                                } label: {
                                    HStack {
                                        Text(range.title)
                                        Spacer(minLength: 3)
                                        if store.dateRange == range { Image(systemName: "checkmark").font(.caption) }
                                    }
                                    .padding(.horizontal, 10).frame(height: 32).contentShape(Rectangle())
                                    .background(store.dateRange == range ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
                                }.buttonStyle(WorkspaceHoverStyle())
                            }
                        }.frame(width: 115).padding(.top, 35)
                        Divider()
                        VStack(spacing: 8) {
                            HStack {
                                Button { moveMonth(-1) } label: { Image(systemName: "chevron.left").frame(width: 20, height: 20) }
                                    .help(L("calendar.previous_month")).accessibilityLabel(L("calendar.previous_month"))
                                Spacer()
                                Text(L("range.custom")).font(.headline)
                                Spacer()
                                Button { moveMonth(1) } label: { Image(systemName: "chevron.right").frame(width: 20, height: 20) }
                                    .help(L("calendar.next_month")).accessibilityLabel(L("calendar.next_month"))
                            }.buttonStyle(.borderless)
                            HStack(alignment: .top, spacing: 18) {
                                monthGrid(month)
                                monthGrid(calendar.date(byAdding: .month, value: 1, to: month)!)
                            }
                        }
                    }.fixedSize(horizontal: false, vertical: true)
                    Divider()
                    HStack(spacing: 10) {
                        Text(end.map { Localization.dateRange(UsageStore.day(start), UsageStore.day($0)) } ?? L("calendar.choose_end"))
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button(L("action.cancel")) { isPresented = false }.keyboardShortcut(.cancelAction)
                        Button(L("action.apply")) {
                            guard let end else { return }
                            store.dateRange = .custom
                            var filter = store.filter
                            filter.from = UsageStore.day(start); filter.to = UsageStore.day(end); filter.offset = 0
                            store.filter = filter; isPresented = false
                        }.buttonStyle(.borderedProminent).disabled(end == nil).keyboardShortcut(.defaultAction)
                    }
                }.padding(18).frame(width: 660)
                    .onAppear {
                        let finish = store.filter.to.flatMap(Localization.date) ?? calendar.startOfDay(for: Date())
                        end = finish
                        start = store.filter.from.flatMap(Localization.date) ?? calendar.date(byAdding: .day, value: -29, to: finish)!
                        month = calendar.date(from: calendar.dateComponents([.year, .month], from: start))!
                    }
            }
    }
    private func moveMonth(_ delta: Int) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { month = calendar.date(byAdding: .month, value: delta, to: month)! }
    }
    private func monthGrid(_ date: Date) -> some View {
        let first = calendar.date(from: calendar.dateComponents([.year, .month], from: date))!
        let leading = (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
        let days = calendar.range(of: .day, in: .month, for: first)!.count
        return VStack(spacing: 8) {
            Text(Localization.month(first))
                .font(.callout.weight(.medium)).frame(height: 24)
            HStack(spacing: 0) {
                ForEach(0..<7, id: \.self) { offset in
                    Text(calendar.veryShortStandaloneWeekdaySymbols[(calendar.firstWeekday - 1 + offset) % 7])
                        .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 3) {
                ForEach(0..<42, id: \.self) { cell in
                    if cell >= leading && cell < leading + days {
                        let day = calendar.date(byAdding: .day, value: cell - leading, to: first)!
                        dayButton(day)
                    } else { Color.clear.frame(height: 30).accessibilityHidden(true) }
                }
            }
        }.frame(maxWidth: .infinity)
    }
    private func dayButton(_ date: Date) -> some View {
        let isStart = calendar.isDate(date, inSameDayAs: start)
        let isEnd = end.map { calendar.isDate(date, inSameDayAs: $0) } ?? false
        let included = end.map { date >= start && date <= $0 } ?? false
        let today = calendar.isDateInToday(date)
        return Button {
            if end != nil { start = date; end = nil }
            else if date < start { end = start; start = date }
            else { end = date }
        } label: {
            Text("\(calendar.component(.day, from: date))").font(.system(size: 12, weight: today ? .bold : .regular)).monospacedDigit()
                .foregroundStyle(isStart || isEnd ? Color.white : Color.primary)
                .frame(width: 30, height: 30)
                .background(isStart || isEnd ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 6))
                .overlay { if today && !isStart && !isEnd { RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 1) } }
                .frame(maxWidth: .infinity).contentShape(Rectangle())
                .background(included ? Color.accentColor.opacity(0.12) : .clear)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Localization.day(UsageStore.day(date)))
        .accessibilityAddTraits(isStart || isEnd || included ? [.isSelected] : [])
    }
}
