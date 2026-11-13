// [INPUT]: Effective daily ledger aggregates in Beijing reporting dates.
// [OUTPUT]: Calendar cells, habits and aligned model history with optional costs.
// [POS]: Pure presentation data; totals remain raw when averages or order change.
// [PROTOCOL]: Update this header on change, then check AGENTS.md
import Foundation

enum UsageMetric: String, CaseIterable {
    case tokens, cost
    var title: String { L(self == .tokens ? "usage.tokens" : "history.cost") }
}

struct ActivityDay: Identifiable {
    let date: Date
    let key: String
    let summary: UsageSummary?
    var id: String { key }
    var tokens: Int64 { summary?.tokens ?? 0 }
    var cost: Double? { summary?.knownEstimatedCostUsd ?? (tokens == 0 ? 0 : nil) }
    var label: String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: Localization.locale,
                                       calendar: Localization.reportingCalendar, timeZone: Localization.reportingCalendar.timeZone))
    }
}

struct UsageActivity {
    let days: [ActivityDay]
    let leadingDays: Int
    let weekdayTokens: [Int64]
    var activeDays: Int { days.filter { $0.tokens > 0 }.count }
    var peak: ActivityDay? { days.filter { $0.tokens > 0 }.max { $0.tokens < $1.tokens } }
    var topWeekday: Int? {
        guard let highest = weekdayTokens.max(), highest > 0 else { return nil }
        return weekdayTokens.firstIndex(of: highest)
    }
    init(report: ActivityReport) {
        let calendar = Localization.reportingCalendar
        let lookup = Dictionary(uniqueKeysWithValues: report.daily.map { ($0.key, $0.summary) })
        guard let start = Localization.date(report.from), let end = Localization.date(report.to) else {
            days = []; leadingDays = 0; weekdayTokens = Array(repeating: 0, count: 7); return
        }
        let count = calendar.dateComponents([.day], from: start, to: end).day! + 1
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone; formatter.dateFormat = "yyyy-MM-dd"
        days = (0..<max(0, count)).map { offset in
            let date = calendar.date(byAdding: .day, value: offset, to: start)!
            let key = formatter.string(from: date)
            return ActivityDay(date: date, key: key, summary: lookup[key])
        }
        leadingDays = (calendar.component(.weekday, from: start) + 5) % 7
        var weekdays = Array(repeating: Int64(0), count: 7)
        for day in days { weekdays[(calendar.component(.weekday, from: day.date) + 5) % 7] += day.tokens }
        weekdayTokens = weekdays
    }
    static func dayKey(_ date: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = Localization.reportingCalendar.timeZone; f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}

struct HistorySeries: Identifiable {
    let client: String
    let model: String
    let shade: Int
    let values: [Double?]
    let rawValues: [Double?]
    let total: Double?
    var id: String { client + "\u{0}" + model }
}

struct UsageHistory {
    let days: [ActivityDay]
    let series: [HistorySeries]
    let maximum: Double
    let total: Double?
    let unpricedTokens: Int64
    let metric: UsageMetric
    let average: Bool

    init(report: ActivityReport, metric: UsageMetric, average: Bool, client: String? = nil, newestFirst: Bool = false, calendarDays preparedDays: [ActivityDay]? = nil) {
        self.metric = metric; self.average = average
        let calendarDays = preparedDays ?? UsageActivity(report: report).days
        let rows = report.modelDays.filter { client == nil || $0.client == client }
        let grouped = Dictionary(grouping: rows, by: { $0.client + "\u{0}" + $0.model })
        let keys = grouped.keys.sorted {
            let a = grouped[$0]!, b = grouped[$1]!
            if a[0].client != b[0].client { return a[0].client < b[0].client }
            let at = a.reduce(Int64(0)) { $0 + $1.summary.tokens }, bt = b.reduce(Int64(0)) { $0 + $1.summary.tokens }
            return at == bt ? $0 < $1 : at > bt
        }
        var shades: [String: Int] = [:]
        series = keys.map { key in
            let group = grouped[key]!, first = group[0]
            let lookup = Dictionary(uniqueKeysWithValues: group.map { ($0.date, $0.summary) })
            let raw: [Double?] = calendarDays.map { day in
                guard let summary = lookup[day.key] else { return 0 }
                return metric == .tokens ? Double(summary.tokens) : summary.knownEstimatedCostUsd ?? (summary.tokens == 0 ? 0 : nil)
            }
            let values = average ? Self.trailingAverage(raw) : raw
            let shade = shades[first.client, default: 0]; shades[first.client] = shade + 1
            return HistorySeries(client: first.client, model: first.model, shade: shade,
                                 values: newestFirst ? Array(values.reversed()) : values,
                                 rawValues: newestFirst ? Array(raw.reversed()) : raw,
                                 total: raw.contains(where: { $0 != nil }) ? raw.compactMap { $0 }.reduce(0, +) : nil)
        }
        days = newestFirst ? Array(calendarDays.reversed()) : calendarDays
        let costs = rows.compactMap(\.summary.knownEstimatedCostUsd)
        total = metric == .tokens ? Double(rows.reduce(Int64(0)) { $0 + $1.summary.tokens })
            : rows.isEmpty ? 0 : costs.isEmpty ? nil : costs.reduce(0, +)
        unpricedTokens = rows.reduce(0) { $0 + $1.summary.unpricedTokens }
        let plottedSeries = series
        maximum = max(1, (0..<calendarDays.count).map { index in plottedSeries.compactMap { $0.values[index] }.reduce(0, +) }.max() ?? 0) * 1.08
    }

    static func trailingAverage(_ values: [Double?], window: Int = 30) -> [Double?] {
        var sum = 0.0, unknown = 0
        return values.enumerated().map { index, value in
            if let value { sum += value } else { unknown += 1 }
            if index >= window {
                if let old = values[index - window] { sum -= old } else { unknown -= 1 }
            }
            return unknown > 0 ? nil : sum / Double(min(window, index + 1))
        }
    }
}
