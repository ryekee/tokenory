import XCTest
@testable import Tokenory

final class PresentationDataTests: XCTestCase {
    private func summary(_ tokens: Int64, cost: Double?) -> UsageSummary {
        UsageSummary(tokens: tokens, tokenBreakdown: TokenBreakdown(input: tokens, output: 0, cacheRead: 0, cacheWrite: 0, reasoning: 0),
                     knownEstimatedCostUsd: cost, unpricedTokens: cost == nil ? tokens : 0,
                     costStatus: cost == nil ? "unknown" : "complete", recordCount: 1, activeDays: 1, partialDays: 0, requests: 1)
    }
    func testHourlyPlotPreservesUnknownCostsAndFutureHours() {
        let hours = HourlyUsage(buckets: [
            UsageGroup(key: "2026-11-06T00:00:00+08:00", summary: summary(100, cost: nil)),
            UsageGroup(key: "2026-11-06T01:00:00+08:00", summary: summary(200, cost: 0.5))
        ], unallocated: summary(20, cost: nil))
        let report = UsageReport(revision: 1, summary: summary(320, cost: 0.5), daily: [], clients: [], providers: [], models: [], details: [], hourly: hours)
        let now = ISO8601DateFormatter().date(from: "2026-11-05T18:20:00Z")!
        let trend = UsageTrend(report: report, filter: UsageFilter(from: "2026-11-06", to: "2026-11-06"), now: now)
        XCTAssertTrue(trend.hourly)
        XCTAssertEqual(trend.points.count, 24)
        XCTAssertEqual(trend.unallocatedTokens, 20)
        XCTAssertEqual(trend.domain.lowerBound, Localization.date("2026-11-06"))
        XCTAssertEqual(trend.domain.upperBound, Localization.date("2026-11-07"))
        XCTAssertNil(trend.points[0].cost)
        XCTAssertEqual(trend.points[0].tokens, 100)
        XCTAssertEqual(trend.points[1].cost, 0.5)
        XCTAssertEqual(trend.points[2].tokens, 0)
        XCTAssertEqual(trend.points[2].cost, 0)
        XCTAssertNil(trend.points[3].tokens)
        XCTAssertNil(trend.points[3].cost)
        XCTAssertTrue(trend.points[23].isFuture)
        XCTAssertGreaterThanOrEqual(trend.tokenMaximum, 200)
        XCTAssertGreaterThanOrEqual(trend.costMaximum, 0.5)
    }
    func testCostLinesBreakAtUnknownPricesAndMissingDates() {
        let days = [
            UsageGroup(key: "2026-11-01", summary: summary(10, cost: 1)),
            UsageGroup(key: "2026-11-02", summary: summary(20, cost: nil)),
            UsageGroup(key: "2026-11-03", summary: summary(30, cost: 2)),
            UsageGroup(key: "2026-11-05", summary: summary(40, cost: 3))
        ]
        let report = UsageReport(revision: 1, summary: summary(100, cost: 6), daily: days, clients: [], providers: [], models: [], details: [], hourly: nil)
        let trend = UsageTrend(report: report, filter: UsageFilter(), now: Localization.date("2026-11-06")!)
        XCTAssertFalse(trend.hourly)
        XCTAssertNil(trend.points[1].cost)
        XCTAssertNotEqual(trend.points[0].costSegment, trend.points[2].costSegment)
        XCTAssertNotEqual(trend.points[2].costSegment, trend.points[3].costSegment)
    }
    func testPriceGroupingIncludesProviderTiersAndSchedules() {
        let base: [String: Double?] = ["input_cost_per_token": 0.000001, "output_cost_per_token": 0.000005]
        let entries = [
            PriceCatalogEntry(provider: "openai", model: "model-a", rates: base, schedule: nil, allowFast: false, explicitFree: false),
            PriceCatalogEntry(provider: "openai", model: "model-alias", rates: base, schedule: nil, allowFast: false, explicitFree: false),
            PriceCatalogEntry(provider: "anthropic", model: "model-b", rates: base, schedule: nil, allowFast: false, explicitFree: false),
            PriceCatalogEntry(provider: "openai", model: "model-tiered", rates: base.merging(["input_cost_per_token_above_272k_tokens": 0.000002]) { _, new in new }, schedule: nil, allowFast: false, explicitFree: false),
            PriceCatalogEntry(provider: "openai", model: "model-scheduled", rates: base, schedule: "special", allowFast: false, explicitFree: false)
        ]
        let providers = PriceProviderGroup.make(entries)
        XCTAssertEqual(providers.count, 2)
        let openai = providers.first { $0.id == "openai" }!
        XCTAssertEqual(openai.groups.count, 3)
        XCTAssertEqual(openai.groups.first { $0.entries.count == 2 }?.entries.map(\.model), ["model-a", "model-alias"])
        XCTAssertEqual(providers.first { $0.id == "anthropic" }?.groups.count, 1)
    }
}
