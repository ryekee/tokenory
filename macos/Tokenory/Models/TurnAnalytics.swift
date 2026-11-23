// [INPUT]: Multi-agent completed main-turn analytics and support capabilities from the Rust worker.
// [OUTPUT]: Validated turns, searchable projects, titles and IDs, whole-range summaries and speed distributions.
// [POS]: Turn analytics presentation boundary; independent of priced usage pagination.
// [PROTOCOL]: Update this header on change, then check AGENTS.md
import Foundation

struct TurnQuery: Codable, Hashable, Sendable {
    var from: String?
    var to: String?
    var model: String?
    var client: String? = nil
    var timestampFromMs: Int64? = nil
    var timestampToMs: Int64? = nil
}

struct TurnCapability: Decodable, Sendable {
    let client: String
    let supported: Bool
    let reason: String?
    let remedy: String?
    let delegateClients: [String]?
}

struct TurnReport: Decodable, Sendable {
    let revision: Int64
    let models: [String]
    let turns: [AgentTurn]
    let clients: [String]
    let capabilities: [TurnCapability]
    let conversationTitles: [String: [String: String]]?

    init(revision: Int64, models: [String], turns: [AgentTurn], clients: [String] = [], capabilities: [TurnCapability] = [],
         conversationTitles: [String: [String: String]]? = nil) {
        self.revision = revision; self.models = models; self.turns = turns
        self.clients = clients; self.capabilities = capabilities
        self.conversationTitles = conversationTitles
    }
}

struct AgentTurn: Codable, Identifiable, Equatable, Sendable {
    let client: String
    let durationEstimated: Bool
    let id: String
    let sessionId: String
    let turnId: String
    let project: String
    let model: String
    let effort: String?
    let startMs: Int64
    let endMs: Int64
    let durationMs: Int64
    let ttftMs: Int64?
    let generatedTokens: Int64
    let reasoningTokens: Int64?
    let requests: Int64?
    let toolCalls: Int64?
    let toolWaitMs: Int64?
    let inferenceSpeed: InferenceSpeed?

    var start: Date { Date(timeIntervalSince1970: Double(startMs) / 1000) }
    var speed: Double { Double(generatedTokens) * 1000 / Double(durationMs) }
    var reasoningShare: Double? {
        guard let reasoningTokens, generatedTokens > 0 else { return nil }
        return Double(reasoningTokens) / Double(generatedTokens)
    }

    init(id: String, sessionId: String, turnId: String, project: String, model: String, effort: String?,
         startMs: Int64, endMs: Int64, durationMs: Int64, ttftMs: Int64?, generatedTokens: Int64,
         reasoningTokens: Int64?, requests: Int64?, toolCalls: Int64?, toolWaitMs: Int64?, client: String = "codex",
         durationEstimated: Bool = false, inferenceSpeed: InferenceSpeed? = nil) {
        self.client = client; self.durationEstimated = durationEstimated
        self.id = id; self.sessionId = sessionId; self.turnId = turnId; self.project = project; self.model = model
        self.effort = effort; self.startMs = startMs; self.endMs = endMs; self.durationMs = durationMs
        self.ttftMs = ttftMs; self.generatedTokens = generatedTokens; self.reasoningTokens = reasoningTokens
        self.requests = requests; self.toolCalls = toolCalls; self.toolWaitMs = toolWaitMs
        self.inferenceSpeed = inferenceSpeed
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        client = try c.decode(String.self, forKey: .client)
        durationEstimated = try c.decode(Bool.self, forKey: .durationEstimated)
        id = try c.decode(String.self, forKey: .id)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        turnId = try c.decode(String.self, forKey: .turnId)
        project = try c.decode(String.self, forKey: .project)
        model = try c.decode(String.self, forKey: .model)
        effort = try c.decodeIfPresent(String.self, forKey: .effort)
        startMs = try c.decode(Int64.self, forKey: .startMs)
        endMs = try c.decode(Int64.self, forKey: .endMs)
        durationMs = try c.decode(Int64.self, forKey: .durationMs)
        ttftMs = try c.decodeIfPresent(Int64.self, forKey: .ttftMs)
        generatedTokens = try c.decode(Int64.self, forKey: .generatedTokens)
        reasoningTokens = try c.decodeIfPresent(Int64.self, forKey: .reasoningTokens)
        requests = try c.decodeIfPresent(Int64.self, forKey: .requests)
        toolCalls = try c.decodeIfPresent(Int64.self, forKey: .toolCalls)
        toolWaitMs = try c.decodeIfPresent(Int64.self, forKey: .toolWaitMs)
        inferenceSpeed = try c.decodeIfPresent(InferenceSpeed.self, forKey: .inferenceSpeed)
        guard !client.isEmpty, !id.isEmpty, !sessionId.isEmpty, !turnId.isEmpty,
              startMs > 0, endMs >= startMs, durationMs > 0, generatedTokens >= 0,
              requests.map({ $0 >= 0 }) ?? true, toolCalls.map({ $0 >= 0 }) ?? true,
              reasoningTokens.map({ $0 >= 0 && $0 <= generatedTokens }) ?? true,
              ttftMs.map({ $0 >= 0 && $0 <= durationMs }) ?? true,
              toolWaitMs.map({ $0 >= 0 && $0 <= durationMs }) ?? true else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid completed-turn metrics"))
        }
    }
}

enum TurnSort: String, CaseIterable {
    case duration, newest, oldest, speed, reasoning
    var title: String { L("turns.sort." + rawValue) }
}

enum TurnSpeedGranularity: Sendable {
    case hour, day, week

    init(dayCount: Int?) {
        switch dayCount {
        case 1?: self = .hour
        case let days? where (2...7).contains(days): self = .day
        default: self = .week
        }
    }

    var component: Calendar.Component {
        switch self {
        case .hour: .hour
        case .day: .day
        case .week: .weekOfYear
        }
    }
}

struct TurnSpeedBucket: Sendable {
    struct Distribution: Sendable {
        let middle: ClosedRange<Double>
        let median: Double
        let whiskers: ClosedRange<Double>
        let outliers: [AgentTurn]
        let representative: AgentTurn
    }

    let interval: Range<Date>
    let turns: [AgentTurn]
    let distribution: Distribution?
    let containsEstimates: Bool

    var start: Date { interval.lowerBound }
    var end: Date { interval.upperBound }
    var center: Date { start + end.timeIntervalSince(start) / 2 }
    var visiblePoints: [AgentTurn] { distribution?.outliers ?? turns }

    init(interval: Range<Date>, turns: [AgentTurn]) {
        self.interval = interval
        self.turns = turns
        containsEstimates = turns.contains(where: \.durationEstimated)
        guard turns.count >= 3 else {
            distribution = nil
            return
        }
        let ordered = turns.sorted { ($0.speed, $0.startMs, $0.id) < ($1.speed, $1.startMs, $1.id) }
        let q1 = Self.percentile(0.25, in: ordered)
        let median = Self.percentile(0.5, in: ordered)
        let q3 = Self.percentile(0.75, in: ordered)
        let fence = (q3 - q1) * 1.5
        let regular = (q1 - fence)...(q3 + fence)
        let representative = turns.min {
            abs($0.speed - median) < abs($1.speed - median)
        } ?? turns[0]
        let low = ordered.first(where: { regular.contains($0.speed) }) ?? representative
        let high = ordered.last(where: { regular.contains($0.speed) }) ?? representative
        distribution = Distribution(middle: q1...q3, median: median,
                                    whiskers: low.speed...high.speed,
                                    outliers: ordered.filter { !regular.contains($0.speed) },
                                    representative: representative)
    }

    private static func percentile(_ fraction: Double, in ordered: [AgentTurn]) -> Double {
        let index = fraction * Double(ordered.count - 1)
        let lower = ordered[Int(index)].speed
        let upper = ordered[Int(index.rounded(.up))].speed
        return lower + (upper - lower) * (index - index.rounded(.down))
    }
}

struct TurnSpeedTimeline: Sendable {
    let calendar: Calendar
    let granularity: TurnSpeedGranularity
    let domain: ClosedRange<Date>?
    let buckets: [TurnSpeedBucket]
    let maxSpeed: Double
    private let bucketsByCalendarStart: [Date: TurnSpeedBucket]
    private let visiblePoints: [AgentTurn]

    fileprivate init(chronologicalPoints points: [AgentTurn], query: TurnQuery) {
        var calendar = Localization.reportingCalendar
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        self.calendar = calendar

        let from = query.from.flatMap(Localization.date)
        let to = query.to.flatMap(Localization.date)
        let dayCount = from.flatMap { start in to.flatMap { calendar.dateComponents([.day], from: start, to: $0).day } }
            .map { $0 + 1 }
        let granularity = TurnSpeedGranularity(dayCount: dayCount)
        self.granularity = granularity
        let component = granularity.component
        let start = from ?? points.first.flatMap { calendar.dateInterval(of: component, for: $0.start)?.start }
        let end = to.flatMap { calendar.date(byAdding: .day, value: 1, to: $0) }
            ?? points.last.flatMap { calendar.dateInterval(of: component, for: $0.start)?.end }
        guard let start, let end, start < end else {
            domain = nil; buckets = []; bucketsByCalendarStart = [:]; visiblePoints = []; maxSpeed = 0
            return
        }

        domain = start...end
        let included = points.filter { $0.start >= start && $0.start < end }
        let groups = Dictionary(grouping: included) { calendar.dateInterval(of: component, for: $0.start) }
        let mapped = groups.compactMap { interval, rows -> (Date, TurnSpeedBucket)? in
            guard let interval else { return nil }
            let clipped = max(start, interval.start)..<min(end, interval.end)
            return (interval.start, TurnSpeedBucket(interval: clipped, turns: rows))
        }
        let buckets = mapped.map(\.1).sorted { $0.start < $1.start }
        self.buckets = buckets
        bucketsByCalendarStart = Dictionary(uniqueKeysWithValues: mapped)
        visiblePoints = buckets.flatMap(\.visiblePoints).sorted { ($0.startMs, $0.id) < ($1.startMs, $1.id) }
        maxSpeed = included.lazy.map(\.speed).max() ?? 0
    }

    func bucket(at date: Date) -> TurnSpeedBucket? {
        guard let start = calendar.dateInterval(of: granularity.component, for: date)?.start,
              let bucket = bucketsByCalendarStart[start], bucket.interval.contains(date) else { return nil }
        return bucket
    }

    func points(in interval: Range<Date>) -> ArraySlice<AgentTurn> {
        visiblePoints[lowerBound(interval.lowerBound)..<lowerBound(interval.upperBound)]
    }

    private func lowerBound(_ date: Date) -> Int {
        var lower = 0, upper = visiblePoints.count
        while lower < upper {
            let mid = (lower + upper) / 2
            if visiblePoints[mid].start < date { lower = mid + 1 } else { upper = mid }
        }
        return lower
    }
}

struct TurnPresentation: Sendable {
    private let conversationTitles: [String: [String: String]]
    let revision: Int64
    let models: [String]
    let clients: [String]
    let capabilities: [TurnCapability]
    let containsEstimates: Bool
    let points: [AgentTurn]
    let speedTimeline: TurnSpeedTimeline?
    let averageSpeed: Double?
    let averageTTFTSeconds: Double?
    let averageReasoning: Double?
    let reasoningShare: Double?
    let reasoningCoverage: Int
    let ttftCoverage: Int

    init(report: TurnReport, query: TurnQuery? = nil) {
        conversationTitles = report.conversationTitles ?? [:]
        clients = report.clients
        capabilities = report.capabilities
        containsEstimates = report.turns.contains { $0.durationEstimated }
        revision = report.revision
        models = report.models
        let points = report.turns.sorted { ($0.startMs, $0.id) < ($1.startMs, $1.id) }
        self.points = points
        speedTimeline = query.map { TurnSpeedTimeline(chronologicalPoints: points, query: $0) }
        let seconds = points.reduce(0.0) { $0 + Double($1.durationMs) / 1000 }
        let generated = points.reduce(0.0) { $0 + Double($1.generatedTokens) }
        averageSpeed = seconds > 0 ? generated / seconds : nil
        let waits = points.compactMap(\.ttftMs)
        ttftCoverage = waits.count
        averageTTFTSeconds = waits.isEmpty ? nil : waits.reduce(0.0) { $0 + Double($1) / 1000 } / Double(waits.count)
        let known = points.filter { $0.reasoningTokens != nil }
        reasoningCoverage = known.count
        let reasoning = known.reduce(0.0) { $0 + Double($1.reasoningTokens!) }
        let knownGenerated = known.reduce(0.0) { $0 + Double($1.generatedTokens) }
        averageReasoning = known.isEmpty ? nil : reasoning / Double(known.count)
        reasoningShare = knownGenerated > 0 ? reasoning / knownGenerated : nil
    }

    func title(for turn: AgentTurn) -> String? {
        conversationTitles[turn.client]?[turn.sessionId]
    }

    func matches(_ turn: AgentTurn, search: String) -> Bool {
        search.isEmpty || turn.project.localizedCaseInsensitiveContains(search)
            || matchingSubtitle(for: turn, search: search) != nil
    }

    func matchingSubtitle(for turn: AgentTurn, search: String) -> String? {
        guard !search.isEmpty else { return nil }
        if let title = title(for: turn), title.localizedCaseInsensitiveContains(search) { return title }
        if turn.turnId.localizedCaseInsensitiveContains(search) { return turn.turnId }
        return turn.id.localizedCaseInsensitiveContains(search) ? turn.id : nil
    }

    func sorted(by order: TurnSort, in bucket: TurnSpeedBucket? = nil, search: String = "") -> [AgentTurn] {
        let source = bucket?.turns ?? points
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let points = query.isEmpty ? source : source.filter { matches($0, search: query) }
        switch order {
        case .oldest: return points
        case .newest: return points.reversed()
        case .duration: return points.sorted { ($0.durationMs, $0.startMs, $0.id) > ($1.durationMs, $1.startMs, $1.id) }
        case .speed: return points.sorted { ($0.speed, $0.startMs, $0.id) < ($1.speed, $1.startMs, $1.id) }
        case .reasoning: return points.sorted { ($0.reasoningTokens ?? -1, $0.startMs, $0.id) > ($1.reasoningTokens ?? -1, $1.startMs, $1.id) }
        }
    }

    func nearest(to date: Date) -> AgentTurn? {
        // Binary lookup keeps pointer feedback independent of the history size.
        let target = date.timeIntervalSince1970 * 1000
        var lower = 0, upper = points.count
        while lower < upper {
            let mid = (lower + upper) / 2
            if Double(points[mid].startMs) < target { lower = mid + 1 } else { upper = mid }
        }
        guard !points.isEmpty else { return nil }
        if lower == 0 { return points[0] }
        if lower == points.count { return points[points.count - 1] }
        return target - Double(points[lower - 1].startMs) <= Double(points[lower].startMs) - target ? points[lower - 1] : points[lower]
    }
}

enum TurnFormat {
    static func number(_ value: Double?) -> String {
        value?.formatted(.number.precision(.fractionLength(1)).locale(Localization.locale)) ?? "—"
    }
    static func timestamp(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(locale: Localization.locale, calendar: Localization.reportingCalendar,
                                        timeZone: Localization.reportingCalendar.timeZone).month(.twoDigits).day(.twoDigits).hour().minute())
    }
    static func speedBucket(_ bucket: TurnSpeedBucket, granularity: TurnSpeedGranularity) -> String {
        let calendar = Localization.reportingCalendar
        if granularity == .hour {
            let clock = Date.FormatStyle(locale: Localization.locale, calendar: calendar, timeZone: calendar.timeZone).hour().minute()
            return "\(timestamp(bucket.start))–\(bucket.end.formatted(clock))"
        }

        let lastDay = bucket.end - 1
        let formatter = DateIntervalFormatter()
        formatter.locale = Localization.locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: bucket.start, to: calendar.startOfDay(for: lastDay))
    }
    static func clockDuration(_ milliseconds: Int64) -> String {
        let seconds = milliseconds / 1000
        return seconds >= 3600 ? String(format: "%lld:%02lld:%02lld", seconds / 3600, seconds / 60 % 60, seconds % 60) : String(format: "%lld:%02lld", seconds / 60, seconds % 60)
    }
    static func duration(_ milliseconds: Int64) -> String {
        let formatter = DateComponentsFormatter()
        formatter.calendar = Localization.reportingCalendar
        formatter.allowedUnits = milliseconds >= 3_600_000 ? [.hour, .minute] : milliseconds >= 60_000 ? [.minute, .second] : [.second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: Double(milliseconds) / 1000) ?? "—"
    }
}
