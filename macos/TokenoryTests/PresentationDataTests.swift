import AppKit
import XCTest
@testable import Tokenory

final class PresentationDataTests: XCTestCase {
    func testOdometerMovesHigherWheelsInTheCarryIntervalOnly() {
        let beforeCarry = OdometerPosition.between(from: 98, to: 102, progress: 0.125)
        let carry = OdometerPosition.between(from: 98, to: 102, progress: 0.375)
        let afterCarry = OdometerPosition.between(from: 98, to: 102, progress: 0.625)
        let places: [Int64] = [100, 10, 1]
        XCTAssertEqual(places.map { beforeCarry.digit(at: $0) }, [0, 9, 8.5])
        XCTAssertEqual(places.map { carry.digit(at: $0) }, [0.5, 9.5, 9.5])
        XCTAssertEqual(places.map { afterCarry.digit(at: $0) }, [1, 0, 0.5])

        let borrow = OdometerPosition.between(from: 102, to: 98, progress: 0.625)
        XCTAssertEqual(borrow, carry)
        XCTAssertEqual(places.map { borrow.wheel(at: $0, relativeTo: 102) }, [0.5, -0.5, -0.5])

        let largest = OdometerPosition.between(from: Int64.max - 5, to: Int64.max, progress: 0.5)
        XCTAssertEqual(largest.whole, Int64.max - 3)
        XCTAssertEqual(largest.fraction, 0.5)
        XCTAssertEqual(largest.digit(at: 1), 4.5)
    }

    func testDashboardCounterCarriesCentsAndBorrowsAcrossDigitWidths() throws {
        let cents = try XCTUnwrap(DashboardOdometer(from: "$9.99", to: "$10.00"))
        XCTAssertEqual(cents.startText, "$09.99")
        XCTAssertEqual(cents.targetText, "$10.00")
        XCTAssertEqual(cents.ticks, 1)
        let half = cents.position(at: 0.5)
        let places = cents.columns.compactMap { column -> Int64? in
            if case let .wheel(place) = column { return place }
            return nil
        }
        XCTAssertEqual(places.map { half.digit(at: $0) }, [0.5, 9.5, 9.5, 9.5])

        let reverse = try XCTUnwrap(DashboardOdometer(from: "100", to: "99"))
        XCTAssertEqual(reverse.startText, "100")
        XCTAssertEqual(reverse.targetText, "099")
        XCTAssertEqual(reverse.position(at: 0.5).wheel(at: 10, relativeTo: reverse.rollStart), -0.5)
        XCTAssertEqual(reverse.position(at: 1).whole, 99)
    }

    func testDashboardCounterBoundsLargeChangesAndRequiresMatchingUnits() throws {
        let large = try XCTUnwrap(DashboardOdometer(from: "980.30万", to: "12.99万"))
        XCTAssertEqual(large.start, 98_030)
        XCTAssertEqual(large.target, 1_299)
        XCTAssertEqual(large.rollStart, 1_307)
        XCTAssertEqual(large.position(at: 1).whole, large.target)
        XCTAssertNil(DashboardOdometer(from: "9,999.99万", to: "1亿"))
    }

    func testChartOnlyGrowsOnMountWhenReturningFromEmptyAcrossRanges() {
        let populated = DashboardPlotPresence(range: DashboardDateSpan(from: "2026-11-18", to: "2026-11-18"),
                                              hasData: true)
        let empty = DashboardPlotPresence(range: DashboardDateSpan(from: "2026-11-17", to: "2026-11-17"),
                                          hasData: false)
        let transition = DashboardPlotTransition()
        XCTAssertFalse(transition.takeEntrance(populated))
        transition.commit(empty)
        transition.commit(populated)
        XCTAssertTrue(transition.takeEntrance(populated), "A renderer mounted after commit still gets the entrance.")
        XCTAssertFalse(transition.takeEntrance(populated), "Remounting the same range does not replay it.")

        let emptySameRange = DashboardPlotPresence(range: populated.range, hasData: false)
        transition.commit(emptySameRange)
        XCTAssertFalse(transition.takeEntrance(populated))

        transition.commit(empty)
        XCTAssertTrue(transition.takeEntrance(populated), "A renderer mounted before commit also gets the entrance.")
        transition.commit(populated)
        XCTAssertFalse(transition.takeEntrance(populated))
    }

    @MainActor
    func testChartRendererGrowsFromBaselineAndRevealsLineAfterEmptyRange() throws {
        let range = DashboardDateSpan(from: "2026-11-18", to: "2026-11-18")
        let emptyRange = DashboardDateSpan(from: "2026-11-17", to: "2026-11-17")
        let transition = DashboardPlotTransition()
        transition.commit(.init(range: emptyRange, hasData: false))
        let marks = DashboardChartMarks(
            bars: [.init(frame: CGRect(x: 20, y: 40, width: 12, height: 60), emphasized: true)],
            series: [[CGPoint(x: 20, y: 40), CGPoint(x: 50, y: 10)]], dots: [],
            frameSize: CGSize(width: 100, height: 100), range: range, animateRangeChanges: true,
            takeEntrance: { transition.takeEntrance(.init(range: range, hasData: true)) },
            barColor: .systemBlue, lineColor: .systemOrange
        )
        let chart = DashboardChartMarks.PlotView()
        chart.update(marks)
        let layers = try XCTUnwrap(chart.layer?.sublayers)
        let bar = try XCTUnwrap(layers.first?.sublayers?.first)
        let growth = try XCTUnwrap(bar.animation(forKey: "range") as? CABasicAnimation)
        XCTAssertEqual(growth.keyPath, "bounds.size.height")
        XCTAssertEqual(growth.fromValue as? Double, 0)
        XCTAssertEqual(growth.toValue as? Double, 60)
        XCTAssertEqual(bar.position, CGPoint(x: 20, y: 0))
        XCTAssertNotNil(layers.last?.mask?.animation(forKey: "range"))

        let remounted = DashboardChartMarks.PlotView()
        remounted.update(marks)
        XCTAssertNil(remounted.layer?.sublayers?.first?.sublayers?.first?.animation(forKey: "range"))
        XCTAssertNil(remounted.layer?.sublayers?.last?.mask)
    }

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
