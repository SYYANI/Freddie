import XCTest
@testable import ReadPaper

final class LanguageManagerTests: XCTestCase {
    func testSimplifiedChineseVariantsNormalizeToSupportedLanguage() {
        XCTAssertEqual(AppLocalization.normalizedSupportedLanguageCode(for: "zh-Hans"), "zh-Hans")
        XCTAssertEqual(AppLocalization.normalizedSupportedLanguageCode(for: "zh-Hans-CN"), "zh-Hans")
        XCTAssertEqual(AppLocalization.normalizedSupportedLanguageCode(for: "zh-CN"), "zh-Hans")
        XCTAssertEqual(AppLocalization.normalizedSupportedLanguageCode(for: "zh-SG"), "zh-Hans")
    }

    func testUnsupportedLocalesFallBackToEnglish() {
        XCTAssertEqual(AppLocalization.bestSupportedLanguageCode(for: ["zh-Hant", "en-US"]), "en")
        XCTAssertEqual(AppLocalization.bestSupportedLanguageCode(for: ["ja-JP", "fr-FR"]), "en")
    }

    @MainActor
    func testLanguageOverrideResolvesLocalizedBundleAndUpdatesAtRuntime() {
        let originalOverride = LanguageManager.shared.languageOverride
        defer { LanguageManager.shared.setLanguage(originalOverride) }

        LanguageManager.shared.setLanguage("zh-CN")
        XCTAssertEqual(String(localized: "General", bundle: LanguageManager.shared.bundle), "通用")

        LanguageManager.shared.setLanguage("en")
        XCTAssertEqual(String(localized: "General", bundle: LanguageManager.shared.bundle), "General")
    }
}
