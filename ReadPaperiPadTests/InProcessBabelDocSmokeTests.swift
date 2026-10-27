import BabelDocKit
import PDFKit
import SwiftUI
import UIKit
import XCTest
@testable import ReadPaperiPad

final class InProcessBabelDocSmokeTests: XCTestCase {
    func testPDFProgressShowsPercentageAndKeepsLocalizedStageInDetail() {
        let originalOverride = AppLocalization.currentLanguageOverride()
        defer { AppLocalization.setLanguageOverride(originalOverride) }

        for (language, stage) in [("zh-Hans", "正在翻译文本块"), ("en", "Translating text blocks")] {
            AppLocalization.setLanguageOverride(language)
            let update = InProcessBabelDocRunner.progressUpdate(.init(
                stage: .translation, completed: 13, total: 21, overallPercentage: 62.4
            ))

            XCTAssertEqual(update.summary, "62%")
            XCTAssertEqual(update.statusMessage, "\(stage) 13/21")
            XCTAssertEqual(update.completed, 62.4)
            XCTAssertEqual(update.total, 100)
        }
    }

    func testPDFProgressWithoutStageTotalStillShowsClampedOverallPercentage() {
        for (percentage, expected) in [(-5.0, "0%"), (62.8, "63%"), (105.0, "100%")] {
            let update = InProcessBabelDocRunner.progressUpdate(.init(
                stage: .frontend, completed: 0, total: 0, overallPercentage: percentage
            ))

            XCTAssertEqual(update.summary, expected)
            XCTAssertFalse(update.statusMessage.contains("0/0"))
        }
    }

    func testPDFDiagnosticDetailDoesNotReplacePercentageSummary() {
        let update = InProcessBabelDocRunner.diagnosticProgressUpdate(.init(
            outputPDF: URL(fileURLWithPath: "/tmp/translated.pdf"),
            translationAttemptCount: 21,
            translationSuccessCount: 21
        ))

        XCTAssertEqual(update.summary, "100%")
        XCTAssertEqual(update.completed, update.total)
        XCTAssertFalse(update.statusMessage.isEmpty)
        XCTAssertNotEqual(update.statusMessage, update.summary)
    }

    @MainActor
    func testReopeningPartialTranslationRestoresTranslatedPageWithoutMovingOriginal() throws {
        let savedState = ReadingState(paperID: UUID(), readerMode: .bilingualPDF, pageIndex: 24)
        let document = PDFDocument()
        let pageImage = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        }
        for index in 0..<10 {
            document.insert(try XCTUnwrap(PDFPage(image: pageImage)), at: index)
        }
        let translatedTarget = DualPDFPageIndexSync.translatedPageIndex(
            forOriginalPageIndex: savedState.pageIndex,
            translatedPageCount: document.pageCount
        )
        var pendingTargets: Set<Int> = [translatedTarget]
        let pageBinding = Binding<Int>(
            get: { translatedTarget },
            set: { page in
                if let original = DualPDFPageIndexSync.originalPageIndex(
                    forTranslatedPageIndex: page,
                    translatedPageCount: document.pageCount,
                    pendingProgrammaticTargets: &pendingTargets
                ) {
                    savedState.pageIndex = original
                }
            }
        )
        let view = PDFView()
        view.document = document
        let coordinator = PDFReaderView.Coordinator(
            attachmentID: nil,
            pageIndex: pageBinding,
            onNoteSelectionChanged: nil
        )
        coordinator.attach(to: view)
        coordinator.prepareForProgrammaticPageRestore(to: PDFReadingPosition(pageIndex: translatedTarget))
        view.go(to: try XCTUnwrap(document.page(at: translatedTarget)))
        coordinator.updateCurrentPageIndexIfNeeded()

        XCTAssertEqual(document.index(for: try XCTUnwrap(view.currentPage)), 9)
        XCTAssertEqual(savedState.pageIndex, 24)
    }

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
