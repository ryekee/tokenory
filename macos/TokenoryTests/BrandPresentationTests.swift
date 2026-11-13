// [INPUT]: 使用 Tokenory 品牌映射、格式化函数和打包资源。
// [OUTPUT]: 验证展示文本和原生品牌资源。
// [POS]: 防止模型映射存在但资源缺失的展示回归。
// [PROTOCOL]: Update this header on change, then check AGENTS.md
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
        XCTAssertEqual(Brand.slug("devin-cli", kind: .tool), "devin")
        XCTAssertEqual(Brand.slug("devin-desktop", kind: .tool), "devin")
        XCTAssertEqual(Brand.slug("devin", kind: .provider), "devin")
        XCTAssertEqual(Brand.slug("swe-2-flash-medium", kind: .model), "devin")
        XCTAssertEqual(Brand.slug("swe-1.7", kind: .model), "windsurf")
        XCTAssertNil(Brand.slug("unknown", kind: .model))
        XCTAssertNil(Brand.slug("custom-local-model", kind: .model))
    }
    func testToolsDoNotBorrowModelFamilyIcons() {
        XCTAssertEqual(Brand.slug("hermes", kind: .tool), "hermesagent")
        XCTAssertEqual(Brand.slug("hermes-3", kind: .model), "nousresearch")
        XCTAssertEqual(Brand.slug("gemini", kind: .tool), "geminicli")
        XCTAssertEqual(Brand.slug("gemini-3-pro", kind: .model), "gemini")
        XCTAssertEqual(Brand.slug("kilocode", kind: .tool), "kilocode")
        XCTAssertNil(Brand.slug("kilo", kind: .tool))
        XCTAssertNotNil(Brand.toolSymbols["kilo"])
    }
    @MainActor func testEveryToolAssetLoadsAndHasNativeMenuSize() {
        for slug in Set(Brand.toolSlugs.values) {
            let image = NSImage(named: "Brand-" + slug)
            XCTAssertNotNil(image, slug)
            XCTAssertLessThanOrEqual(image?.size.width ?? 100, 14, slug)
            XCTAssertLessThanOrEqual(image?.size.height ?? 100, 14, slug)
        }
    }
    @MainActor func testPrimaryNativeBrandAssetsLoad() {
        for name in ["openai", "claude", "gemini", "deepseek", "githubcopilot", "cline", "xiaomimimo", "devin"] {
            let image = NSImage(named: "Brand-" + name)
            XCTAssertNotNil(image, name)
            XCTAssertEqual(image?.size, NSSize(width: 14, height: 14), "Native picker image: " + name)
        }
    }
    @MainActor func testFullProviderCatalogHasNamesAndBundledIcons() {
        XCTAssertGreaterThan(ProviderBrand.all.count, 200)
        XCTAssertEqual(ProviderBrand.all["xiaomi"]?.name, "Xiaomi MiMo")
        XCTAssertEqual(Brand.slug("xiaomi", kind: .provider), "provider-xiaomi")
        XCTAssertEqual(Brand.slug("mimo-v2.6-flash", kind: .model), "provider-xiaomi")
        for (id, brand) in ProviderBrand.all {
            XCTAssertFalse(brand.name.isEmpty, id)
            XCTAssertNotNil(NSImage(named: "Brand-" + brand.icon), id)
        }
    }

}
