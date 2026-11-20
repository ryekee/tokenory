import XCTest
@testable import Tokenory

final class LocalizationTests: XCTestCase {
    func testCatalogLookupFallbackAndPlurals() {
        XCTAssertEqual(Localization.string("nav.overview", language: "en"), "Overview")
        XCTAssertEqual(Localization.string("nav.overview", language: "zh-Hans"), "总览")
        XCTAssertEqual(Localization.string("nav.overview", language: "fr"), "Overview")
        XCTAssertEqual(Localization.format("usage.record_count", [Int64(1)], language: "en"), "1 record")
        XCTAssertEqual(Localization.format("usage.record_count", [Int64(2)], language: "en"), "2 records")
        XCTAssertEqual(Localization.format("usage.record_count", [Int64(2)], language: "zh-Hans"), "2 条记录")
        XCTAssertEqual(Localization.format("usage.unpriced", ["2.5M"], language: "en"), "Total includes 2.5M unpriced tokens")
    }

    func testCompactRecordsDateUsesSimplifiedChineseShortFormat() {
        XCTAssertEqual(Localization.day("2026-11-20", compact: true, language: "zh-Hans"), "2026/11/20")
        XCTAssertEqual(Localization.day("2026-01-02", compact: true, language: "zh-Hans"), "2026/1/2")
        XCTAssertEqual(Localization.day("2026-11-20", compact: false, language: "zh-Hans"), "2026年11月20日")
        XCTAssertEqual(Localization.day("2026-11-20", compact: true, language: "en"), "Nov 20, 2026")
    }

    @MainActor
    func testReportingDateKeepsBeijingBoundary() {
        let date = Localization.date("2026-11-05")!
        XCTAssertEqual(UsageStore.day(date), "2026-11-05")
        XCTAssertEqual(ISO8601DateFormatter().string(from: date), "2026-11-04T16:00:00Z")
    }
}
