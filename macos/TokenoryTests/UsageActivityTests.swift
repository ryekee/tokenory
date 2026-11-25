// [INPUT]: Daily aggregates with gaps, free and unknown costs.
// [OUTPUT]: Regression coverage for annual calendar, model history and rounded axis ticks.
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
    func testMonthLabelsFavorFullMonthsAtBothEdges() {
        let candidates = [
            ActivityMonthLabelLayout.Candidate(week: 0, title: "Nov", width: 16, partial: true),
            ActivityMonthLabelLayout.Candidate(week: 1, title: "Dec", width: 16, partial: false),
            ActivityMonthLabelLayout.Candidate(week: 5, title: "Jan", width: 14, partial: false),
            ActivityMonthLabelLayout.Candidate(week: 9, title: "Feb", width: 16, partial: false)
        ]
        let labels = ActivityMonthLabelLayout.resolve(candidates, weeks: 10, cell: 7)
        XCTAssertNil(labels[0])
        XCTAssertEqual(labels[1]?.title, "Dec")
        XCTAssertEqual(labels[5]?.title, "Jan")
        XCTAssertEqual(labels[9]?.title, "Feb")
        XCTAssertEqual(labels[9]?.offset, -9)
    }

    func testMonthLabelsPreservePartialMonthWhenThereIsRoom() {
        let candidates = [
            ActivityMonthLabelLayout.Candidate(week: 0, title: "11月", width: 14, partial: true),
            ActivityMonthLabelLayout.Candidate(week: 3, title: "12月", width: 14, partial: false),
            ActivityMonthLabelLayout.Candidate(week: 7, title: "1月", width: 10, partial: false)
        ]
        for cell: CGFloat in [7, 10, 15] {
            let labels = ActivityMonthLabelLayout.resolve(candidates, weeks: 8, cell: cell)
            XCTAssertEqual(labels[0]?.title, "11月")
            XCTAssertEqual(labels[3]?.title, "12月")
            XCTAssertEqual(labels[7]?.title, "1月")
        }
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
    func testActivityStreakAndAverageUseOnlyDaysWithTokens() {
        let activity = UsageActivity(report: report)
        XCTAssertEqual(activity.streak.current, 0)
        XCTAssertEqual(activity.streak.longest, 1)
        XCTAssertEqual(activity.averageActiveDayTokens, 45)
    }

    func testInsightsSeparateActiveDaysFromCalendarDaysAndRequireCompleteCosts() {
        let now = Localization.date("2026-11-04")!
        let filter = UsageFilter(from: "2026-11-01", to: "2026-11-30")
        let known = OverviewInsights(summary: summary(30, 3), filter: filter,
                                     calendar: Localization.reportingCalendar, now: now)
        XCTAssertEqual(known.activeDayTokens, 30)
        XCTAssertEqual(known.activeDayCost, 3)
        XCTAssertEqual(known.cachedInputShare, 0)
        XCTAssertEqual(known.periodDays, 4)
        XCTAssertEqual(known.monthlyPace, 22.5)
        XCTAssertEqual(known.costPerMillion, 100_000)

        let unknown = OverviewInsights(summary: summary(60, nil), filter: filter,
                                       calendar: Localization.reportingCalendar, now: now)
        XCTAssertEqual(unknown.activeDayTokens, 60)
        XCTAssertNil(unknown.activeDayCost)
        XCTAssertNil(unknown.monthlyPace)
        XCTAssertNil(unknown.costPerMillion)
        let singleDay = OverviewInsights(summary: summary(30, 3), filter: UsageFilter(from: "2026-11-04", to: "2026-11-04"),
                                         calendar: Localization.reportingCalendar, now: now)
        XCTAssertNil(singleDay.monthlyPace)
    }

    func testChartPinSurvivesHoverAndTogglesOffOnTheSameMark() {
        var inspection = ChartInspection<Int>()
        inspection.hovered = 2
        XCTAssertEqual(inspection.selection, 2)
        inspection.togglePin(2)
        inspection.hovered = 3
        XCTAssertEqual(inspection.selection, 2)
        inspection.togglePin(2)
        XCTAssertNil(inspection.selection)
        inspection.togglePin(3)
        inspection.clear()
        XCTAssertNil(inspection.selection)
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

    func testHistoryAxisKeepsRoundTicksUntilThePeakCrossesTheBand() {
        let chinese = Locale(identifier: "zh-Hans")
        let axis = HistoryAxisScale(paddedMaximum: 229_600_000, metric: .tokens, locale: chinese)
        XCTAssertEqual(axis.maximum, 250_000_000)
        XCTAssertEqual(axis.labels, ["2.5亿", "2亿", "1.5亿", "1亿", "0.5亿", "0"])
        XCTAssertEqual(HistoryAxisScale(paddedMaximum: 250_000_000, metric: .tokens, locale: chinese).labels, axis.labels)

        let next = HistoryAxisScale(paddedMaximum: 250_000_001, metric: .tokens, locale: chinese)
        XCTAssertEqual(next.maximum, 500_000_000)
        XCTAssertEqual(next.labels, ["5亿", "4亿", "3亿", "2亿", "1亿", "0"])

        let english = HistoryAxisScale(paddedMaximum: 229_600_000, metric: .tokens, locale: Locale(identifier: "en"))
        XCTAssertEqual(english.labels, ["250M", "200M", "150M", "100M", "50M", "0"])
    }

    func testHistoryAxisUsesReadableUnitsForSmallAndLargeValues() {
        let english = Locale(identifier: "en")
        let empty = HistoryAxisScale(paddedMaximum: 0, metric: .tokens, locale: english)
        XCTAssertEqual(empty.labels, ["5", "4", "3", "2", "1", "0"])

        let cost = HistoryAxisScale(paddedMaximum: 2.31, metric: .cost, locale: english)
        XCTAssertEqual(cost.labels, ["$2.5", "$2", "$1.5", "$1", "$0.5", "$0"])
        let small = HistoryAxisScale(paddedMaximum: 0.09, metric: .cost, locale: english)
        XCTAssertEqual(small.maximum, 0.1, accuracy: 1e-12)
        XCTAssertEqual(small.labels, ["10¢", "8¢", "6¢", "4¢", "2¢", "0¢"])

        let large = HistoryAxisScale(paddedMaximum: 1_090_000, metric: .cost, locale: english)
        XCTAssertEqual(large.labels, ["$1,250K", "$1,000K", "$750K", "$500K", "$250K", "$0"])
    }
}
