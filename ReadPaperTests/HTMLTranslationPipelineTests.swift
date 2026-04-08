import XCTest
@testable import ReadPaper

final class HTMLTranslationPipelineTests: XCTestCase {
    @MainActor
    func testExtractsSegmentsAndProtectsMathAndCitations() throws {
        let html = """
        <html><body>
        <p>We show that <math><mi>x</mi></math> improves the baseline <cite>[1]</cite> in a controlled setting.</p>
        <p class="rp-translation-block" data-rp-translation="true">Already translated.</p>
        </body></html>
        """
        let candidates = try HTMLTranslationPipeline.extractCandidates(from: html)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertTrue(candidates[0].sourceText.contains("[PROTECTED_0]"))
        XCTAssertTrue(candidates[0].sourceText.contains("[PROTECTED_1]"))
        XCTAssertEqual(candidates[0].protectedFragments.count, 2)
    }

    @MainActor
    func testAppliesTranslationBlocks() throws {
        let html = "<html><body><p>This is a long enough paragraph for translation.</p></body></html>"
        let prepared = try HTMLTranslationPipeline.prepareDocument(html)
        let output = try HTMLTranslationPipeline.applyTranslations(
            toPreparedHTML: prepared.preparedHTML,
            candidates: prepared.candidates,
            translations: [prepared.candidates[0].segmentID: "Translated paragraph."]
        )
        XCTAssertTrue(output.contains("rp-translation-block"))
        XCTAssertTrue(output.contains("Translated paragraph."))
    }
}
