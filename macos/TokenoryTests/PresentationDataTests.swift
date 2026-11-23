import AppKit
import SwiftUI
import XCTest
@testable import Tokenory

final class PresentationDataTests: XCTestCase {
    @MainActor func testWorkspacePaletteMatchesApprovedLightAndDarkRoles() {
        let roles: [(ColorScheme, [UInt32])] = [
            (.light, [0xF6F8FA, 0xFFFFFF, 0x231B32, 0x60566E, 0x008CE0, 0x00A677,
                      0xE10067, 0xBF8A00, 0x5260BD, 0xC31978, 0x716B80, 0x2E579E]),
            (.dark, [0x100E18, 0x20182C, 0xFFFFFF, 0xC5C3C8, 0x00B0FF, 0x69F0AE,
                     0xFF4081, 0xFFEA00, 0x5C6BC0, 0xF50057, 0xA19EA6, 0xFF4081])
        ]
        let filterLabel = WorkspaceStyle.lightFilterLabel.resolve(in: EnvironmentValues())
        XCTAssertEqual(filterLabel.red, 89 / 255, accuracy: 0.001)
        XCTAssertEqual(filterLabel.green, 99 / 255, accuracy: 0.001)
        XCTAssertEqual(filterLabel.blue, 110 / 255, accuracy: 0.001)
        for (scheme, expected) in roles {
            var environment = EnvironmentValues()
            environment.colorScheme = scheme
            let colors = [WorkspaceStyle.canvas(scheme), WorkspaceStyle.surface(scheme),
                          WorkspaceStyle.text, WorkspaceStyle.subtext, WorkspaceStyle.localUsage,
                          WorkspaceStyle.otherDevices(scheme), WorkspaceStyle.costColor(scheme),
                          WorkspaceStyle.fastUsage(scheme), WorkspaceStyle.cacheRead,
                          WorkspaceStyle.cacheWrite, WorkspaceStyle.reasoningTokens, WorkspaceStyle.selection]
            for (color, rgb) in zip(colors, expected) {
                let resolved = color.resolve(in: environment)
                let actual = UInt32((resolved.red * 255).rounded()) << 16
                    | UInt32((resolved.green * 255).rounded()) << 8 | UInt32((resolved.blue * 255).rounded())
                XCTAssertEqual(actual, rgb, "Color in \(scheme)")
            }
        }
    }

    func testOverviewDeviceSharesPartitionFastWithinEachSource() {
        func shares(_ total: Double, _ amount: Double, _ other: Double, _ fast: Double, _ otherFast: Double) -> [Double] {
            let pieces = OverviewShareSegments(total: total, amount: amount, other: other, fast: fast, otherFast: otherFast)
            return [pieces.localStandard, pieces.localFast, pieces.otherStandard, pieces.otherFast]
        }
        XCTAssertEqual(shares(200, 120, 50, 30, 20), [0.30, 0.05, 0.15, 0.10])
        XCTAssertEqual(shares(2, 1.25, 0.5, 0.375, 0.125), [0.25, 0.125, 0.1875, 0.0625])
        XCTAssertEqual(shares(80, 80, 0, 80, 0), [0, 1, 0, 0])
        XCTAssertEqual(shares(80, 80, 80, 80, 80), [0, 0, 0, 1])
        XCTAssertEqual(shares(80, 80, 24, 80, 24), [0, 0.7, 0, 0.3])
        XCTAssertEqual(shares(80, 80, 24, 0, 0), [0.7, 0, 0.3, 0])
        XCTAssertEqual(shares(0, 0, 0, 0, 0), [0, 0, 0, 0])
    }

    @MainActor func testInactivePanelDropdownUsesTheNativeButtonBackground() throws {
        let dropdown = WorkspaceDropdownTrigger(label: "Tool", value: "All tools", width: 126) {}
        let view = HStack(spacing: 0) {
            WorkspacePanel { dropdown }.frame(width: 200)
            dropdown.padding(18).frame(width: 200, alignment: .leading).background(Color.white)
        }
        .environment(\.colorScheme, .light)
        .environment(\.controlActiveState, .inactive)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 64),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.appearance = NSAppearance(named: .aqua)
        window.contentViewController = NSHostingController(rootView: view)
        window.setContentSize(NSSize(width: 400, height: 64))
        window.orderBack(nil)
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()
        content.displayIfNeeded()
        let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: bitmap)

        // Sample the empty face between the title and chevron, at the same point in both buttons.
        func face(at x: Int) throws -> NSColor {
            try XCTUnwrap(bitmap.colorAt(x: x * bitmap.pixelsWide / 400, y: bitmap.pixelsHigh / 2)?
                .usingColorSpace(.sRGB))
        }
        let panel = try face(at: 115), native = try face(at: 315)
        XCTAssertEqual(panel.alphaComponent, native.alphaComponent, accuracy: 0.01)
        for (actual, expected) in [(panel.redComponent, native.redComponent),
                                   (panel.greenComponent, native.greenComponent),
                                   (panel.blueComponent, native.blueComponent)] {
            XCTAssertEqual(actual, expected, accuracy: 0.06)
        }
    }

    @MainActor func testRankingBarPaintsBothFastPortionsAtFullHeight() throws {
        let bar = OverviewShareBar(total: 200, amount: 120, other: 50, fast: 30, otherFast: 20, height: 5)
            .frame(width: 200).environment(\.colorScheme, .light)
        let view = HStack(spacing: 0) {
            bar
            Rectangle().fill(WorkspaceStyle.fastUsage(.light)).frame(width: 20, height: 5)
        }
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
        XCTAssertEqual(bitmap.pixelsWide, 440)
        XCTAssertEqual(bitmap.pixelsHigh, 10)
        let fast = try XCTUnwrap(bitmap.colorAt(x: 420, y: 5)?.usingColorSpace(.sRGB))
        for y in [1, 5, 8] {
            // Pixel centers on both sides of each of the four source/mode boundaries.
            for (x, expectsFast) in [(118, false), (121, true), (138, true), (141, false),
                                     (198, false), (201, true), (226, true), (244, false)] {
                let value = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                let distance = max(abs(value.redComponent - fast.redComponent),
                                   abs(value.greenComponent - fast.greenComponent),
                                   abs(value.blueComponent - fast.blueComponent))
                XCTAssertEqual(distance < 0.025, expectsFast, "pixel (\(x), \(y)): \(value), compared with \(fast)")
            }
        }
    }

    func testOverviewCountsDistinctUsedModelsAndShowsUnknownDevicePrices() {
        let used = summary(20, cost: 1), unpriced = summary(3, cost: nil), empty = summary(0, cost: nil)
        let groups = [UsageGroup(key: "shared", summary: used), UsageGroup(key: "shared", summary: used),
                      UsageGroup(key: "remote", summary: unpriced), UsageGroup(key: "unused", summary: empty)]
        let report = UsageReport(revision: 1, summary: used, daily: [], clients: [], providers: [],
                                 models: groups, details: [], hourly: nil)
        XCTAssertEqual(report.overviewModelCount, 2)
        XCTAssertEqual(OverviewDeviceRow(id: "r", name: "Mac", summary: unpriced).cost, usd(nil))
        XCTAssertEqual(OverviewDeviceRow(id: "r", name: "Mac", summary: nil).cost, usd(0))
        XCTAssertEqual(OverviewDeviceRow(id: "r", name: "Mac", summary: empty).cost, usd(0))
    }

    @MainActor
    func testFilterRanksKeysByTokensAcrossTheSelectedMacs() {
        let local = [UsageGroup(key: "local", summary: summary(20, cost: nil)),
                     UsageGroup(key: "shared", summary: summary(10, cost: nil)),
                     UsageGroup(key: "another-local", summary: summary(10, cost: nil))]
        let remote = [UsageGroup(key: "remote", summary: summary(40, cost: nil)),
                      UsageGroup(key: "shared", summary: summary(40, cost: nil)),
                      UsageGroup(key: "another-remote", summary: summary(20, cost: nil))]

        let allMacs = UsageFiltersView(showsSource: false, localOnly: false)
        let thisMac = UsageFiltersView(showsSource: true, localOnly: true)
        XCTAssertEqual(allMacs.rankedFilterKeys(local: local, remote: remote),
                       ["shared", "remote", "another-remote", "local", "another-local"])
        XCTAssertEqual(thisMac.rankedFilterKeys(local: local, remote: remote),
                       ["local", "another-local", "shared"])
    }

    @MainActor
    func testOverviewDeviceReadoutOrdersOtherMacsByNameThenID() {
        let rows = [OverviewDeviceRow(id: "total", name: "Total", summary: nil),
                    OverviewDeviceRow(id: "local", name: "This Mac", summary: nil),
                    OverviewDeviceRow(id: "remote:c", name: "Studio", summary: nil),
                    OverviewDeviceRow(id: "remote:a", name: "Studio", summary: nil),
                    OverviewDeviceRow(id: "remote:b", name: "Air", summary: nil)]

        XCTAssertEqual(OverviewDeviceReadout(rows: rows).rows.map(\.id),
                       ["total", "local", "remote:b", "remote:a", "remote:c"])
    }

    @MainActor
    func testStackedDeviceChartSegmentsShareOneBaseline() throws {
        let marks = DashboardChartMarks(
            bars: [.init(frame: CGRect(x: 10, y: 70, width: 14, height: 30), emphasized: true),
                   .init(frame: CGRect(x: 10, y: 25, width: 14, height: 45), emphasized: true, otherDevice: true)],
            series: [], dots: [], frameSize: CGSize(width: 120, height: 100),
            range: DashboardDateSpan(from: "2026-11-22", to: "2026-11-22"),
            animateRangeChanges: false, takeEntrance: { false },
            barColor: .systemBlue, lineColor: .systemPurple, otherDeviceColor: .systemTeal
        )
        let chart = DashboardChartMarks.PlotView()
        chart.update(marks)
        let layers = try XCTUnwrap(chart.layer?.sublayers?.first?.sublayers)
        XCTAssertEqual(layers.count, 2)
        XCTAssertEqual(layers[0].frame.maxY, layers[1].frame.minY)
        XCTAssertEqual(layers[1].frame.maxY, 75)
        XCTAssertNotEqual(layers[0].backgroundColor, layers[1].backgroundColor)
    }

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
        let zone = TimeZone(identifier: "Asia/Shanghai")!
        let trend = UsageTrend(report: report, filter: UsageFilter(from: "2026-11-06", to: "2026-11-06"), now: now, timeZone: zone)
        XCTAssertTrue(trend.hourly)
        XCTAssertEqual(trend.points.count, 24)
        XCTAssertEqual(trend.unallocatedTokens, 20)
        XCTAssertEqual(trend.domain.lowerBound, Localization.date("2026-11-06", timeZone: zone))
        XCTAssertEqual(trend.domain.upperBound, Localization.date("2026-11-07", timeZone: zone))
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
    func testHourlyPlotKeepsBothRepeatedHoursOnFallBack() {
        let day = "2026-11-01"
        let zone = TimeZone(identifier: "America/New_York")!
        let hours = HourlyUsage(buckets: [
            UsageGroup(key: "2026-11-01T01:00:00-04:00", summary: summary(100, cost: 1)),
            UsageGroup(key: "2026-11-01T01:00:00-05:00", summary: summary(200, cost: 2))
        ], unallocated: summary(0, cost: 0))
        let report = UsageReport(revision: 1, summary: summary(300, cost: 3), daily: [], clients: [],
                                 providers: [], models: [], details: [], hourly: hours)
        let end = Localization.date("2026-11-02", timeZone: zone)!
        let trend = UsageTrend(report: report, filter: UsageFilter(from: day, to: day), now: end, timeZone: zone)
        XCTAssertEqual(trend.points.count, 25)
        XCTAssertEqual(trend.points[1].tokens, 100)
        XCTAssertEqual(trend.points[2].tokens, 200)
        XCTAssertEqual(trend.domain.upperBound, end)
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
