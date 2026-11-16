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
    func testUpdatesCoalesceAndHideStopsWork() {
        let model = HUDAnimator()
        model.receive(reading(100), animated: true)
        model.receive(reading(110), animated: true)
        model.receive(reading(130), animated: true)
        model.receive(reading(150), animated: true)
        model.advance(elapsed: 5)
        XCTAssertTrue(model.isRolling)
        model.advance(elapsed: 5)
        XCTAssertFalse(model.isRolling)
        XCTAssertEqual(model.reading?.value, 150)
        model.receive(reading(200), animated: true)
        model.settle()
        XCTAssertFalse(model.isRolling)
        XCTAssertEqual(model.reading?.value, 200)
        XCTAssertEqual(model.positions.map { Int($0) % 10 }, [0, 0, 0, 2, 0, 0])
    }
    func testPreferencesPersistAndValidateStoredValues() {
        let name = "Tokenory-HUD-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = HUDPreferences(defaults: defaults)
        XCTAssertFalse(preferences.enabled)
        XCTAssertFalse(preferences.soundEnabled)
        XCTAssertEqual(preferences.volume, 0.35)
        preferences.enabled = true; preferences.soundEnabled = true; preferences.volume = 0.6; preferences.metric = .cost
        let restored = HUDPreferences(defaults: defaults)
        XCTAssertTrue(restored.enabled); XCTAssertTrue(restored.soundEnabled)
        XCTAssertEqual(restored.volume, 0.6); XCTAssertEqual(restored.metric, .cost)
        defaults.set(8, forKey: "hud.volume")
        XCTAssertEqual(HUDPreferences(defaults: defaults).volume, 1)
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
        preferences.enabled = false
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(controller.panel?.contentView)
        preferences.enabled = true
        try await Task.sleep(for: .milliseconds(50))
        let reopened = try XCTUnwrap(controller.panel?.contentView)
        XCTAssertTrue(String(reflecting: type(of: reopened)).contains("NSHostingView"))
    }
}
