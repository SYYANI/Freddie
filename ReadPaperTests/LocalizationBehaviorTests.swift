import XCTest
@testable import ReadPaper

final class LocalizationBehaviorTests: XCTestCase {
    @MainActor
    func testAppOwnedErrorsUseCurrentLanguageOverride() {
        let originalOverride = LanguageManager.shared.languageOverride
        defer { LanguageManager.shared.setLanguage(originalOverride) }

        LanguageManager.shared.setLanguage("zh-Hans")
        XCTAssertEqual(PaperImportError.missingPDF.localizedDescription, "这篇论文没有可用的 PDF 附件。")
        XCTAssertEqual(LLMProviderValidationError.emptyAPIKey.localizedDescription, "API key 不能为空。")

        LanguageManager.shared.setLanguage("en")
        XCTAssertEqual(PaperImportError.missingPDF.localizedDescription, "No PDF attachment is available for this paper.")
    }
}
