import Foundation

struct UsageTrendPoint: Identifiable {
    let start: Date
    let duration: TimeInterval
    let summary: UsageSummary?
    let costSegment: Int
    let isFuture: Bool
    var id: Date { start }
    var center: Date { start.addingTimeInterval(duration / 2) }
    var tokens: Int64? { isFuture ? nil : summary?.tokens ?? 0 }
    var cost: Double? { isFuture ? nil : summary.map(\.knownEstimatedCostUsd) ?? 0 }
}

struct UsageTrend {
    let points: [UsageTrendPoint]
    let domain: ClosedRange<Date>
    let hourly: Bool
    let unallocatedTokens: Int64
    let tokenMaximum: Double
    let costMaximum: Double
    let hasPricedUsage: Bool

    var axisPoints: [UsageTrendPoint] {
        if hourly { return stride(from: 0, to: points.count, by: 4).map { points[$0] } }
        guard points.count > 7 else { return points }
        return (0...4).map { points[$0 * (points.count - 1) / 4] }
    }

    init(report: UsageReport, filter: UsageFilter, now: Date = Date(), timeZone: TimeZone = .autoupdatingCurrent) {
        hourly = report.hourly != nil
        unallocatedTokens = report.hourly?.unallocated.tokens ?? 0
        var calendar = Localization.reportingCalendar
        calendar.timeZone = timeZone
        let values: [(start: Date, duration: TimeInterval, summary: UsageSummary?)]
        if let hours = report.hourly, let day = filter.from.flatMap({ Localization.date($0, timeZone: timeZone) }),
           let bounds = calendar.dateInterval(of: .day, for: day) {
            let parser = ISO8601DateFormatter()
            let lookup = Dictionary(uniqueKeysWithValues: hours.buckets.compactMap { group in
                parser.date(from: group.key).map { ($0, group.summary) }
            })
            values = stride(from: 0.0, to: bounds.duration, by: 3600).map { elapsed in
                let date = bounds.start.addingTimeInterval(elapsed)
                return (date, min(3600, bounds.duration - elapsed), lookup[date])
            }
        } else {
            values = report.daily.compactMap { group in
                guard let day = Localization.date(group.key, timeZone: timeZone),
                      let bounds = calendar.dateInterval(of: .day, for: day) else { return nil }
                return (bounds.start, bounds.duration, group.summary)
            }.sorted { $0.start < $1.start }
        }
        hasPricedUsage = values.contains { $0.summary?.knownEstimatedCostUsd != nil }
        var segment = 0
        var previousEnd: Date?
        points = values.map { date, duration, summary in
            let future = date > now
            if summary?.costStatus == "unknown" || future || (previousEnd.map { date > $0 } ?? false) {
                segment += 1
            }
            previousEnd = date.addingTimeInterval(duration)
            return UsageTrendPoint(start: date, duration: duration, summary: summary, costSegment: segment, isFuture: future)
        }
        let start = values.first?.start ?? now
        let end = values.last.map { $0.start.addingTimeInterval($0.duration) } ?? start.addingTimeInterval(86400)
        domain = start...end
        tokenMaximum = Self.axisMaximum(points.compactMap { $0.tokens.map(Double.init) }.max() ?? 0)
        costMaximum = Self.axisMaximum(points.compactMap(\.cost).max() ?? 0)
    }

    // Each metric has its own zero-based, labelled scale. The shared plot uses
    // fractions only for geometry; readouts and accessibility keep actual units.
    static func axisMaximum(_ value: Double) -> Double {
        guard value > 0 else { return 1 }
        let magnitude = pow(10, floor(log10(value)))
        let scaled = value / magnitude
        let step = [1.0, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10].first { $0 >= scaled * 1.08 } ?? 10
        return step * magnitude
    }
}
