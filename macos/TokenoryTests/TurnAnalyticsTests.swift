// [INPUT]: Typed turn fixtures and IPC-shaped JSON.
// [OUTPUT]: Verifies summary definitions, missing values and chronological selection.
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
}
