import AppKit
import SwiftUI
import XCTest
@testable import Tokenory

@MainActor
final class HUDTests: XCTestCase {
    private func reading(_ tokens: Int64, day: String = "2026-11-16", metric: HUDMetric = .tokens,
                         cost: Double? = 18.645, status: String = "complete") -> HUDReading {
        HUDReading(day: day, metric: metric, summary: UsageSummary(
            tokens: tokens, tokenBreakdown: TokenBreakdown(input: tokens, output: 0, cacheRead: 0, cacheWrite: 0, reasoning: 0),
            knownEstimatedCostUsd: cost, unpricedTokens: status == "partial" ? 10 : 0,
            costStatus: status, recordCount: 1, activeDays: 1, partialDays: nil, requests: nil))
    }
    func testReadingPreservesExactTokensAndUnknownCost() {
        XCTAssertEqual(reading(9_007_199_254_740_993).value, 9_007_199_254_740_993)
        XCTAssertEqual(reading(10, metric: .cost).value, 1865)
        XCTAssertNil(reading(10, metric: .cost, cost: nil, status: "unknown").value)
        XCTAssertTrue(reading(10, metric: .cost, status: "partial").partial)
        XCTAssertFalse(reading(10, status: "partial").partial)
        XCTAssertNil(reading(10, metric: .cost, cost: .infinity).value)
    }
    func testLocalDayUsesDeviceZoneAndDSTMidnights() {
        let parse = ISO8601DateFormatter()
        let instant = parse.date(from: "2026-11-06T02:00:00Z")!
        let la = LocalUsageDay(now: instant, timeZone: TimeZone(identifier: "America/Los_Angeles")!)
        let tokyo = LocalUsageDay(now: instant, timeZone: TimeZone(identifier: "Asia/Tokyo")!)
        XCTAssertEqual(la.day, "2026-11-05")
        XCTAssertEqual(tokyo.day, "2026-11-06")
        XCTAssertEqual(parse.string(from: la.start), "2026-11-05T08:00:00Z")
        XCTAssertEqual(parse.string(from: la.end), "2026-11-06T08:00:00Z")
        let ny = TimeZone(identifier: "America/New_York")!
        let spring = LocalUsageDay(now: parse.date(from: "2026-03-08T12:00:00Z")!, timeZone: ny)
        let autumn = LocalUsageDay(now: parse.date(from: "2026-11-01T12:00:00Z")!, timeZone: ny)
        XCTAssertEqual(spring.end.timeIntervalSince(spring.start), 23 * 3600)
        XCTAssertEqual(autumn.end.timeIntervalSince(autumn.start), 25 * 3600)
    }
    func testIntegerTokensAndPointerSelectedScreen() {
        XCTAssertEqual(reading(163_704_355).formatted, "163,704,355")
        XCTAssertEqual(reading(1).formatted, "1")
        let frames = [CGRect(x: 0, y: 0, width: 1440, height: 900),
                      CGRect(x: -1920, y: 0, width: 1920, height: 1080),
                      CGRect(x: 0, y: 900, width: 1440, height: 900)]
        XCTAssertEqual(HUDController.activeScreenIndex(pointer: CGPoint(x: 50, y: 50), frames: frames), 0)
        XCTAssertEqual(HUDController.activeScreenIndex(pointer: CGPoint(x: -50, y: 50), frames: frames), 1)
        XCTAssertEqual(HUDController.activeScreenIndex(pointer: CGPoint(x: 50, y: 1000), frames: frames), 2)
        XCTAssertNil(HUDController.activeScreenIndex(pointer: CGPoint(x: 2000, y: 2000), frames: frames))
    }
    func testRollCarriesAndDeceleratesToExactTarget() {
        let roll = HUDRoll(from: 999_999, to: 1_000_008)
        XCTAssertEqual(roll.positions(at: 0).map { Int($0) % 10 }, [0, 9, 9, 9, 9, 9, 9])
        XCTAssertEqual(roll.positions(at: 1).map { Int($0) % 10 }, [1, 0, 0, 0, 0, 0, 8])
        let peak = HUDRoll.curve(0.34)
        XCTAssertGreaterThan(peak.speed, HUDRoll.curve(0.6).speed)
        XCTAssertGreaterThan(HUDRoll.curve(0.6).speed, HUDRoll.curve(0.9).speed)
        XCTAssertEqual(HUDRoll.curve(1).speed, 0)
        XCTAssertEqual(HUDRoll.curve(1).progress, 1)
        var prior = 0.0
        for step in 0...1000 {
            let progress = HUDRoll.curve(Double(step) / 1000).progress
            XCTAssertGreaterThanOrEqual(progress, prior)
            prior = progress
        }
    }
    func testFirstReadingSwitchMidnightAndCorrectionsAreSilent() {
        let model = HUDAnimator()
        model.receive(reading(128_648), animated: true)
        XCTAssertFalse(model.isRolling)
        model.receive(reading(128_656), animated: true)
        XCTAssertTrue(model.isRolling)
        model.receive(reading(2, day: "2026-11-17"), animated: true)
        XCTAssertFalse(model.isRolling)
        XCTAssertEqual(model.reading?.value, 2)
        model.receive(reading(1, day: "2026-11-17"), animated: true)
        XCTAssertFalse(model.isRolling)
        model.receive(reading(1, day: "2026-11-17", metric: .cost), animated: true)
        XCTAssertFalse(model.isRolling)
    }

    func testTensEaseInNearCarryWithoutChangingUnitsPace() {
        let animator = HUDAnimator()
        animator.receive(reading(123), animated: true)
        animator.receive(reading(135), animated: true)
        for (ticks, tens) in [(4.0, 2.0), (5.0, 2.0), (6.0, 2.5), (7.0, 3.0), (9.0, 3.0)] {
            animator.advance(elapsed: time(atProgress: ticks / 12))
            XCTAssertEqual(animator.positions[4], tens, accuracy: 1e-8)
            XCTAssertEqual(animator.positions[5], 3 + ticks, accuracy: 1e-8)
        }
        animator.advance(elapsed: 4.2)
        XCTAssertEqual(Array(animator.positions.suffix(3)).map { Int($0) % 10 }, [1, 3, 5])
        XCTAssertFalse(animator.isRolling)
    }

    func test099CarryMovesBothHigherWheelsAndSettlesTogether() {
        let animator = HUDAnimator()
        animator.receive(reading(99), animated: true)
        animator.receive(reading(100), animated: true)
        animator.advance(elapsed: time(atProgress: 0.5))
        let middle = Array(animator.positions.suffix(3))
        for (actual, expected) in zip(middle, [0.5, 9.5, 9.5]) {
            XCTAssertEqual(actual, expected, accuracy: 1e-8)
        }
        animator.advance(elapsed: 4.2)
        XCTAssertEqual(Array(animator.positions.suffix(3)).map { Int($0) % 10 }, [1, 0, 0])
    }

    func testNewReadingMakesCarryReachableWithoutJumpingHigherWheel() {
        let animator = HUDAnimator()
        animator.receive(reading(123), animated: true)
        animator.receive(reading(129), animated: true)
        animator.advance(elapsed: time(atProgress: 5.5 / 6))
        let before = animator.positions
        XCTAssertEqual(before[4], 2)
        animator.receive(reading(135), animated: true)
        XCTAssertEqual(animator.positions, before)
        animator.advance(elapsed: 9)
        XCTAssertEqual(Array(animator.positions.suffix(3)).map { Int($0) % 10 }, [1, 3, 5])
    }

    private func time(atProgress desired: Double) -> TimeInterval {
        var lower = 0.0
        var upper = 1.0
        for _ in 0..<48 {
            let middle = (lower + upper) / 2
            if HUDRoll.curve(middle).progress < desired { lower = middle }
            else { upper = middle }
        }
        return (lower + upper) / 2 * 4.2
    }
    func testUpdatesExtendCurrentRollWithoutRestartAndHideStopsWork() {
        let model = HUDAnimator()
        model.receive(reading(100), animated: true)
        model.receive(reading(110), animated: true)
        model.advance(elapsed: 1)
        let positions = model.positions
        let generation = model.generation
        model.receive(reading(130), animated: true)
        model.receive(reading(150), animated: true)
        XCTAssertEqual(model.reading?.value, 150)
        XCTAssertEqual(model.positions, positions)
        XCTAssertEqual(model.generation, generation)
        model.advance(elapsed: 4.3)
        XCTAssertTrue(model.isRolling)
        model.advance(elapsed: 6)
        XCTAssertFalse(model.isRolling)
        XCTAssertEqual(model.reading?.value, 150)
        model.receive(reading(200), animated: true)
        model.settle()
        XCTAssertFalse(model.isRolling)
        XCTAssertEqual(model.reading?.value, 200)
        XCTAssertEqual(model.positions.map { Int($0) % 10 }, [0, 0, 0, 2, 0, 0])
    }
    func testMidRollUpdatePreservesVelocityAndNewDigitCarry() {
        let model = HUDAnimator()
        model.receive(reading(999_900), animated: true)
        model.receive(reading(999_999), animated: true)
        model.advance(elapsed: 1.4999)
        let before = model.positions
        model.advance(elapsed: 1.5)
        let atUpdate = model.positions
        model.receive(reading(1_000_017), animated: true)
        XCTAssertEqual(Array(model.positions.suffix(6)), atUpdate)
        model.advance(elapsed: 1.5001)
        let after = Array(model.positions.suffix(6))
        for index in before.indices {
            XCTAssertEqual((after[index] - atUpdate[index]) / 0.0001,
                           (atUpdate[index] - before[index]) / 0.0001, accuracy: 0.02)
        }
        var previous = model.positions
        for step in 151...700 {
            model.advance(elapsed: Double(step) / 100)
            for (old, new) in zip(previous, model.positions) { XCTAssertGreaterThanOrEqual(new + 1e-10, old) }
            previous = model.positions
        }
        XCTAssertFalse(model.isRolling)
        XCTAssertEqual(model.positions.map { Int($0) % 10 }, [1, 0, 0, 0, 0, 1, 7])
    }
    func testFrequentIncrementsDoNotQueueExtraRollsOrPhantomClicks() {
        let model = HUDAnimator()
        model.receive(reading(100), animated: true)
        model.receive(reading(200), animated: true)
        let generation = model.generation
        for update in 1...30 {
            let time = Double(update) / 10
            model.advance(elapsed: time)
            let positions = model.positions
            model.receive(reading(200 + Int64(update) * 8400), animated: true)
            XCTAssertEqual(model.positions, positions)
            XCTAssertEqual(model.generation, generation)
            XCTAssertFalse(model.advance(elapsed: time))
            XCTAssertTrue(model.positions.allSatisfy(\.isFinite))
        }
        model.advance(elapsed: 7.3)
        XCTAssertFalse(model.isRolling)
        XCTAssertEqual(model.positions.map { Int($0) % 10 }, [2, 5, 2, 2, 0, 0])
        XCTAssertEqual(model.reading?.value, 252_200)
    }
    func testPreferencesPersistAndValidateStoredValues() {
        let name = "Tokenory-HUD-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = HUDPreferences(defaults: defaults)
        XCTAssertFalse(preferences.enabled)
        XCTAssertFalse(preferences.autoHideWhenIdle)
        XCTAssertEqual(preferences.dismissal, .disable)
        XCTAssertFalse(preferences.soundEnabled)
        XCTAssertEqual(preferences.volume, 0.35)
        preferences.placement = .topCenter
        preferences.autoHideWhenIdle = true
        preferences.dismissal = .minute1
        preferences.enabled = true; preferences.soundEnabled = true; preferences.volume = 0.6; preferences.metric = .cost
        let restored = HUDPreferences(defaults: defaults)
        XCTAssertEqual(restored.placement, .topCenter)
        XCTAssertTrue(restored.enabled); XCTAssertTrue(restored.soundEnabled)
        XCTAssertTrue(restored.autoHideWhenIdle)
        XCTAssertEqual(restored.dismissal, .minute1)
        XCTAssertEqual(HUDDismissal.allCases.map(\.duration), [nil, .seconds(30), .seconds(60), .seconds(300), nil])
        restored.dismissal = .ignore
        XCTAssertEqual(HUDPreferences(defaults: defaults).dismissal, .ignore)
        XCTAssertEqual(restored.volume, 0.6); XCTAssertEqual(restored.metric, .cost)
        defaults.set(8, forKey: "hud.volume")
        XCTAssertEqual(HUDPreferences(defaults: defaults).volume, 1)
    }
    func testPlacementUsesCompactScreenEdgesIncludingOffsetDisplays() {
        let bounds = CGRect(x: -1440, y: 80, width: 1440, height: 790)
        let screen = CGRect(x: -1440, y: 0, width: 1440, height: 900)
        let size = CGSize(width: 220, height: 92)
        // Compact 10pt visual edge inset (= 5pt frame inset) and 3pt clearance below menu bar.
        let expected: [CGPoint] = [
            CGPoint(x: -1435, y: 775), CGPoint(x: -830, y: 775), CGPoint(x: -225, y: 775),
            CGPoint(x: -1435, y: 80), CGPoint(x: -830, y: 80), CGPoint(x: -225, y: 80)
        ]
        for (placement, origin) in zip(HUDPlacement.allCases, expected) {
            XCTAssertEqual(placement.origin(in: bounds, screenFrame: screen, size: size), origin)
            XCTAssertTrue(screen.contains(CGRect(origin: origin, size: size)))
        }
    }
    func testBottomCornersSitFlushWhenDockDoesNotOverlapAndLiftWhenOverlapping() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let visible = CGRect(x: 0, y: 70, width: 1440, height: 800)
        let size = CGSize(width: 220, height: 92)

        // Centered narrow Dock (width 500 -> x: 470...970): bottomLeft and bottomRight sit flush at bottom!
        let narrowDock = CGRect(x: 470, y: 0, width: 500, height: 68)
        let narrowMetrics = HUDDisplayMetrics(screenFrame: screen, visibleFrame: visible, dockRect: narrowDock, menuBarHeight: 30)
        let leftOrigin = HUDLayoutSolver.origin(for: HUDPlacement.bottomLeft.anchor, in: narrowMetrics, size: size)
        let rightOrigin = HUDLayoutSolver.origin(for: HUDPlacement.bottomRight.anchor, in: narrowMetrics, size: size)
        let centerOrigin = HUDLayoutSolver.origin(for: HUDPlacement.bottomCenter.anchor, in: narrowMetrics, size: size)
        XCTAssertEqual(leftOrigin, CGPoint(x: 5, y: 5))
        XCTAssertEqual(rightOrigin, CGPoint(x: 1215, y: 5))
        XCTAssertEqual(centerOrigin.y, 71) // Lifted above Dock (68 + 3pt frame clearance).

        // Wide Dock reaching corners: bottomLeft and bottomRight lift above Dock.
        let wideDock = CGRect(x: 120, y: 0, width: 1200, height: 68)
        let wideMetrics = HUDDisplayMetrics(screenFrame: screen, visibleFrame: visible, dockRect: wideDock, menuBarHeight: 30)
        XCTAssertEqual(HUDLayoutSolver.origin(for: HUDPlacement.bottomLeft.anchor, in: wideMetrics, size: size).y, 71)
        XCTAssertEqual(HUDLayoutSolver.origin(for: HUDPlacement.bottomRight.anchor, in: wideMetrics, size: size).y, 71)

        // Auto-hidden Dock collapsed (dockRect == nil, dockAutoHidden == true): bottomCenter sits flush too.
        let hiddenDockMetrics = HUDDisplayMetrics(screenFrame: screen, visibleFrame: screen, dockRect: nil, menuBarHeight: 0, dockAutoHidden: true, menuBarAutoHidden: true)
        XCTAssertEqual(HUDLayoutSolver.origin(for: HUDPlacement.bottomCenter.anchor, in: hiddenDockMetrics, size: size).y, 5)

        // Notch avoidance when menu bar is auto-hidden and collapsed.
        let notch = CGRect(x: 620, y: 866, width: 200, height: 34)
        let notchMetrics = HUDDisplayMetrics(screenFrame: screen, visibleFrame: screen, dockRect: nil, menuBarHeight: 0, notchRect: notch, dockAutoHidden: true, menuBarAutoHidden: true)
        XCTAssertEqual(HUDLayoutSolver.origin(for: HUDPlacement.topCenter.anchor, in: notchMetrics, size: size).y, 866 - 3 - size.height)
        XCTAssertEqual(HUDLayoutSolver.origin(for: HUDPlacement.topLeft.anchor, in: notchMetrics, size: size).y, 900 - 5 - size.height)
    }
    func testMagneticSnapChoosesNearestEdgeAndScalesBounceWithDistance() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let metrics = HUDDisplayMetrics(screenFrame: screen, visibleFrame: screen, dockRect: nil, menuBarHeight: 0, dockAutoHidden: true, menuBarAutoHidden: true)
        let size = CGSize(width: 220, height: 92)

        let leftSnap = HUDLayoutSolver.snap(from: CGPoint(x: 40, y: 400), velocity: .zero, in: metrics, size: size)
        XCTAssertEqual(leftSnap.edge, .left)
        XCTAssertNil(leftSnap.matchingPreset())

        let rightSnap = HUDLayoutSolver.snap(from: CGPoint(x: 1180, y: 400), velocity: .zero, in: metrics, size: size)
        XCTAssertEqual(rightSnap.edge, .right)

        let near = HUDLayoutSolver.magneticSnapParameters(from: CGPoint(x: 25, y: 10), to: CGPoint(x: 5, y: 10), releaseVelocity: .zero)
        let far = HUDLayoutSolver.magneticSnapParameters(from: CGPoint(x: 400, y: 10), to: CGPoint(x: 5, y: 10), releaseVelocity: .zero)
        XCTAssertLessThan(far.damping, near.damping, "Farther release should have lower effective damping for stronger bounce")
        XCTAssertGreaterThan(abs(far.initialVelocity.dx), abs(near.initialVelocity.dx))
    }
    func testReducedMotionUnavailableAndLargestCounterSettleExactly() {
        let model = HUDAnimator()
        model.receive(reading(999_999), animated: false)
        model.receive(reading(1_000_000), animated: false)
        XCTAssertFalse(model.isRolling)
        XCTAssertEqual(model.positions.map { Int($0) % 10 }, [1, 0, 0, 0, 0, 0, 0])
        model.receive(reading(1, metric: .cost, cost: nil, status: "unknown"), animated: true)
        XCTAssertTrue(model.positions.isEmpty)
        let roll = HUDRoll(from: Int64.max - 5, to: Int64.max)
        XCTAssertEqual(roll.positions(at: 1).map { String(Int($0) % 10) }.joined(), String(Int64.max))
    }
    func testBundledMechanicalFontAndBilingualControls() {
        _ = HUDController.fontRegistered
        XCTAssertNotNil(NSFont(name: "SairaExtraCondensed-SemiBold", size: 60))
        XCTAssertNotNil(Bundle.main.url(forResource: "SairaExtraCondensed-OFL", withExtension: "txt"))
        XCTAssertEqual(Localization.string("hud.sound", language: "en"), "Roller sound")
        XCTAssertEqual(Localization.string("hud.sound", language: "zh-Hans"), "滚轮音效")
        XCTAssertEqual(Localization.string("hud.show", language: "zh-Hans"), "显示 HUD")
    }
    func testFirstPanelOpenInstallsHostedCounterAndHideReleasesIt() async throws {
        let name = "Tokenory-HUD-panel-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = HUDPreferences(defaults: defaults)
        preferences.enabled = true
        let controller = HUDController(preferences: preferences, store: UsageStore(), reduceMotion: { true })
        controller.start()
        defer { controller.stop() }
        let content = try XCTUnwrap(controller.panel?.contentView)
        XCTAssertTrue(String(reflecting: type(of: content)).contains("NSHostingView"))
        XCTAssertFalse(controller.panel?.isKeyWindow ?? true)
        preferences.placement = .topLeft
        try await Task.sleep(for: .milliseconds(50))
        let panel = try XCTUnwrap(controller.panel)
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertFalse(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenNone))
        let screen = try XCTUnwrap(panel.screen)
        XCTAssertEqual(panel.frame.size, MechanicalHUDView.windowSize)
        XCTAssertLessThanOrEqual(panel.frame.maxY, screen.visibleFrame.maxY)
        XCTAssertGreaterThanOrEqual(panel.frame.maxY, screen.visibleFrame.maxY - 10)
        XCTAssertGreaterThanOrEqual(panel.frame.minX, screen.visibleFrame.minX)
        let originalOrigin = panel.frame.origin
        preferences.volume = 0.2
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(panel.frame.origin, originalOrigin)
        preferences.enabled = false
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(controller.panel?.contentView)
        preferences.enabled = true
        try await Task.sleep(for: .milliseconds(50))
        let reopened = try XCTUnwrap(controller.panel?.contentView)
        XCTAssertTrue(String(reflecting: type(of: reopened)).contains("NSHostingView"))
    }

    func testIdleHUDWakesForUsageAndTripleClickHonorsSavedAction() async throws {
        let name = "Tokenory-HUD-visibility-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = HUDPreferences(defaults: defaults)
        let store = UsageStore()
        func report(_ tokens: Int64, cost: Double) -> UsageReport {
            let summary = UsageSummary(tokens: tokens, tokenBreakdown: TokenBreakdown(input: tokens, output: 0, cacheRead: 0, cacheWrite: 0, reasoning: 0),
                                       knownEstimatedCostUsd: cost, unpricedTokens: 0, costStatus: "complete",
                                       recordCount: 1, activeDays: 1, partialDays: nil, requests: 1)
            return UsageReport(revision: 0, summary: summary, daily: [], clients: [], providers: [], models: [], details: [], hourly: nil)
        }
        store.today = report(100, cost: 1)
        preferences.enabled = true
        let controller = HUDController(preferences: preferences, store: store, idleTimeout: .milliseconds(200), reduceMotion: { true })
        controller.start()
        defer { controller.stop() }
        XCTAssertEqual(controller.panel?.isVisible, true)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(controller.panel?.isVisible, true)
        preferences.autoHideWhenIdle = true
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(controller.panel?.isVisible, false)
        XCTAssertTrue(preferences.enabled)
        preferences.metric = .cost
        store.today = report(100, cost: 2)
        try await Task.sleep(for: .milliseconds(35))
        XCTAssertEqual(controller.panel?.isVisible, false)
        preferences.autoHideWhenIdle = false
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(controller.panel?.isVisible, true)
        preferences.autoHideWhenIdle = true
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(controller.panel?.isVisible, false)
        store.today = report(120, cost: 2)
        try await Task.sleep(for: .milliseconds(35))
        XCTAssertEqual(controller.panel?.isVisible, true)
        preferences.dismissal = .seconds30
        controller.dismissFromHUD()
        preferences.autoHideWhenIdle = false
        store.today = report(140, cost: 2)
        try await Task.sleep(for: .milliseconds(35))
        XCTAssertEqual(controller.panel?.isVisible, false)
        XCTAssertTrue(preferences.enabled)
        preferences.enabled = false
        try await Task.sleep(for: .milliseconds(35))
        preferences.enabled = true
        try await Task.sleep(for: .milliseconds(35))
        XCTAssertEqual(controller.panel?.isVisible, true)
        preferences.dismissal = .disable
        controller.dismissFromHUD()
        XCTAssertFalse(preferences.enabled)
        XCTAssertEqual(controller.panel?.isVisible, false)
    }

    func testHUDDoubleClickOpensStatisticsAndTripleClickUsesConfiguredAction() async throws {
        let name = "Tokenory-HUD-clicks-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = HUDPreferences(defaults: defaults)
        preferences.enabled = true
        var openedStatistics = 0
        let controller = HUDController(preferences: preferences, store: UsageStore(), openStatistics: { openedStatistics += 1 }, reduceMotion: { true })
        controller.start()
        defer { controller.stop() }
        let panel = try XCTUnwrap(controller.panel)
        let readout = CGPoint(x: 110, y: 59)
        func click(_ count: Int, at location: CGPoint) async throws {
            for click in 1...count {
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    let event = try XCTUnwrap(NSEvent.mouseEvent(
                        with: type, location: location, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                        context: nil, eventNumber: click, clickCount: click, pressure: type == .leftMouseDown ? 1 : 0
                    ))
                    NSApp.postEvent(event, atStart: false)
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.2))
        }
        try await click(2, at: readout)
        XCTAssertEqual(openedStatistics, 1)
        XCTAssertTrue(panel.isVisible)
        try await click(2, at: CGPoint(x: 10, y: 59))
        XCTAssertEqual(openedStatistics, 2)
        preferences.dismissal = .ignore
        try await click(3, at: readout)
        XCTAssertEqual(openedStatistics, 2)
        XCTAssertTrue(preferences.enabled)
        XCTAssertTrue(panel.isVisible)
        preferences.dismissal = .disable
        try await click(3, at: readout)
        XCTAssertEqual(openedStatistics, 2)
        XCTAssertFalse(preferences.enabled)
        XCTAssertFalse(panel.isVisible)
    }

    func testHUDFadeOutIsInterruptibleByReshowAndCompletesWhenNotInterrupted() async throws {
        let name = "Tokenory-HUD-fade-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = HUDPreferences(defaults: defaults)
        preferences.enabled = true
        let controller = HUDController(preferences: preferences, store: UsageStore(), reduceMotion: { false })
        controller.start()
        defer { controller.stop() }
        let panel = try XCTUnwrap(controller.panel)
        XCTAssertTrue(panel.isVisible)

        // Start fading out, then immediately re-enable before the 140ms fade completes.
        preferences.enabled = false
        try await Task.sleep(for: .milliseconds(40))
        preferences.enabled = true
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertTrue(panel.isVisible, "Stale fade-out completion must not orderOut a re-shown HUD")
        XCTAssertNotNil(panel.contentView)

        // Let a full fade-out complete without interruption.
        preferences.enabled = false
        try await Task.sleep(for: .milliseconds(260))
        XCTAssertFalse(panel.isVisible)
        XCTAssertNil(panel.contentView)
    }

    func testHostedHUDRollsAcrossFramesInsteadOfSnappingOnFirstTick() async throws {
        let name = "Tokenory-HUD-roll-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = HUDPreferences(defaults: defaults)
        let store = UsageStore()
        func report(_ tokens: Int64) -> UsageReport {
            let summary = UsageSummary(tokens: tokens, tokenBreakdown: TokenBreakdown(input: tokens, output: 0, cacheRead: 0, cacheWrite: 0, reasoning: 0),
                                       knownEstimatedCostUsd: 1, unpricedTokens: 0, costStatus: "complete",
                                       recordCount: 1, activeDays: 1, partialDays: nil, requests: 1)
            return UsageReport(revision: 0, summary: summary, daily: [], clients: [], providers: [], models: [], details: [], hourly: nil)
        }
        store.today = report(100)
        let animator = HUDAnimator()
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: MechanicalHUDView.windowSize),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = NSHostingView(rootView: MechanicalHUDView(
            canPlaySound: { false }, dismiss: {}, animator: animator
        ).environment(store).environment(preferences))
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil); panel.contentView = nil }

        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(animator.reading?.value, 100)
        XCTAssertFalse(animator.isRolling)
        let beforePositions = animator.positions

        store.today = report(250)
        try await Task.sleep(for: .milliseconds(160))
        XCTAssertEqual(animator.reading?.value, 250)
        XCTAssertTrue(animator.isRolling, "HUD should still be rolling smoothly instead of snapping on the first tick")
        XCTAssertNotEqual(animator.positions, beforePositions, "HUD drums should visibly advance across frames")
        XCTAssertNotEqual(animator.positions.map { Int($0) % 10 }, [0, 0, 0, 2, 5, 0])
    }

}
