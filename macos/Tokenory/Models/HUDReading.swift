// [INPUT]: Today's all-agent summary and selected display metric.
// [OUTPUT]: Exact integer drum targets and the approved braking curve.
// [POS]: Pure HUD presentation and motion model; amounts are display-only cents.
// [PROTOCOL]: Update this header on change, then check AGENTS.md
import Foundation

enum HUDMetric: String, CaseIterable { case tokens, cost }

struct HUDReading: Equatable {
    let day: String
    let metric: HUDMetric
    let value: Int64?
    let partial: Bool

    init(day: String, metric: HUDMetric, summary: UsageSummary?) {
        self.day = day; self.metric = metric
        partial = metric == .cost && summary?.costStatus == "partial"
        switch metric {
        case .tokens: value = summary?.tokens
        case .cost:
            if let amount = summary?.knownEstimatedCostUsd, amount.isFinite, amount >= 0,
               (amount * 100).rounded() < Double(Int64.max) {
                value = Int64((amount * 100).rounded())
            } else { value = nil }
        }
    }

    var formatted: String {
        guard let value else { return "—" }
        if metric == .tokens { return value.formatted(.number.locale(Locale(identifier: "en_US"))) }
        return "$" + (value / 100).formatted(.number.locale(Locale(identifier: "en_US"))) + String(format: ".%02lld", value % 100)
    }
}

struct HUDRoll {
    let starts: [Double]
    let travel: [Double]
    var duration: TimeInterval { 4.2 }
    var maxTravel: Double { travel.max() ?? 0 }

    init(from: Int64, to: Int64) {
        let count = max(6, String(max(from, to)).count)
        var starts: [Double] = [], travel: [Double] = []
        var power: Int64 = 1
        for index in 0..<count {
            let start = from / power, difference = to / power - start
            starts.insert(Double(start % 10), at: 0)
            // Bound visual rotations; the final digit remains exact even above Double's integer precision.
            travel.insert(Double(difference > 30 ? 20 + difference % 10 : difference), at: 0)
            if index < count - 1 { power *= 10 }
        }
        self.starts = starts; self.travel = travel
    }

    static func curve(_ time: Double) -> (progress: Double, speed: Double) {
        let t = min(1, max(0, time)), acceleration = 0.16, cruiseEnd = 0.34, brake = 0.66
        let area = acceleration / 2 + cruiseEnd - acceleration + brake / 3
        if t < acceleration { return (t * t / (2 * acceleration * area), t / (acceleration * area)) }
        if t < cruiseEnd { return ((acceleration / 2 + t - acceleration) / area, 1 / area) }
        let remaining = (1 - t) / brake
        return (1 - brake * pow(remaining, 3) / (3 * area), remaining * remaining / area)
    }

    func positions(at time: Double) -> [Double] {
        let progress = Self.curve(time).progress
        return zip(starts, travel).map { $0 + $1 * progress }
    }
}
