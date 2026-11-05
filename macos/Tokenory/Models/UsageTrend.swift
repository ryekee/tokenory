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

    init(report: UsageReport, filter: UsageFilter, now: Date = Date()) {
        hourly = report.hourly != nil
        unallocatedTokens = report.hourly?.unallocated.tokens ?? 0
        var values: [(Date, UsageSummary?)] = []
        let duration: TimeInterval = hourly ? 3600 : 86400
        if let hours = report.hourly, let day = filter.from.flatMap(Localization.date) {
            let parser = ISO8601DateFormatter()
            let lookup = Dictionary(uniqueKeysWithValues: hours.buckets.compactMap { group in
                parser.date(from: group.key).map { ($0, group.summary) }
            })
            values = (0..<24).map { hour in
                let date = day.addingTimeInterval(Double(hour) * 3600)
                return (date, lookup[date])
            }
        } else {
            values = report.daily.compactMap { group in Localization.date(group.key).map { ($0, group.summary) } }
                .sorted { $0.0 < $1.0 }
        }
        hasPricedUsage = values.contains { $0.1?.knownEstimatedCostUsd != nil }
        var segment = 0
        var previous: Date?
        points = values.map { date, summary in
            let future = date > now
            if summary?.costStatus == "unknown" || future || (previous.map { date.timeIntervalSince($0) > duration * 1.01 } ?? false) {
                segment += 1
            }
            previous = date
            return UsageTrendPoint(start: date, duration: duration, summary: summary, costSegment: segment, isFuture: future)
        }
        let start = values.first?.0 ?? now
        domain = start...(values.last?.0 ?? start).addingTimeInterval(duration)
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
