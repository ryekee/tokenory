import AppKit
import SwiftUI
import XCTest
@testable import Tokenory

@MainActor
final class CursorTooltipTests: XCTestCase {
    func testHoverFocusIsImmediateAndOnlyTheReadoutWaits() async throws {
        let hover = HoverDwell<Int>(delay: .milliseconds(40))
        hover.update(1)
        XCTAssertEqual(hover.target, 1)
        XCTAssertNil(hover.readoutTarget)
        hover.update(2)
        XCTAssertEqual(hover.target, 2)
        XCTAssertNil(hover.readoutTarget)

        // Repeated pointer samples for the same target must let the timer finish.
        let deadline = ContinuousClock.now + .seconds(1)
        while hover.readoutTarget == nil, ContinuousClock.now < deadline {
            hover.update(2)
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(hover.readoutTarget, 2)

        hover.update(3)
        XCTAssertEqual(hover.target, 3)
        XCTAssertNil(hover.readoutTarget)
        hover.update(nil)
        XCTAssertNil(hover.target)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertNil(hover.readoutTarget)
    }

    func testCalendarWaitsLongerThanOtherReadouts() {
        XCTAssertGreaterThan(HoverDwell<Int>.calendarDelay, HoverDwell<Int>.standardDelay)
    }

    func testFollowsPointerAndFlipsBesideTheSelectedMark() {
        let size = CGSize(width: 213, height: 84)
        let window = CGRect(x: 0, y: 0, width: 660, height: 440)
        for x in [24, 189, 435, 640] {
            let mark = CGRect(x: x - 18, y: 110, width: 36, height: 160)
            for y in [116, 145, 229] {
                let pointer = CGPoint(x: x, y: y)
                let card = CursorTooltipLayout.frame(size: size, pointer: pointer, mark: mark, bounds: window)
                XCTAssertTrue(window.contains(card))
                XCTAssertFalse(card.intersects(mark))
                XCTAssertFalse(card.contains(pointer))
                XCTAssertEqual(card.size, size)
                XCTAssertEqual(card.maxY, pointer.y + 5)
                if x == 640 { XCTAssertLessThan(card.maxX, mark.minX) }
                else if x == 24 { XCTAssertGreaterThan(card.minX, mark.maxX) }
            }
        }
    }

    func testWideValuePlacesReadoutVerticallyWithoutCoveringDigits() {
        let window = CGRect(x: 10, y: 15, width: 330, height: 300)
        let size = CGSize(width: 260, height: 80)
        for y in [30, 140, 250] {
            let value = CGRect(x: 56, y: y, width: 200, height: 36)
            let point = CGPoint(x: value.midX, y: value.midY)
            let card = CursorTooltipLayout.frame(size: size, pointer: point, mark: value, bounds: window)
            XCTAssertTrue(window.contains(card))
            XCTAssertFalse(card.intersects(value))
            XCTAssertFalse(card.contains(point))
        }
    }

    private func size<V: View>(_ view: V) -> CGSize {
        NSHostingView(rootView: view.fixedSize()).intrinsicContentSize
    }

    func testBucketCardKeepsExactSizeAcrossDatesPricesAndHours() {
        let tokens = TokenBreakdown(input: 100, output: 0, cacheRead: 0, cacheWrite: 0, reasoning: 0)
        let partial = UsageSummary(tokens: 735_423_210, tokenBreakdown: tokens, knownEstimatedCostUsd: 97_332.92,
                                   unpricedTokens: 134_000_000, costStatus: "partial", recordCount: 8, activeDays: 1,
                                   partialDays: 1, requests: nil)
        let priced = UsageSummary(tokens: 28, tokenBreakdown: tokens, knownEstimatedCostUsd: 0.002,
                                  unpricedTokens: 0, costStatus: "complete", recordCount: 1, activeDays: 1,
                                  partialDays: 0, requests: nil)
        let samples: [(String, UsageSummary?)] = [("November 23, 2026", partial), ("May 1, 2026", priced), ("08:00–09:00", nil)]
        for multi in [false, true] {
            func card(_ sample: (String, UsageSummary?), reserves: Bool) -> CGSize {
                let rows = multi ? [OverviewDeviceRow(id: "total", name: "Total", summary: sample.1),
                                    OverviewDeviceRow(id: "local", name: "MacBook Pro", summary: sample.1),
                                    OverviewDeviceRow(id: "remote", name: "Mac mini", summary: nil)] : []
                return size(UsageBucketReadout(title: sample.0, summary: sample.1, tokens: sample.1?.tokens ?? 0,
                           cost: sample.1?.knownEstimatedCostUsd, rows: rows, width: multi ? 255 : 152, reservesPendingLine: reserves))
            }
            let reference = card(samples[0], reserves: true)
            XCTAssertGreaterThan(reference.height, 0)
            for day in samples { XCTAssertEqual(card(day, reserves: true), reference) }
            XCTAssertLessThan(card(samples[1], reserves: false).height, reference.height)
        }
    }

    func testAnnualHistoryCardKeepsExactSizeAsActiveModelsChange() {
        let series = [
            HistoryDayReadout.Row(model: "long-model-name-with-parameters-and-version", color: .blue, value: "932.46M"),
            HistoryDayReadout.Row(model: "短名称", color: .green, value: "—"),
            HistoryDayReadout.Row(model: "GPT", color: .purple, value: "1")
        ]
        for average in [false, true] {
            func card(_ count: Int, title: String) -> CGSize {
                size(HistoryDayReadout(title: title, average: average, rows: Array(series.prefix(count)), rowCount: 3, width: 210))
            }
            let full = card(3, title: "November 23")
            XCTAssertEqual(full.width, 210, accuracy: 1)
            XCTAssertEqual(card(1, title: "May 1"), full)
            XCTAssertEqual(card(0, title: "June 30"), full)
        }
    }

    func testReadoutIsPaintedAboveSplitViewAndPassesMouseEventsThrough() async throws {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 760, height: 420),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let mark = CGRect(x: 45, y: 45, width: 20, height: 90)
        let pointer = TooltipPointer()
        pointer.move(to: CGPoint(x: 55, y: 60))
        let root = NavigationSplitView {
            Text("Sidebar")
        } detail: {
            ScrollView {
                Color.black.frame(height: 320)
                    .background { GeometryReader { geo in TooltipGeometryProbe().frame(width: geo.size.width, height: geo.size.height) } }
                    .selectedTooltip(avoiding: mark, pointer: pointer) {
                        Color(red: 1, green: 0, blue: 1).frame(width: 130, height: 34)
                    }
                    .padding(.top, 32)
                    .padding(.horizontal, 18)
            }
            .cursorTooltipSurface()
            .toolbar { Button("Scope") {} }
        }
        window.contentViewController = NSHostingController(rootView: root)
        window.setContentSize(NSSize(width: 760, height: 420))
        window.orderBack(nil)
        let content = try XCTUnwrap(window.contentView)
        func find(_ id: String, in view: NSView) -> NSView? {
            if view.identifier?.rawValue == id { return view }
            return view.subviews.lazy.compactMap { find(id, in: $0) }.first
        }
        var found: NSView?
        for _ in 0..<30 {
            content.layoutSubtreeIfNeeded()
            found = find("Tokenory.cursorTooltip", in: content)
            if let found, found.frame.width > 0 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let tooltip = try XCTUnwrap(found)
        XCTAssertEqual(tooltip.frame.width, 150, accuracy: 1)
        XCTAssertEqual(tooltip.frame.height, 50, accuracy: 1)
        XCTAssertNil(tooltip.hitTest(CGPoint(x: 10, y: 10)))
        XCTAssertNil(tooltip.superview?.hitTest(tooltip.frame.origin))
        let plot = try XCTUnwrap(find("plot-geometry", in: content))
        let plotFrame = plot.convert(plot.bounds, to: nil)
        XCTAssertGreaterThan(plotFrame.minX, 18)
        for sample in [CGPoint(x: 55, y: 60), CGPoint(x: 63, y: 110)] {
            pointer.move(to: sample)
            let card = tooltip.convert(tooltip.bounds, to: nil)
            // SwiftUI hover coordinates start at the plot's top left. AppKit window y grows upward.
            XCTAssertEqual(card.minX, plotFrame.minX + mark.maxX + 9, accuracy: 1)
            XCTAssertEqual(card.maxY, plotFrame.maxY - sample.y + 5, accuracy: 1)
        }
        let frame = tooltip.convert(tooltip.bounds, to: content)
        XCTAssertTrue(content.bounds.contains(frame))

        // Checking only the card frame misses views occluded by SwiftUI's native split panes.
        content.displayIfNeeded()
        let sample = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: frame))
        content.cacheDisplay(in: frame, to: sample)
        let color = try XCTUnwrap(sample.colorAt(x: sample.pixelsWide / 2, y: sample.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(color.redComponent, 0.85)
        // The window server can colour-manage the marker. Its green channel must
        // still be clearly separated from both red and blue.
        XCTAssertLessThan(color.greenComponent + 0.4, min(color.redComponent, color.blueComponent))
        XCTAssertGreaterThan(color.blueComponent, 0.85)
    }
}

private struct TooltipGeometryProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.identifier = .init("plot-geometry")
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
}
