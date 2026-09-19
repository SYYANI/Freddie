import BabelDocKit
import PDFKit
import UIKit
import XCTest
@testable import ReadPaperiPad

final class InProcessBabelDocSmokeTests: XCTestCase {
    func testPartialTranslationProgrammaticClampDoesNotOverwriteOriginalPage() {
        let originalPage = 24
        let translatedPage = DualPDFPageIndexSync.translatedPageIndex(
            forOriginalPageIndex: originalPage,
            translatedPageCount: 10
        )
        var pendingTargets: Set<Int> = [translatedPage]

        let propagated = DualPDFPageIndexSync.originalPageIndex(
            forTranslatedPageIndex: translatedPage,
            translatedPageCount: 10,
            pendingProgrammaticTargets: &pendingTargets
        )

        XCTAssertEqual(translatedPage, 9)
        XCTAssertNil(propagated)
        XCTAssertEqual(originalPage, 24)
    }

    func testPartialTranslationUserPageChangePropagatesToOriginalPage() {
        var pendingTargets: Set<Int> = []

        let propagated = DualPDFPageIndexSync.originalPageIndex(
            forTranslatedPageIndex: 6,
            translatedPageCount: 10,
            pendingProgrammaticTargets: &pendingTargets
        )

        XCTAssertEqual(propagated, 6)
    }

    @MainActor
    func testEmbeddedRuntimeTranslatesOnePagePDFInProcess() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("babeldoc-ios-smoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let input = temporaryDirectory.appendingPathComponent("input.pdf")
        let output = temporaryDirectory.appendingPathComponent("translated.pdf")
        try makeInputPDF(at: input)

        let runtime = try InProcessBabelDocRunner().embeddedRuntimeAssets()
        _ = try await BabelDoc.translate(
            request: BabelDocTranslationRequest(
                inputPDF: input,
                outputPDF: output,
                pages: [1],
                targetLanguage: "zh-CN",
                onlyIncludeTranslatedPages: true
            ),
            runtime: runtime,
            translator: DeterministicTranslator()
        )

        let document = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(document.pageCount, 1)
        XCTAssertGreaterThan(try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0, 0)
    }

    @MainActor
    private func makeInputPDF(at url: URL) throws {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        try renderer.writePDF(to: url) { context in
            context.beginPage()
            let text = "Local PDF translation smoke test. This paragraph verifies the embedded BabelDocSwift pipeline."
            text.draw(
                in: CGRect(x: 72, y: 96, width: 468, height: 160),
                withAttributes: [
                    .font: UIFont.systemFont(ofSize: 18),
                    .foregroundColor: UIColor.black,
                ]
            )
        }
    }
}

private struct DeterministicTranslator: BabelDocTextTranslator {
    func translate(_ text: String) async throws -> String {
        "本地译文：\(text)"
    }
}
