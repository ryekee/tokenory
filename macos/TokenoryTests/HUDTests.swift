import AppKit
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
        XCTAssertFalse(preferences.soundEnabled)
        XCTAssertEqual(preferences.volume, 0.35)
        preferences.placement = .topCenter
        preferences.enabled = true; preferences.soundEnabled = true; preferences.volume = 0.6; preferences.metric = .cost
        let restored = HUDPreferences(defaults: defaults)
        XCTAssertEqual(restored.placement, .topCenter)
        XCTAssertTrue(restored.enabled); XCTAssertTrue(restored.soundEnabled)
        XCTAssertEqual(restored.volume, 0.6); XCTAssertEqual(restored.metric, .cost)
        defaults.set(8, forKey: "hud.volume")
        XCTAssertEqual(HUDPreferences(defaults: defaults).volume, 1)
    }
    func testPlacementUsesVisibleScreenEdgesIncludingOffsetDisplays() {
        let bounds = CGRect(x: -1440, y: 80, width: 1440, height: 790)
        let size = CGSize(width: 220, height: 92)
        let expected: [CGPoint] = [
            CGPoint(x: -1309, y: 778), CGPoint(x: -830, y: 778), CGPoint(x: -351, y: 778),
            CGPoint(x: -1309, y: 80), CGPoint(x: -830, y: 80), CGPoint(x: -351, y: 80)
        ]
        for (placement, origin) in zip(HUDPlacement.allCases, expected) {
            XCTAssertEqual(placement.origin(in: bounds, screenFrame: CGRect(x: -1440, y: 0, width: 1440, height: 900), size: size), origin)
            XCTAssertTrue(bounds.contains(CGRect(origin: origin, size: size)))
        }
    }
    func testCornerMarginsMatchScreenAspectRatioAndAvoidSideDock() {
        let screen = CGRect(x: 0, y: 0, width: 900, height: 1600)
        let visible = CGRect(x: 80, y: 0, width: 820, height: 1570)
        let size = CGSize(width: 220, height: 92)
        let left = HUDPlacement.bottomLeft.origin(in: visible, screenFrame: screen, size: size)
        XCTAssertEqual(left.x, 80)
        let right = HUDPlacement.bottomRight.origin(in: visible, screenFrame: screen, size: size)
        XCTAssertEqual(right.x, 680) // Keep the entire panel inside the usable area.
        let bottomDock = CGRect(x: 0, y: 80, width: 900, height: 1490)
        let corner = HUDPlacement.bottomRight.origin(in: bottomDock, screenFrame: screen, size: size)
        XCTAssertEqual((screen.maxX - (corner.x + size.width - 5)) / screen.width,
                       (corner.y + 5 - screen.minY) / screen.height, accuracy: 0.000001)
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
        let controller = HUDController(preferences: preferences, store: UsageStore())
        controller.start()
        defer { controller.stop() }
        let content = try XCTUnwrap(controller.panel?.contentView)
        XCTAssertTrue(String(reflecting: type(of: content)).contains("NSHostingView"))
        XCTAssertFalse(controller.panel?.isKeyWindow ?? true)
        preferences.placement = .topLeft
        try await Task.sleep(for: .milliseconds(50))
        let panel = try XCTUnwrap(controller.panel)
        let screen = try XCTUnwrap(panel.screen)
        XCTAssertEqual(panel.frame.size, MechanicalHUDView.windowSize)
        XCTAssertEqual(panel.frame.maxY, screen.visibleFrame.maxY)
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
}
