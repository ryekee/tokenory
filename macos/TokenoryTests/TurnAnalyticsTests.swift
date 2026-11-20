// [INPUT]: Typed turn fixtures and IPC-shaped JSON.
// [OUTPUT]: Verifies summary definitions, missing values and calendar-based speed distributions.
// [POS]: Native turn analytics contract; no synthetic observations in gaps.
// [PROTOCOL]: Update this header on change, then check AGENTS.md
import XCTest
@testable import Tokenory

final class TurnAnalyticsTests: XCTestCase {
    private func turn(_ id: String, start: Int64, duration: Int64, tokens: Int64,
                      reasoning: Int64? = 20, ttft: Int64? = 1_000) -> AgentTurn {
        AgentTurn(id: id, sessionId: "session", turnId: id, project: "project", model: "model",
                  effort: "medium", startMs: start, endMs: start + duration, durationMs: duration,
                  ttftMs: ttft, generatedTokens: tokens, reasoningTokens: reasoning,
                  requests: 1, toolCalls: 0, toolWaitMs: 0)
    }
    func testFullRangeWeightedSpeedAndMissingMeasurements() {
        let rows = [turn("a", start: 1000, duration: 10000, tokens: 100, reasoning: 20, ttft: 1000),
                    turn("b", start: 20000, duration: 4000, tokens: 200, reasoning: 80, ttft: 3000),
                    turn("c", start: 50000, duration: 6000, tokens: 300, reasoning: nil, ttft: nil)]
        let data = TurnPresentation(report: TurnReport(revision: 1, models: ["model"], turns: rows))
        XCTAssertEqual(data.averageSpeed, 30)
        XCTAssertEqual(data.averageTTFTSeconds, 2)
        XCTAssertEqual(data.averageReasoning, 50)
        XCTAssertEqual(data.reasoningCoverage, 2)
        XCTAssertEqual(data.reasoningShare!, 100.0 / 300, accuracy: 0.0001)
    }
    func testChartKeepsOnlyObservedTurnsAndSortIsIndependent() {
        let rows = [turn("late", start: 100_000_000, duration: 3000, tokens: 100),
                    turn("early", start: 1000, duration: 1000, tokens: 40),
                    turn("middle", start: 1001, duration: 2000, tokens: 80)]
        let data = TurnPresentation(report: TurnReport(revision: 2, models: [], turns: rows))
        XCTAssertEqual(data.points.map(\.id), ["early", "middle", "late"])
        XCTAssertEqual(data.sorted(by: .newest).map(\.id), ["late", "middle", "early"])
        XCTAssertEqual(data.sorted(by: .oldest).map(\.id), ["early", "middle", "late"])
        XCTAssertEqual(data.sorted(by: .duration).map(\.id), ["late", "middle", "early"])
        XCTAssertEqual(data.nearest(to: Date(timeIntervalSince1970: 100_001))?.id, "late")
        XCTAssertEqual(data.points.count, 3)
    }
    func testEmptyAndZeroGenerationDoNotInventValues() {
        let empty = TurnPresentation(report: TurnReport(revision: 1, models: [], turns: []))
        XCTAssertNil(empty.averageSpeed); XCTAssertNil(empty.averageTTFTSeconds); XCTAssertNil(empty.averageReasoning)
        let data = TurnPresentation(report: TurnReport(revision: 1, models: [], turns: [
            turn("zero", start: 1, duration: 1000, tokens: 0, reasoning: 0, ttft: nil)]))
        XCTAssertEqual(data.averageSpeed, 0); XCTAssertEqual(data.averageReasoning, 0)
        XCTAssertNil(data.reasoningShare)
    }

    func testHourlySpeedGroupsKeepSparsePointsAndEmptyHours() throws {
        let start = try XCTUnwrap(Localization.date("2026-11-18"))
        let midnight = Int64(start.timeIntervalSince1970 * 1000)
        let rows = [
            turn("late", start: midnight + 7_200_000, duration: 1000, tokens: 9, reasoning: nil, ttft: nil),
            turn("first", start: midnight, duration: 1000, tokens: 0, reasoning: nil, ttft: nil),
            turn("last", start: midnight + 3_599_999, duration: 1000, tokens: 10, reasoning: nil, ttft: nil)
        ]
        let data = TurnPresentation(report: TurnReport(revision: 1, models: [], turns: rows),
                                    query: TurnQuery(from: "2026-11-18", to: "2026-11-18"))
        let timeline = try XCTUnwrap(data.speedTimeline)
        XCTAssertEqual(timeline.granularity, .hour)
        XCTAssertEqual(timeline.domain, start...start.addingTimeInterval(86_400))
        XCTAssertEqual(timeline.buckets.map(\.start), [start, start.addingTimeInterval(7200)])
        XCTAssertNil(timeline.bucket(at: start.addingTimeInterval(3600)))
        let first = try XCTUnwrap(timeline.bucket(at: start))
        XCTAssertNil(first.distribution)
        XCTAssertEqual(first.visiblePoints.map(\.id), ["first", "last"])
        XCTAssertEqual(first.visiblePoints.map(\.speed), [0, 10])
    }

    func testHourlyDistributionKeepsOutliersAndSelectsAnObservedTurnForTheMedian() throws {
        let rows = [0, 20, 22, 24, 25, 26, 28, 100].enumerated().map { index, speed in
            turn(String(index), start: Int64(1000 + index), duration: 1000, tokens: Int64(speed),
                 reasoning: nil, ttft: nil)
        }
        let data = TurnPresentation(report: TurnReport(revision: 1, models: [], turns: rows.reversed()),
                                    query: TurnQuery(from: "1970-01-01", to: "1970-01-01"))
        let hour = try XCTUnwrap(data.speedTimeline?.buckets.first)
        let stats = try XCTUnwrap(hour.distribution)
        XCTAssertEqual(stats.middle, 21.5...26.5)
        XCTAssertEqual(stats.median, 24.5)
        XCTAssertEqual(stats.whiskers, 20...28)
        XCTAssertEqual(hour.visiblePoints.map(\.speed), [0, 100])
        XCTAssertEqual(stats.representative.id, "3")
    }

    func testSevenSelectedDaysUseDailyBucketsEvenWhenOnlyTwoDaysHaveData() throws {
        let saturday = try XCTUnwrap(Localization.date("2026-11-14"))
        let monday = try XCTUnwrap(Localization.date("2026-11-16"))
        let tuesday = try XCTUnwrap(Localization.date("2026-11-17"))
        let end = try XCTUnwrap(Localization.date("2026-11-21"))
        let midnight = Int64(monday.timeIntervalSince1970 * 1000)
        let rows = [turn("first", start: midnight, duration: 1000, tokens: 20),
                    turn("median", start: midnight + 10_800_000, duration: 1000, tokens: 30),
                    turn("last", start: midnight + 86_399_999, duration: 1000, tokens: 40),
                    turn("next-day", start: midnight + 86_400_000, duration: 1000, tokens: 60)]
        let data = TurnPresentation(report: TurnReport(revision: 1, models: [], turns: rows),
                                    query: TurnQuery(from: "2026-11-14", to: "2026-11-20"))
        let timeline = try XCTUnwrap(data.speedTimeline)
        XCTAssertEqual(timeline.granularity, .day)
        XCTAssertEqual(timeline.domain, saturday...end)
        XCTAssertEqual(timeline.buckets.map(\.start), [monday, tuesday])
        XCTAssertNil(timeline.bucket(at: saturday))
        let bucket = try XCTUnwrap(timeline.bucket(at: monday))
        XCTAssertEqual(bucket.end, tuesday)
        XCTAssertEqual(bucket.turns.map(\.id), ["first", "median", "last"])
        XCTAssertEqual(data.sorted(by: .newest, in: bucket).map(\.id), ["last", "median", "first"])
        XCTAssertEqual(bucket.distribution?.representative.id, "median")
        XCTAssertEqual(timeline.bucket(at: tuesday)?.visiblePoints.map(\.id), ["next-day"])
        XCTAssertEqual(timeline.points(in: monday..<end).map(\.id), ["next-day"])
    }

    func testLongAndUnboundedRangesUseBeijingMondayWeeks() throws {
        let firstMonday = try XCTUnwrap(Localization.date("2026-11-09"))
        let sunday = try XCTUnwrap(Localization.date("2026-11-15"))
        let monday = try XCTUnwrap(Localization.date("2026-11-16"))
        let lastMonday = try XCTUnwrap(Localization.date("2026-12-07"))
        let lastDay = try XCTUnwrap(Localization.date("2026-12-12"))
        let lastEnd = try XCTUnwrap(Localization.date("2026-12-13"))
        let rows = [turn("sunday", start: Int64(monday.timeIntervalSince1970 * 1000) - 1, duration: 1000, tokens: 20),
                    turn("monday", start: Int64(monday.timeIntervalSince1970 * 1000), duration: 1000, tokens: 30),
                    turn("last", start: Int64(lastDay.timeIntervalSince1970 * 1000), duration: 1000, tokens: 40)]
        let report = TurnReport(revision: 1, models: [], turns: rows)
        let month = try XCTUnwrap(TurnPresentation(report: report, query: TurnQuery(from: "2026-11-15", to: "2026-12-14")).speedTimeline)
        let custom = try XCTUnwrap(TurnPresentation(report: report, query: TurnQuery(from: "2026-11-15", to: "2026-12-12")).speedTimeline)
        let all = try XCTUnwrap(TurnPresentation(report: report, query: TurnQuery(from: nil, to: nil)).speedTimeline)
        let eightDays = try XCTUnwrap(TurnPresentation(report: report, query: TurnQuery(from: "2026-11-15", to: "2026-11-22")).speedTimeline)
        XCTAssertEqual([month.granularity, custom.granularity, all.granularity, eightDays.granularity], [.week, .week, .week, .week])
        XCTAssertEqual(custom.domain, sunday...lastEnd)
        XCTAssertEqual(custom.buckets.map(\.start), [sunday, monday, lastMonday])
        XCTAssertEqual(custom.bucket(at: sunday)?.end, monday)
        XCTAssertEqual(custom.bucket(at: monday)?.turns.map(\.id), ["monday"])
        XCTAssertEqual(custom.bucket(at: lastDay)?.end, lastEnd)
        XCTAssertNil(custom.bucket(at: lastEnd))
        XCTAssertEqual(all.buckets.map(\.start), [firstMonday, monday, lastMonday])
    }
    func testMixedAgentsPreserveEstimateAndUnknownMetrics() throws {
        let estimated = AgentTurn(id: "claude-1", sessionId: "s", turnId: "t", project: "p", model: "m",
                                  effort: nil, startMs: 1000, endMs: 11000, durationMs: 10000,
                                  ttftMs: nil, generatedTokens: 100, reasoningTokens: nil,
                                  requests: 1, toolCalls: 0, toolWaitMs: nil, client: "claude", durationEstimated: true)
        let decoded = try JSONDecoder().decode(AgentTurn.self, from: JSONEncoder().encode(estimated))
        XCTAssertEqual(decoded.client, "claude")
        XCTAssertTrue(decoded.durationEstimated)
        let data = TurnPresentation(report: TurnReport(revision: 1, models: ["m"], turns: [decoded]))
        XCTAssertTrue(data.containsEstimates)
        XCTAssertEqual(data.averageSpeed, 10)
        XCTAssertNil(data.averageTTFTSeconds)
        XCTAssertNil(data.averageReasoning)
        XCTAssertEqual(data.ttftCoverage, 0)
    }

    func testDecodingRejectsInvalidTimingAndTokenContracts() throws {
        let row = turn("valid", start: 1000, duration: 10000, tokens: 100)
        let encoded = try JSONEncoder().encode(row)
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for (key, invalid) in [("durationMs", 0), ("reasoningTokens", 101), ("ttftMs", -1), ("toolWaitMs", 10001)] {
            var changed = value; changed[key] = invalid
            XCTAssertThrowsError(try JSONDecoder().decode(AgentTurn.self, from: JSONSerialization.data(withJSONObject: changed)), key)
        }
        value["ttftMs"] = NSNull(); value["reasoningTokens"] = NSNull(); value["requests"] = NSNull(); value["toolCalls"] = NSNull()
        let decoded = try JSONDecoder().decode(AgentTurn.self, from: JSONSerialization.data(withJSONObject: value))
        XCTAssertNil(decoded.ttftMs); XCTAssertNil(decoded.reasoningTokens); XCTAssertNil(decoded.requests); XCTAssertNil(decoded.toolCalls)
    }

    func testFastModeRequiresExplicitWireEvidence() throws {
        let original = turn("turn", start: 1000, duration: 10000, tokens: 100)
        let encoded = try JSONEncoder().encode(original)
        let decoder = JSONDecoder()
        XCTAssertNil(try decoder.decode(AgentTurn.self, from: encoded).inferenceSpeed)
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        for (speed, source, expected) in [
            ("fast", "selected", true), ("fast", "reported", true), ("fast", "inferred", false),
            ("standard", "reported", false), ("ultrafast", "selected", false)
        ] {
            value["inferenceSpeed"] = ["speed": speed, "source": source]
            let decoded = try decoder.decode(AgentTurn.self, from: JSONSerialization.data(withJSONObject: value))
            XCTAssertEqual(decoded.inferenceSpeed?.isFast, expected)
        }
    }
}
