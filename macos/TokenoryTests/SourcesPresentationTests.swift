import XCTest
@testable import Tokenory

final class SourcesPresentationTests: XCTestCase {
    func testLocalToolsCombineCoverageAndKeepUnselectedSources() {
        let scan = [
            SourceStatus(client: "codex", status: "ok", files: 2, records: 4, errors: []),
            SourceStatus(client: "claude", status: "partial", files: 1, records: 2, errors: ["read error"]),
            SourceStatus(client: "gemini", status: "empty", files: 0, records: 0, errors: []),
            SourceStatus(client: "unavailable", status: "unavailable", files: 0, records: 0, errors: [])
        ]
        func coverage(_ client: String, _ source: String, _ selected: Int64) -> JSONValue {
            .object(["client": .string(client), "source": .string(source), "selectedTokens": .integer(selected)])
        }
        let groups = LocalSourceGroup.collect(scan: scan, coverage: [
            coverage("codex", "local", 70), coverage("codex", "tokens-ci", 30),
            coverage("claude", "cc-switch", 40), coverage("claude", "local", 0)
        ])

        XCTAssertEqual(groups.map(\.id), ["codex", "claude", "gemini"])
        XCTAssertEqual(groups[0].selectedTokens, 100)
        XCTAssertEqual(groups[0].coverage.count, 2)
        XCTAssertEqual(groups[1].coverage.count, 2)
        XCTAssertEqual(groups[1].scan?.errors, ["read error"])
        XCTAssertTrue(groups[2].coverage.isEmpty)
    }
}
