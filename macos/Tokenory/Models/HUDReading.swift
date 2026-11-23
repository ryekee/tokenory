// [INPUT]: Today's all-agent summary and selected display metric.
// [OUTPUT]: Device-local day windows, exact drum targets, approved braking curve and velocity-continuous retargeting.
// [POS]: Pure HUD presentation and motion model; tokens remain exact integers; costs use display-only cents.
// [PROTOCOL]: Update this header on change, then check AGENTS.md
import Foundation

struct LocalUsageDay {
    let day: String
    let timeZone: String
    let start: Date
    let end: Date
    var startMs: Int64 { Int64(start.timeIntervalSince1970 * 1000) }
    var endMs: Int64 { Int64(end.timeIntervalSince1970 * 1000) }

    init(now: Date, timeZone: TimeZone = .autoupdatingCurrent) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let bounds = calendar.dateInterval(of: .day, for: now)!
        start = bounds.start
        end = bounds.end
        day = Localization.dayKey(now, timeZone: timeZone)
        self.timeZone = timeZone.identifier
    }
}

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

struct HUDDrumMotion {
    let start: Double
    let target: Double
    let startTime: TimeInterval
    let duration: TimeInterval
    let initialSpeed: Double?
    var endTime: TimeInterval { startTime + duration }

    func sample(at elapsed: TimeInterval) -> (position: Double, speed: Double) {
        let t = min(1, max(0, (elapsed - startTime) / duration))
        if t >= 1 { return (target, 0) }
        let distance = target - start
        guard let initialSpeed, distance > 0 else {
            let curve = HUDRoll.curve(t)
            return (start + distance * curve.progress, distance * curve.speed / duration)
        }
        let slope = initialSpeed * duration / distance
        // Hermite interpolation matches the current velocity and ends at rest.
        let progress = (slope - 2) * t * t * t + (3 - 2 * slope) * t * t + slope * t
        let speed = (3 * (slope - 2) * t * t + 2 * (3 - 2 * slope) * t + slope) * distance / duration
        return (start + distance * progress, speed)
    }

    func extending(by increment: Double, at elapsed: TimeInterval, duration: TimeInterval) -> HUDDrumMotion {
        guard increment > 0 else { return self }
        let current = sample(at: elapsed)
        var destination = target + increment
        // Repeated updates must not accumulate a queue of whole revolutions.
        if destination - current.position > 40 {
            destination -= floor((destination - current.position - 20) / 10) * 10
        }
        return Self.retargeting(from: current, to: destination, at: elapsed, duration: duration)
    }

    static func retargeting(from current: (position: Double, speed: Double), to destination: Double,
                            at elapsed: TimeInterval, duration: TimeInterval) -> HUDDrumMotion {
        let distance = destination - current.position
        // A normalized initial slope <= 3 keeps the entire path forward and prevents overshoot.
        let brakingDuration = current.speed > 0 && distance > 0 ? min(duration, 3 * distance / current.speed) : duration
        return HUDDrumMotion(start: current.position, target: destination, startTime: elapsed,
                             duration: brakingDuration, initialSpeed: current.speed)
    }
}

// Carry timing uses the same visible units travel as the original HUD. Beyond
// that limit, each drum keeps the original bounded winding behavior.
struct HUDCarryRoll {
    static let maximumTravel: Int64 = 30
    private let from: Int64
    private var target: Int64
    private var motion: HUDDrumMotion
    private var lateEngagement: [Int64: Double] = [:]
    private var places: [Int64]
    var endTime: TimeInterval { motion.endTime }

    init?(from: Int64, to: Int64, duration: TimeInterval) {
        guard to > from, to - from <= Self.maximumTravel else { return nil }
        self.from = from
        self.target = to
        motion = HUDDrumMotion(start: 0, target: Double(to - from), startTime: 0, duration: duration, initialSpeed: nil)
        places = Self.drumPlaces(to)
    }

    mutating func extend(to next: Int64, at elapsed: TimeInterval, duration: TimeInterval) -> Bool {
        guard next - from <= Self.maximumTravel else { return false }
        let current = motion.sample(at: elapsed).position
        places = Self.drumPlaces(next)
        for place in places where place > 1 && next / place > target / place {
            // If an update makes a carry reachable while inside its lead-in,
            // engage at the current position instead of jumping into the step.
            let firstNewBoundary = (target / place + 1) * place - from
            if Double(firstNewBoundary) - Double(place) * 0.2 < current {
                lateEngagement[place] = current
            }
        }
        motion = motion.extending(by: Double(next - target), at: elapsed, duration: duration)
        target = next
        return true
    }

    func positions(at elapsed: TimeInterval) -> [Double] {
        let reading = motion.sample(at: elapsed)
        return places.map { drum(at: $0, reading: reading).position }
    }

    func boundedMotions(to next: Int64, at elapsed: TimeInterval, duration: TimeInterval) -> [HUDDrumMotion] {
        let reading = motion.sample(at: elapsed)
        return Self.drumPlaces(next).map { place in
            let current = drum(at: place, reading: reading)
            let digit = from / place % 10
            let steps = next / place - from / place - (Int64(floor(current.position)) - digit)
            let travel = steps > 30 ? 20 + steps % 10 : steps
            let destination = floor(current.position) + Double(travel)
            return HUDDrumMotion.retargeting(from: current, to: destination, at: elapsed, duration: duration)
        }
    }

    private func drum(at place: Int64, reading: (position: Double, speed: Double)) -> (position: Double, speed: Double) {
        let initial = from / place
        if place == 1 { return (Double(initial % 10) + reading.position, reading.speed) }
        let reached = (from + Int64(reading.position)) / place
        let digit = Double(initial % 10 + reached - initial)
        guard reached < target / place else { return (digit, 0) }
        let boundary = Double((reached + 1) * place - from)
        let start = max(0, boundary - Double(place) * 0.2, lateEngagement[place] ?? 0)
        guard reading.position > start else { return (digit, 0) }
        let length = boundary - start
        let t = min(1, (reading.position - start) / length)
        // Ease across the lead-in and arrive at the next digit at the carry.
        return (digit + t * t * (3 - 2 * t), 6 * t * (1 - t) * reading.speed / length)
    }

    private static func drumPlaces(_ value: Int64) -> [Int64] {
        var places: [Int64] = [1]
        for _ in 1..<max(6, String(value).count) { places.append(places[places.count - 1] * 10) }
        return places.reversed()
    }
}
