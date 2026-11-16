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
    func testTokensDisplayInMillionsWithoutLosingSingleTokenPrecision() {
        XCTAssertEqual(reading(0).formatted, "0.000000M")
        XCTAssertEqual(reading(1).formatted, "0.000001M")
        XCTAssertEqual(reading(999_999).formatted, "0.999999M")
        XCTAssertEqual(reading(1_000_000).formatted, "1.000000M")
        XCTAssertEqual(reading(163_704_355).formatted, "163.704355M")
        XCTAssertEqual(reading(9_007_199_254_740_993).formatted, "9007199254.740993M")
        XCTAssertEqual(reading(1, metric: .cost).formatted, "$18.65")
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
