// [INPUT]: Daily aggregates with gaps, free and unknown costs.
// [OUTPUT]: Regression coverage for annual calendar and model history semantics.
// [POS]: Pure native presentation tests.
// [PROTOCOL]: Update this header on change, then check AGENTS.md
import XCTest
@testable import Tokenory

final class UsageActivityTests: XCTestCase {
    private func summary(_ tokens: Int64, _ cost: Double?) -> UsageSummary {
        UsageSummary(tokens: tokens, tokenBreakdown: TokenBreakdown(input: tokens, output: 0, cacheRead: 0, cacheWrite: 0, reasoning: 0), knownEstimatedCostUsd: cost,
                     unpricedTokens: cost == nil ? tokens : 0, costStatus: cost == nil ? "unknown" : "complete", recordCount: 1, activeDays: tokens > 0 ? 1 : 0, partialDays: 0, requests: nil)
    }
    private var report: ActivityReport {
        ActivityReport(revision: 2, from: "2026-11-01", to: "2026-11-04", daily: [
            UsageGroup(key: "2026-11-01", summary: summary(30, 3)),
            UsageGroup(key: "2026-11-03", summary: summary(60, nil))
        ], modelDays: [
            ModelDay(date: "2026-11-01", client: "codex", model: "same-model", summary: summary(30, 3)),
            ModelDay(date: "2026-11-03", client: "claude", model: "same-model", summary: summary(60, nil))
        ])
    }
    func testCalendarFillsMissingDaysAndUsesMondayRows() {
        let activity = UsageActivity(report: report)
        XCTAssertEqual(activity.days.count, 4)
        XCTAssertEqual(activity.leadingDays, 6)
        XCTAssertEqual(activity.days[1].tokens, 0)
        XCTAssertEqual(activity.days[1].cost, 0)
        XCTAssertNil(activity.days[2].cost)
        XCTAssertEqual(activity.activeDays, 2)
        XCTAssertEqual(activity.peak?.key, "2026-11-03")
        XCTAssertEqual(activity.topWeekday, 1)
    }
    func testHistoryKeepsClientIdentityAndRawTotalsAcrossAverageAndReverse() {
        let daily = UsageHistory(report: report, metric: .tokens, average: false)
        let average = UsageHistory(report: report, metric: .tokens, average: true)
        let reverse = UsageHistory(report: report, metric: .tokens, average: true, newestFirst: true)
        XCTAssertEqual(daily.series.count, 2)
        XCTAssertNotEqual(daily.series[0].id, daily.series[1].id)
        XCTAssertEqual(daily.total, 90)
        XCTAssertEqual(average.total, 90)
        XCTAssertEqual(reverse.total, 90)
        let codex = average.series.first { $0.client == "codex" }!
        XCTAssertEqual(codex.values, [30, 15, 10, 7.5])
        XCTAssertEqual(reverse.series.first { $0.client == "codex" }!.values, [7.5, 10, 15, 30])
        XCTAssertEqual(reverse.days.first?.key, "2026-11-04")
        XCTAssertEqual(UsageHistory(report: report, metric: .tokens, average: false, client: "claude").total, 60)
    }
    func testUnknownPricesDoNotBecomeFreeAndAverageRecoversAfterWindow() {
        let costs = UsageHistory(report: report, metric: .cost, average: true, client: "claude")
        XCTAssertNil(costs.total)
        XCTAssertEqual(costs.unpricedTokens, 60)
        XCTAssertNil(costs.series[0].values[2])
        XCTAssertNil(costs.series[0].values[3])
        let raw: [Double?] = [nil] + Array(repeating: 3, count: 30)
        let average = UsageHistory.trailingAverage(raw)
        XCTAssertNil(average[29])
        XCTAssertEqual(average[30], 3)
        XCTAssertEqual(UsageHistory.trailingAverage([0, 2, 4]), [0, 1, 2])
    }
    func testZeroTokenSyntheticRowsDoNotInterruptCostAverage() {
        let report = ActivityReport(revision: 1, from: "2026-11-01", to: "2026-11-04", daily: [], modelDays: [
            ModelDay(date: "2026-11-01", client: "codex", model: "priced", summary: summary(30, 3)),
            ModelDay(date: "2026-11-03", client: "micode", model: "<synthetic>", summary: summary(0, nil))
        ])
        let history = UsageHistory(report: report, metric: .cost, average: true)
        XCTAssertEqual(history.series.first { $0.model == "<synthetic>" }?.values, [0, 0, 0, 0])
        XCTAssertEqual(history.series.first { $0.model == "priced" }?.values, [3, 1.5, 1, 0.75])
        XCTAssertEqual(history.total, 3)
        XCTAssertEqual(history.unpricedTokens, 0)
    }

}
