// [INPUT]: Versioned aggregate snapshots for two devices.
// [OUTPUT]: Checks replacement, additive totals, scoped model and subagent totals, and unique day/model counts.
// [POS]: Snapshot wire format and shared Overview calculations.
// [PROTOCOL]: Update this header on change, then check AGENTS.md
import XCTest
@testable import Tokenory

final class DeviceUsageSnapshotTests: XCTestCase {
    private let firstDay = "2026-11-21"
    private let secondDay = "2026-11-22"

    private func bucket(_ date: String, hour: Int?, tokens: Int64, cost: Double?,
                        client: String = "codex", child: Bool = false) -> DeviceUsageSnapshot.Bucket {
        let breakdown = TokenBreakdown(input: tokens - 1, output: 1, cacheRead: 0, cacheWrite: 0, reasoning: 0)
        let summary = UsageSummary(tokens: tokens, tokenBreakdown: breakdown, knownEstimatedCostUsd: cost,
                                   unpricedTokens: cost == nil ? tokens : 0, costStatus: cost == nil ? "unknown" : "complete",
                                   recordCount: 1, activeDays: 1, partialDays: 1, requests: nil,
                                   fastTokens: child ? tokens : nil, fastEstimatedCostUsd: child ? cost : nil)
        return .init(date: date, hour: hour, client: client, provider: "provider", model: "model",
                     source: hour == nil ? "tokens-ci" : "local", isSubagent: child, summary: summary)
    }

    private func snapshot(_ rows: [DeviceUsageSnapshot.Bucket], starts: [DeviceUsageSnapshot.StartCount] = []) -> DeviceUsageSnapshot {
        DeviceUsageSnapshot(schemaVersion: 1, revision: 4, timezone: "Asia/Shanghai", buckets: rows, subagentStarts: starts)
    }

    func testDeviceReplacementAndSharedModelDayKeepFullTokenTotals() throws {
        let first = snapshot([bucket(firstDay, hour: 11, tokens: 30, cost: 0.3, child: true)])
        let second = snapshot([bucket(firstDay, hour: nil, tokens: 20, cost: nil, client: "other")])
        var devices = ["a": first, "b": second]
        devices["a"] = try JSONDecoder().decode(DeviceUsageSnapshot.self, from: JSONEncoder().encode(first))
        let report = DeviceUsageSnapshot.overview(devices: devices, filter: .init(from: firstDay, to: firstDay))
        XCTAssertEqual(report.summary.tokens, 50)
        XCTAssertEqual(report.summary.tokenBreakdown.input, 48)
        XCTAssertEqual(report.summary.knownEstimatedCostUsd, 0.3)
        XCTAssertEqual(report.summary.unpricedTokens, 20)
        XCTAssertEqual(report.summary.costStatus, "partial")
        XCTAssertEqual(report.summary.fastTokens, 30)
        XCTAssertEqual(report.codexSubagents?.tokens, 30)
        XCTAssertEqual(report.summary.activeDays, 1)
        XCTAssertEqual(report.summary.partialDays, 1)
        XCTAssertEqual(report.models.map(\.key), ["model"])
        XCTAssertEqual(report.models.first?.summary.tokens, 50)
        XCTAssertEqual(report.clients.map(\.key), ["codex", "other"])
        XCTAssertEqual(report.hourly?.buckets.first?.key, firstDay + "T11:00:00+08:00")
        XCTAssertEqual(report.hourly?.unallocated.tokens, 20)
        XCTAssertEqual(report.details.count, 0)
        devices["a"] = snapshot([bucket(firstDay, hour: 11, tokens: 42, cost: 0)])
        XCTAssertEqual(DeviceUsageSnapshot.overview(devices: devices, filter: .init()).summary.tokens, 62)
    }

    func testScopedSubagentStartsAndAnnualActivityKeepSeparateDateRanges() {
        let starts: [DeviceUsageSnapshot.StartCount] = [
            .init(date: firstDay, provider: nil, model: nil, nearestBefore: firstDay, nearestAfter: firstDay, count: 1),
            .init(date: firstDay, provider: nil, model: "model", nearestBefore: nil, nearestAfter: secondDay, count: 1)
        ]
        let devices = ["a": snapshot([bucket(secondDay, hour: 10, tokens: 80, cost: nil, child: true)], starts: starts)]
        let full = DeviceUsageSnapshot.overview(devices: devices, filter: .init(from: firstDay, to: secondDay, model: "model"))
        XCTAssertEqual(full.codexSubagents?.starts, 1)
        XCTAssertEqual(full.codexSubagents?.tokens, 80)
        XCTAssertNil(full.codexSubagents?.cost?.knownEstimatedCostUsd)
        XCTAssertEqual(full.codexSubagents?.cost?.unpricedTokens, 80)
        let filter = UsageFilter(from: firstDay, to: firstDay, model: "model")
        XCTAssertNil(DeviceUsageSnapshot.overview(devices: devices, filter: filter).codexSubagents)
        let activity = DeviceUsageSnapshot.activity(devices: devices, filter: filter, from: firstDay, to: secondDay)
        XCTAssertEqual(activity.daily.first?.summary.tokens, 80)
        XCTAssertEqual(activity.modelDays.first?.date, secondDay)
        XCTAssertEqual(activity.hourly?.buckets.first?.key, "10")
        XCTAssertEqual(DeviceUsageSnapshot.overview(devices: devices, filter: .init(source: "tokens-ci")).summary.tokens, 0)
    }

    func testModelsByToolUseFilteredBucketsAcrossDevices() throws {
        let first = snapshot([
            bucket(firstDay, hour: 11, tokens: 30, cost: 0.3, child: true),
            bucket(secondDay, hour: 8, tokens: 300, cost: 3.0)
        ])
        let second = snapshot([
            bucket(firstDay, hour: nil, tokens: 20, cost: nil),
            bucket(firstDay, hour: 13, tokens: 15, cost: 0.0, client: "other")
        ])
        let devices = ["a": first, "b": second]
        let report = DeviceUsageSnapshot.overview(devices: devices, filter: .init(from: firstDay, to: firstDay))
        let model = try XCTUnwrap(report.clientModels?["codex"]?.first)
        XCTAssertEqual(model.key, "model")
        XCTAssertEqual(model.summary.tokens, 50)
        XCTAssertEqual(model.summary.activeDays, 1)
        XCTAssertEqual(model.summary.costStatus, "partial")
        XCTAssertEqual(model.summary.knownEstimatedCostUsd, 0.3)
        XCTAssertEqual(model.summary.unpricedTokens, 20)
        XCTAssertEqual(model.summary.fastTokens, 30)
        XCTAssertEqual(model.summary.fastEstimatedCostUsd, 0.3)
        XCTAssertEqual(report.clientModels?["other"]?.first?.summary.tokens, 15)
        let imported = DeviceUsageSnapshot.overview(devices: devices, filter: .init(source: "tokens-ci"))
        XCTAssertEqual(imported.clientModels?["codex"]?.first?.summary.tokens, 20)
        XCTAssertNil(imported.clientModels?["other"])
    }

    func testFutureSnapshotSchemaIsRejected() {
        let future = Data(#"{"schemaVersion":2,"revision":0,"timezone":"UTC","buckets":[],"subagentStarts":[]}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(DeviceUsageSnapshot.self, from: future))
    }

    func testRemoteAntigravitySubagentsKeepTheirToolAndFilterScope() throws {
        let local = snapshot([
            bucket(firstDay, hour: 11, tokens: 80, cost: 0.2, client: "antigravity-cli")
        ])
        // Build the additive v1 fields on the wire. The local Mac still has a legacy snapshot.
        let remoteBase = snapshot([
            bucket(secondDay, hour: 9, tokens: 50, cost: nil, client: "antigravity"),
            bucket(secondDay, hour: 10, tokens: 10, cost: 0.1, client: "antigravity")
        ])
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(remoteBase)) as? [String: Any])
        var buckets = try XCTUnwrap(payload["buckets"] as? [[String: Any]])
        buckets[0]["isAntigravitySubagent"] = true
        payload["buckets"] = buckets
        payload["antigravitySubagentStarts"] = [
            ["client": "antigravity", "date": firstDay, "nearestBefore": firstDay, "nearestAfter": firstDay, "count": 1],
            ["client": "antigravity", "date": firstDay, "model": "model", "nearestAfter": secondDay, "count": 1]
        ]
        let remote = try JSONDecoder().decode(DeviceUsageSnapshot.self, from: JSONSerialization.data(withJSONObject: payload))
        let republished = try JSONDecoder().decode(DeviceUsageSnapshot.self, from: JSONEncoder().encode(remote))
        let devices = ["local": local, "remote": republished]

        let aggregate = DeviceUsageSnapshot.overview(devices: devices, filter: .init())
        XCTAssertEqual(aggregate.summary.tokens, 140)
        XCTAssertEqual(aggregate.antigravitySubagents?.tokens, 50)
        XCTAssertEqual(aggregate.antigravitySubagents?.starts, 1)
        XCTAssertEqual(aggregate.antigravitySubagents?.cost?.unpricedTokens, 50)
        XCTAssertEqual(aggregate.antigravitySubagents?.conversations.count, 0)
        XCTAssertNil(aggregate.codexSubagents)
        XCTAssertEqual(aggregate.subagents(forTool: "antigravity")?.tokens, 50)
        XCTAssertNil(aggregate.subagents(forTool: "antigravity-cli"))
        let cli = DeviceUsageSnapshot.overview(devices: devices, filter: .init(client: "antigravity-cli"))
        XCTAssertEqual(cli.summary.tokens, 80)
        XCTAssertNil(cli.antigravitySubagents)
        let firstDayOnly = DeviceUsageSnapshot.overview(devices: devices, filter: .init(from: firstDay, to: firstDay, model: "model"))
        XCTAssertNil(firstDayOnly.antigravitySubagents)
        let bothDays = DeviceUsageSnapshot.overview(devices: devices, filter: .init(from: firstDay, to: secondDay, model: "model"))
        XCTAssertEqual(bothDays.antigravitySubagents?.starts, 1)
        XCTAssertEqual(bothDays.antigravitySubagents?.tokens, 50)
    }

    func testAntigravityRankingUsesOnlyTheMatchingToolReport() throws {
        let empty = DeviceUsageSnapshot.overview(devices: ["mac": snapshot([])], filter: .init())
        let payload: [String: Any] = [
            "revision": 4, "summary": try JSONSerialization.jsonObject(with: JSONEncoder().encode(empty.summary)),
            "daily": [], "clients": [], "providers": [], "models": [], "details": [],
            "antigravitySubagents": ["starts": 1, "tokens": 60, "conversations": []],
            "antigravitySubagentsByClient": ["antigravity": ["starts": 1, "tokens": 60, "conversations": []]]
        ]
        let report = try JSONDecoder().decode(UsageReport.self, from: JSONSerialization.data(withJSONObject: payload))
        XCTAssertEqual(report.subagents(forTool: "antigravity")?.starts, 1)
        XCTAssertEqual(report.subagents(forTool: "antigravity")?.tokens, 60)
        XCTAssertNil(report.subagents(forTool: "antigravity-cli"))
    }
}
