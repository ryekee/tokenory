// [INPUT]: One versioned, aggregate-only worker snapshot per selected Mac.
// [OUTPUT]: Filtered Overview and activity reports for one Mac or their sum.
// [POS]: Shared device-snapshot wire format and presentation aggregation.
// [PROTOCOL]: Update this header on change, then check AGENTS.md
import Foundation

struct DeviceUsageSnapshot: Codable, Sendable {
    let schemaVersion: Int
    let revision: Int64
    let timezone: String
    let buckets: [Bucket]
    let subagentStarts: [StartCount]

    struct Bucket: Codable, Sendable {
        let date: String
        let hour: Int?
        let client: String
        let provider: String
        let model: String
        let source: String
        let isSubagent: Bool
        let summary: UsageSummary

        fileprivate func matches(_ filter: UsageFilter) -> Bool {
            filter.conversation == nil && filter.includesDay(date)
                && (filter.client == nil || client == filter.client)
                && (filter.provider == nil || provider == filter.provider)
                && (filter.model == nil || model == filter.model)
                && (filter.source == nil || source == filter.source)
        }
    }

    struct StartCount: Codable, Sendable {
        let date: String
        let provider: String?
        let model: String?
        let nearestBefore: String?
        let nearestAfter: String?
        let count: Int64

        fileprivate func matches(_ filter: UsageFilter) -> Bool {
            provider == filter.provider && model == filter.model && filter.includesDay(date)
                && (nearestBefore.map(filter.includesDay) == true || nearestAfter.map(filter.includesDay) == true)
        }
    }

    // Input uniqueness is structural: the caller replaces the snapshot at the same device ID.
    static func overview(devices: [String: Self], filter: UsageFilter) -> UsageReport {
        var result = DeviceOverviewAccumulator()
        var subagents = DeviceUsageAccumulator()
        var starts: Int64 = 0
        let includeSubagents = filter.conversation == nil && filter.timestampFromMs == nil
            && (filter.client == nil || filter.client == "codex")
            && (filter.source == nil || filter.source == "local")
        for id in devices.keys.sorted() {
            guard let snapshot = devices[id] else { continue }
            for bucket in snapshot.buckets where bucket.matches(filter) {
                result.add(bucket)
                if includeSubagents && bucket.isSubagent { subagents.add(bucket) }
            }
            if includeSubagents {
                for start in snapshot.subagentStarts where start.matches(filter) { starts += start.count }
            }
        }
        let costs = CodexSubagentCost(knownEstimatedCostUsd: subagents.cost, unpricedTokens: subagents.unpriced)
        let agents = CodexSubagentReport(starts: starts, tokens: subagents.tokens, conversations: [], cost: costs)
        return UsageReport(
            revision: combinedRevision(devices), summary: result.total.summary, daily: ordered(result.days),
            clients: ranked(result.clients), providers: ranked(result.providers), models: ranked(result.models),
            details: [], hourly: filter.from != nil && filter.from == filter.to ? result.hourly : nil,
            codexSubagents: agents.hasActivity ? agents : nil
        )
    }

    static func activity(devices: [String: Self], filter: UsageFilter, from: String, to: String) -> ActivityReport {
        var selected = filter
        selected.from = from
        selected.to = to
        var days: [String: DeviceUsageAccumulator] = [:]
        var models: [DeviceModelDay: DeviceUsageAccumulator] = [:]
        var hours: [String: DeviceUsageAccumulator] = [:]
        var unallocated = DeviceUsageAccumulator()
        for id in devices.keys.sorted() {
            guard let snapshot = devices[id] else { continue }
            for bucket in snapshot.buckets where bucket.matches(selected) {
                days[bucket.date, default: .init()].add(bucket)
                let key = DeviceModelDay(date: bucket.date, client: bucket.client, model: bucket.model)
                models[key, default: .init()].add(bucket)
                if let hour = bucket.hour {
                    hours[String(format: "%02d", hour), default: .init()].add(bucket)
                } else {
                    unallocated.add(bucket)
                }
            }
        }
        let modelDays = models.map { ModelDay(date: $0.key.date, client: $0.key.client, model: $0.key.model, summary: $0.value.summary) }
            .sorted { ($0.date, $0.client, $0.model) < ($1.date, $1.client, $1.model) }
        return ActivityReport(revision: combinedRevision(devices), from: from, to: to, daily: ordered(days),
                              modelDays: modelDays, hourly: HourlyUsage(buckets: ordered(hours), unallocated: unallocated.summary))
    }

    // A report revision for the current process. Cloud writes use a separate publication sequence.
    private static func combinedRevision(_ devices: [String: Self]) -> Int64 {
        var hasher = Hasher()
        for id in devices.keys.sorted() {
            hasher.combine(id)
            hasher.combine(devices[id]?.revision)
        }
        return Int64(hasher.finalize())
    }
}

extension DeviceUsageSnapshot {
    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try fields.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == 1 else {
            throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: fields, debugDescription: "Unsupported usage snapshot version")
        }
        revision = try fields.decode(Int64.self, forKey: .revision)
        timezone = try fields.decode(String.self, forKey: .timezone)
        buckets = try fields.decode([Bucket].self, forKey: .buckets)
        subagentStarts = try fields.decode([StartCount].self, forKey: .subagentStarts)
    }
}

private extension UsageFilter {
    func includesDay(_ date: String) -> Bool {
        (from.map { date >= $0 } ?? true) && (to.map { date <= $0 } ?? true)
    }
}

private struct DeviceModelDay: Hashable {
    let date: String
    let client: String
    let model: String
}

private func ordered(_ groups: [String: DeviceUsageAccumulator]) -> [UsageGroup] {
    groups.map { UsageGroup(key: $0.key, summary: $0.value.summary) }.sorted { $0.key < $1.key }
}

private func ranked(_ groups: [String: DeviceUsageAccumulator]) -> [UsageGroup] {
    groups.map { UsageGroup(key: $0.key, summary: $0.value.summary) }.sorted {
        $0.summary.tokens == $1.summary.tokens ? $0.key < $1.key : $0.summary.tokens > $1.summary.tokens
    }
}

private struct DeviceOverviewAccumulator {
    var total = DeviceUsageAccumulator()
    var days: [String: DeviceUsageAccumulator] = [:]
    var clients: [String: DeviceUsageAccumulator] = [:]
    var providers: [String: DeviceUsageAccumulator] = [:]
    var models: [String: DeviceUsageAccumulator] = [:]
    var hours: [String: DeviceUsageAccumulator] = [:]
    var unallocated = DeviceUsageAccumulator()
    var hourly: HourlyUsage { HourlyUsage(buckets: ordered(hours), unallocated: unallocated.summary) }

    mutating func add(_ bucket: DeviceUsageSnapshot.Bucket) {
        total.add(bucket)
        days[bucket.date, default: .init()].add(bucket)
        clients[bucket.client, default: .init()].add(bucket)
        providers[bucket.provider, default: .init()].add(bucket)
        models[bucket.model, default: .init()].add(bucket)
        if let hour = bucket.hour {
            let key = "\(bucket.date)T\(String(format: "%02d", hour)):00:00+08:00"
            hours[key, default: .init()].add(bucket)
        } else {
            unallocated.add(bucket)
        }
    }
}

private struct DeviceUsageAccumulator {
    var tokens: Int64 = 0
    var input: Int64 = 0
    var output: Int64 = 0
    var cacheRead: Int64 = 0
    var cacheWrite: Int64 = 0
    var reasoning: Int64 = 0
    var unpriced: Int64 = 0
    var records: Int64 = 0
    var cost: Double?
    var requests: Int64?
    var fastTokens: Int64?
    var fastCost: Double?
    var activeDates: Set<String> = []
    var partialDates: Set<String> = []

    mutating func add(_ bucket: DeviceUsageSnapshot.Bucket) {
        let value = bucket.summary
        tokens += value.tokens
        input += value.tokenBreakdown.input
        output += value.tokenBreakdown.output
        cacheRead += value.tokenBreakdown.cacheRead
        cacheWrite += value.tokenBreakdown.cacheWrite
        reasoning += value.tokenBreakdown.reasoning
        records += value.recordCount
        unpriced += value.unpricedTokens
        if let n = value.knownEstimatedCostUsd { cost = (cost ?? 0) + n }
        if let n = value.requests { requests = (requests ?? 0) + n }
        if let n = value.fastTokens { fastTokens = (fastTokens ?? 0) + n }
        if let n = value.fastEstimatedCostUsd { fastCost = (fastCost ?? 0) + n }
        if value.tokens > 0 { activeDates.insert(bucket.date) }
        if (value.partialDays ?? 0) > 0 { partialDates.insert(bucket.date) }
    }

    var summary: UsageSummary {
        let status: String
        if records == 0 { status = "empty" }
        else if cost == nil { status = "unknown" }
        else if unpriced > 0 { status = "partial" }
        else { status = "complete" }
        return UsageSummary(tokens: tokens, tokenBreakdown: TokenBreakdown(input: input, output: output,
                              cacheRead: cacheRead, cacheWrite: cacheWrite, reasoning: reasoning),
                            knownEstimatedCostUsd: cost, unpricedTokens: unpriced, costStatus: status,
                            recordCount: records, activeDays: Int64(activeDates.count), partialDays: Int64(partialDates.count),
                            requests: requests, fastTokens: fastTokens, fastEstimatedCostUsd: fastCost)
    }
}
