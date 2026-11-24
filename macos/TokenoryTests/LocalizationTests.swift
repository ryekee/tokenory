import AppKit
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
    func testReportingDateUsesSystemMidnight() {
        let date = Localization.date("2026-11-05")!
        XCTAssertEqual(UsageStore.day(date), "2026-11-05")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        XCTAssertEqual(date, calendar.date(from: DateComponents(year: 2026, month: 11, day: 5)))
    }

    @MainActor
    func testBackgroundClockNotificationsRefreshOnMainActor() async {
        let center = NotificationCenter()
        let workspaceCenter = NotificationCenter()
        let refreshed = expectation(description: "Midnight, time zone and wake each trigger a refresh")
        refreshed.expectedFulfillmentCount = 3
        let observer = SystemClockObserver(center: center, workspaceCenter: workspaceCenter) {
            MainActor.preconditionIsolated()
            refreshed.fulfill()
        }

        DispatchQueue.global().async {
            dispatchPrecondition(condition: .notOnQueue(.main))
            center.post(name: .NSCalendarDayChanged, object: nil)
            center.post(name: .NSSystemTimeZoneDidChange, object: nil)
            workspaceCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        }
        await fulfillment(of: [refreshed], timeout: 5)
        withExtendedLifetime(observer) {}
    }
}
