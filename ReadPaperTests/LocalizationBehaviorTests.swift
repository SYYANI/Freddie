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
        XCTAssertEqual(
            AppLocalization.localized("Use arXiv LaTeX structure for PDF translation"),
            "使用 arXiv LaTeX 结构改进 PDF 翻译"
        )
        XCTAssertEqual(AppLocalization.localized("PDF Annotations"), "PDF 标注")
        XCTAssertEqual(AppLocalization.localized("Retranslate PDF"), "重新翻译 PDF")
        XCTAssertEqual(
            PDFAnnotationStoreError.sourceAndDestinationMatch.localizedDescription,
            "请选择其他位置，以保留原始 PDF。"
        )

        LanguageManager.shared.setLanguage("en")
        XCTAssertEqual(PaperImportError.missingPDF.localizedDescription, "No PDF attachment is available for this paper.")
        XCTAssertEqual(AppLocalization.localized("PDF Annotations"), "PDF Annotations")
        XCTAssertEqual(AppLocalization.localized("Retranslate PDF"), "Retranslate PDF")
    }
}
