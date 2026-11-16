// [INPUT]: Multi-agent completed main-turn analytics and support capabilities from the Rust worker.
// [OUTPUT]: Validated client identities, estimated durations, whole-range summaries and chronological chart points.
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

    init(revision: Int64, models: [String], turns: [AgentTurn], clients: [String] = [], capabilities: [TurnCapability] = []) {
        self.revision = revision; self.models = models; self.turns = turns
        self.clients = clients; self.capabilities = capabilities
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

    var start: Date { Date(timeIntervalSince1970: Double(startMs) / 1000) }
    var speed: Double { Double(generatedTokens) * 1000 / Double(durationMs) }
    var reasoningShare: Double? {
        guard let reasoningTokens, generatedTokens > 0 else { return nil }
        return Double(reasoningTokens) / Double(generatedTokens)
    }

    init(id: String, sessionId: String, turnId: String, project: String, model: String, effort: String?,
         startMs: Int64, endMs: Int64, durationMs: Int64, ttftMs: Int64?, generatedTokens: Int64,
         reasoningTokens: Int64?, requests: Int64?, toolCalls: Int64?, toolWaitMs: Int64?, client: String = "codex", durationEstimated: Bool = false) {
        self.client = client; self.durationEstimated = durationEstimated
        self.id = id; self.sessionId = sessionId; self.turnId = turnId; self.project = project; self.model = model
        self.effort = effort; self.startMs = startMs; self.endMs = endMs; self.durationMs = durationMs
        self.ttftMs = ttftMs; self.generatedTokens = generatedTokens; self.reasoningTokens = reasoningTokens
        self.requests = requests; self.toolCalls = toolCalls; self.toolWaitMs = toolWaitMs
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

struct TurnPresentation: Sendable {
    let revision: Int64
    let models: [String]
    let clients: [String]
    let capabilities: [TurnCapability]
    let containsEstimates: Bool
    let points: [AgentTurn]
    let averageSpeed: Double?
    let averageTTFTSeconds: Double?
    let averageReasoning: Double?
    let reasoningShare: Double?
    let reasoningCoverage: Int
    let ttftCoverage: Int

    init(report: TurnReport) {
        clients = report.clients
        capabilities = report.capabilities
        containsEstimates = report.turns.contains { $0.durationEstimated }
        revision = report.revision
        models = report.models
        points = report.turns.sorted { ($0.startMs, $0.id) < ($1.startMs, $1.id) }
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

    func sorted(by order: TurnSort) -> [AgentTurn] {
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
