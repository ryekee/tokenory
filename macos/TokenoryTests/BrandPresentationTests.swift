import AppKit
import XCTest
@testable import Tokenory

final class BrandPresentationTests: XCTestCase {
    func testCompactTokensUseGroupingAndTwoDecimalRounding() {
        XCTAssertEqual(compactTokens(17_406_900, locale: Locale(identifier: "zh-Hans")), "1,740.69万")
        XCTAssertEqual(compactTokens(17_406_999, locale: Locale(identifier: "zh-Hans")), "1,740.7万")
        XCTAssertEqual(compactTokens(17_406_900, locale: Locale(identifier: "en")), "17.41M")
        XCTAssertEqual(compactTokens(1740, locale: Locale(identifier: "zh-Hans")), "1,740")
    }
    func testCurrencyUsesDollarSignAndTwoDecimalPlaces() {
        XCTAssertEqual(usd(1740.696), "$1,740.70")
        XCTAssertEqual(usd(0.006), "$0.01")
        XCTAssertEqual(usd(0), "$0.00")
        XCTAssertEqual(usd(nil), L("cost.unavailable"))
    }
    func testBrandsResolveToolsModelsAndGatewayOverrides() {
        XCTAssertEqual(Brand.slug("copilot", kind: .tool), "githubcopilot")
        XCTAssertEqual(Brand.slug("google", kind: .provider), "gemini")
        XCTAssertEqual(Brand.slug("anthropic/claude-opus-5", kind: .model), "claude")
        XCTAssertEqual(Brand.slug("accounts/fireworks/routers/kimi-k2", kind: .model), "fireworks")
        XCTAssertEqual(Brand.slug("deepseek-v4-flash", kind: .model), "deepseek")
        XCTAssertNil(Brand.slug("unknown", kind: .model))
        XCTAssertNil(Brand.slug("custom-local-model", kind: .model))
    }
    @MainActor func testPrimaryNativeBrandAssetsLoad() {
        for name in ["openai", "claude", "gemini", "deepseek", "githubcopilot", "cline", "xiaomimimo"] {
            let image = NSImage(named: "Brand-" + name)
            XCTAssertNotNil(image, name)
            XCTAssertEqual(image?.size, NSSize(width: 14, height: 14), "Native picker image: " + name)
        }
    }
}
