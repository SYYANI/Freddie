import PDFKit
import SwiftUI
import XCTest
@testable import ReadPaper

final class PDFMergerTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    // MARK: - Helper Methods

    private func createPDFDocument(withPageCount pageCount: Int) -> PDFDocument {
        let document = PDFDocument()
        for i in 0..<pageCount {
            let page = PDFPage(image: createTestImage(withText: "Page \(i + 1)"))!
            document.insert(page, at: i)
        }
        return document
    }

    private func createTestImage(withText text: String) -> NSImage {
        let size = NSSize(width: 200, height: 100)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.black
        ]
        text.draw(at: NSPoint(x: 10, y: 40), withAttributes: attributes)
        image.unlockFocus()
        return image
    }

    private func savePDFDocument(_ document: PDFDocument, to url: URL) throws {
        guard document.write(to: url) else {
            throw NSError(domain: "PDFMergerTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to write PDF"])
        }
    }

    // MARK: - Tests

    func testMergeWithPDFDocumentParameter() throws {
        // Create existing PDF with 3 pages
        let existingDoc = createPDFDocument(withPageCount: 3)

        // Create increment PDF file with 2 pages
        let incrementDoc = createPDFDocument(withPageCount: 2)
        let incrementURL = tempDirectory.appendingPathComponent("increment.pdf")
        try savePDFDocument(incrementDoc, to: incrementURL)

        // Merge
        let outputURL = tempDirectory.appendingPathComponent("merged.pdf")
        let resultURL = try PDFMerger.merge(existing: existingDoc, increment: incrementURL, output: outputURL)

        // Verify
        XCTAssertEqual(resultURL, outputURL)
        let mergedDoc = PDFDocument(url: resultURL)
        XCTAssertNotNil(mergedDoc)
        XCTAssertEqual(mergedDoc?.pageCount, 5)
    }

    func testMergeWithURLParameter() throws {
        // Create existing PDF file with 4 pages
        let existingDoc = createPDFDocument(withPageCount: 4)
        let existingURL = tempDirectory.appendingPathComponent("existing.pdf")
        try savePDFDocument(existingDoc, to: existingURL)

        // Create increment PDF file with 3 pages
        let incrementDoc = createPDFDocument(withPageCount: 3)
        let incrementURL = tempDirectory.appendingPathComponent("increment.pdf")
        try savePDFDocument(incrementDoc, to: incrementURL)

        // Merge
        let outputURL = tempDirectory.appendingPathComponent("merged.pdf")
        let resultURL = try PDFMerger.merge(existing: existingURL, increment: incrementURL, output: outputURL)

        // Verify
        XCTAssertEqual(resultURL, outputURL)
        let mergedDoc = PDFDocument(url: resultURL)
        XCTAssertNotNil(mergedDoc)
        XCTAssertEqual(mergedDoc?.pageCount, 7)
    }

    func testMergeInBackgroundWithURLParameters() async throws {
        let existingDoc = createPDFDocument(withPageCount: 4)
        let existingURL = tempDirectory.appendingPathComponent("existing-background.pdf")
        try savePDFDocument(existingDoc, to: existingURL)

        let incrementDoc = createPDFDocument(withPageCount: 3)
        let incrementURL = tempDirectory.appendingPathComponent("increment-background.pdf")
        try savePDFDocument(incrementDoc, to: incrementURL)

        let outputURL = tempDirectory.appendingPathComponent("merged-background.pdf")
        let resultURL = try await PDFMerger.mergeInBackground(
            existing: existingURL,
            increment: incrementURL,
            output: outputURL
        )

        XCTAssertEqual(resultURL, outputURL)
        XCTAssertEqual(PDFDocument(url: resultURL)?.pageCount, 7)
    }

    func testMergeWithEmptyExistingDocument() throws {
        // Create empty existing PDF
        let existingDoc = PDFDocument()

        // Create increment PDF with 2 pages
        let incrementDoc = createPDFDocument(withPageCount: 2)
        let incrementURL = tempDirectory.appendingPathComponent("increment.pdf")
        try savePDFDocument(incrementDoc, to: incrementURL)

        // Merge
        let outputURL = tempDirectory.appendingPathComponent("merged.pdf")
        let resultURL = try PDFMerger.merge(existing: existingDoc, increment: incrementURL, output: outputURL)

        // Verify only increment pages exist
        let mergedDoc = PDFDocument(url: resultURL)
        XCTAssertNotNil(mergedDoc)
        XCTAssertEqual(mergedDoc?.pageCount, 2)
    }

    func testMergeWithEmptyIncrementDocument() throws {
        // Create existing PDF with 3 pages
        let existingDoc = createPDFDocument(withPageCount: 3)

        // Create empty increment PDF
        let incrementDoc = PDFDocument()
        let incrementURL = tempDirectory.appendingPathComponent("increment.pdf")
        try savePDFDocument(incrementDoc, to: incrementURL)

        // Merge
        let outputURL = tempDirectory.appendingPathComponent("merged.pdf")
        let resultURL = try PDFMerger.merge(existing: existingDoc, increment: incrementURL, output: outputURL)

        // Verify only existing pages exist (empty PDF may still have a placeholder page)
        let mergedDoc = PDFDocument(url: resultURL)
        XCTAssertNotNil(mergedDoc)
        // Empty PDF may be saved with 1 page or 0 pages depending on PDFKit implementation
        // The important thing is the existing pages are preserved
        XCTAssertGreaterThanOrEqual(mergedDoc?.pageCount ?? 0, 3)
    }

    func testMergeFailsWithNonExistentIncrementFile() throws {
        // Create existing PDF
        let existingDoc = createPDFDocument(withPageCount: 3)

        // Use non-existent increment URL
        let nonExistentURL = tempDirectory.appendingPathComponent("nonexistent.pdf")

        // Merge should throw
        let outputURL = tempDirectory.appendingPathComponent("merged.pdf")
        XCTAssertThrowsError(try PDFMerger.merge(existing: existingDoc, increment: nonExistentURL, output: outputURL)) { error in
            guard case PDFMergerError.failedToOpenFile(let path) = error else {
                XCTFail("Expected PDFMergerError.failedToOpenFile, got \(error)")
                return
            }
            XCTAssertEqual(path, nonExistentURL.path)
        }
    }

    func testMergeFailsWithNonExistentExistingFile() throws {
        // Use non-existent existing URL
        let nonExistentURL = tempDirectory.appendingPathComponent("nonexistent.pdf")

        // Create increment PDF
        let incrementDoc = createPDFDocument(withPageCount: 2)
        let incrementURL = tempDirectory.appendingPathComponent("increment.pdf")
        try savePDFDocument(incrementDoc, to: incrementURL)

        // Merge should throw
        let outputURL = tempDirectory.appendingPathComponent("merged.pdf")
        XCTAssertThrowsError(try PDFMerger.merge(existing: nonExistentURL, increment: incrementURL, output: outputURL)) { error in
            guard case PDFMergerError.failedToOpenFile(let path) = error else {
                XCTFail("Expected PDFMergerError.failedToOpenFile, got \(error)")
                return
            }
            XCTAssertEqual(path, nonExistentURL.path)
        }
    }

    func testMergeErrorLocalizedDescription() {
        let openError = PDFMergerError.failedToOpenFile("/path/to/file.pdf")
        XCTAssertNotNil(openError.errorDescription)
        XCTAssertTrue(openError.errorDescription?.contains("file.pdf") ?? false)

        let writeError = PDFMergerError.failedToWriteOutput("/path/to/output.pdf")
        XCTAssertNotNil(writeError.errorDescription)
        XCTAssertTrue(writeError.errorDescription?.contains("output.pdf") ?? false)
    }

    func testTranslatedPDFPageBoundsNormalizerRemovesNonZeroCropOrigin() throws {
        let document = createPDFDocument(withPageCount: 1)
        let page = try XCTUnwrap(document.page(at: 0))
        page.setBounds(CGRect(x: 0, y: 0, width: 200, height: 100), for: .mediaBox)
        page.setBounds(CGRect(x: 20, y: 10, width: 160, height: 80), for: .cropBox)
        page.setBounds(CGRect(x: 20, y: 10, width: 160, height: 80), for: .bleedBox)
        page.setBounds(CGRect(x: 20, y: 10, width: 160, height: 80), for: .trimBox)
        page.setBounds(CGRect(x: 20, y: 10, width: 160, height: 80), for: .artBox)
        let url = tempDirectory.appendingPathComponent("translated-with-crop-offset.pdf")
        try savePDFDocument(document, to: url)

        XCTAssertTrue(try TranslatedPDFPageBoundsNormalizer.normalize(at: url))

        let normalized = try XCTUnwrap(PDFDocument(url: url))
        let normalizedPage = try XCTUnwrap(normalized.page(at: 0))
        let expected = CGRect(x: 0, y: 0, width: 160, height: 80)
        for displayBox in [
            PDFDisplayBox.mediaBox,
            .cropBox,
            .bleedBox,
            .trimBox,
            .artBox,
        ] {
            XCTAssertEqual(normalizedPage.bounds(for: displayBox), expected)
        }
    }

    func testTranslatedPDFPageBoundsNormalizerLeavesZeroOriginPageUntouched() throws {
        let document = createPDFDocument(withPageCount: 1)
        let page = try XCTUnwrap(document.page(at: 0))
        let expected = CGRect(x: 0, y: 0, width: 160, height: 80)
        page.setBounds(expected, for: .mediaBox)
        page.setBounds(expected, for: .cropBox)
        let url = tempDirectory.appendingPathComponent("translated-with-zero-origin.pdf")
        try savePDFDocument(document, to: url)
        let dataBeforeNormalization = try Data(contentsOf: url)

        XCTAssertFalse(try TranslatedPDFPageBoundsNormalizer.normalize(at: url))
        XCTAssertEqual(try Data(contentsOf: url), dataBeforeNormalization)
    }

    @MainActor
    func testPDFReaderCoordinatorIgnoresTransientFirstPageDuringProgrammaticRestore() throws {
        let document = createPDFDocument(withPageCount: 20)
        let pdfView = PDFView()
        pdfView.document = document

        var pageIndex = 9
        let coordinator = PDFReaderView.Coordinator(
            attachmentID: nil,
            pageIndex: Binding(
                get: { pageIndex },
                set: { pageIndex = $0 }
            ),
            onNoteSelectionChanged: nil
        )
        coordinator.attach(to: pdfView)
        coordinator.prepareForProgrammaticPageRestore(to: PDFReadingPosition(pageIndex: pageIndex))

        guard let firstPage = document.page(at: 0),
              let restoredPage = document.page(at: 9),
              let nextPage = document.page(at: 10)
        else {
            return XCTFail("Expected test PDF pages to exist")
        }

        pdfView.go(to: firstPage)
        coordinator.updateCurrentPageIndexIfNeeded()
        XCTAssertEqual(pageIndex, 9)

        pdfView.go(to: restoredPage)
        coordinator.updateCurrentPageIndexIfNeeded()
        XCTAssertEqual(pageIndex, 9)

        pdfView.go(to: nextPage)
        coordinator.updateCurrentPageIndexIfNeeded()
        XCTAssertEqual(pageIndex, 10)
    }

    @MainActor
    func testPDFReaderCoordinatorCapturesDestinationPointForReloadRestore() throws {
        let document = createPDFDocument(withPageCount: 20)
        let pdfView = PDFView(frame: NSRect(x: 0, y: 0, width: 600, height: 800))
        pdfView.document = document

        var pageIndex = 0
        let coordinator = PDFReaderView.Coordinator(
            attachmentID: nil,
            pageIndex: Binding(
                get: { pageIndex },
                set: { pageIndex = $0 }
            ),
            onNoteSelectionChanged: nil
        )
        coordinator.attach(to: pdfView)

        guard let page = document.page(at: 9) else {
            return XCTFail("Expected test PDF page to exist")
        }

        let point = CGPoint(x: 24, y: 36)
        pdfView.go(to: PDFDestination(page: page, at: point))
        let position = coordinator.readingPosition(fallbackPageIndex: 0, in: pdfView)

        XCTAssertEqual(position.pageIndex, 9)
        XCTAssertNotNil(position.point)
    }

    func testDualPDFPageSyncClampsTranslatedPageWithoutProducingInvalidOriginalPage() {
        let translatedTarget = DualPDFPageIndexSync.translatedPageIndex(
            forOriginalPageIndex: 14,
            translatedPageCount: 10
        )

        XCTAssertEqual(translatedTarget, 9)
        XCTAssertEqual(DualPDFPageIndexSync.originalPageIndex(
            forTranslatedPageIndex: 8,
            translatedPageCount: 10
        ), 8)
        XCTAssertNil(DualPDFPageIndexSync.originalPageIndex(
            forTranslatedPageIndex: 10,
            translatedPageCount: 10
        ))
    }

    @MainActor
    func testTranslatedPDFCoordinatorDoesNotPushPartialClampBackToOriginalBinding() throws {
        let document = createPDFDocument(withPageCount: 10)
        let pdfView = PDFView()
        pdfView.document = document

        var originalPageIndex = 14
        var originalBindingWriteCount = 0
        let translatedPageCount = 10
        let translatedPageBinding = Binding(
            get: {
                DualPDFPageIndexSync.translatedPageIndex(
                    forOriginalPageIndex: originalPageIndex,
                    translatedPageCount: translatedPageCount
                )
            },
            set: { translatedPageIndex in
                if let target = DualPDFPageIndexSync.originalPageIndex(
                    forTranslatedPageIndex: translatedPageIndex,
                    translatedPageCount: translatedPageCount
                ) {
                    originalBindingWriteCount += 1
                    originalPageIndex = target
                }
            }
        )
        let coordinator = PDFReaderView.Coordinator(
            attachmentID: nil,
            pageIndex: translatedPageBinding,
            onNoteSelectionChanged: nil
        )
        coordinator.attach(to: pdfView)

        let clampedPageIndex = translatedPageBinding.wrappedValue
        coordinator.prepareForProgrammaticPageRestore(
            to: PDFReadingPosition(pageIndex: clampedPageIndex)
        )
        pdfView.go(to: try XCTUnwrap(document.page(at: clampedPageIndex)))
        coordinator.updateCurrentPageIndexIfNeeded()

        XCTAssertEqual(originalPageIndex, 14)
        XCTAssertEqual(originalBindingWriteCount, 0)

        pdfView.go(to: try XCTUnwrap(document.page(at: 8)))
        coordinator.updateCurrentPageIndexIfNeeded()
        XCTAssertEqual(originalPageIndex, 8)
        XCTAssertEqual(originalBindingWriteCount, 1)
    }

    @MainActor
    func testPDFReaderCoordinatorCoalescesDocumentPageCountCallbacks() async {
        var publishedPageCounts: [Int] = []
        let callbackExpectation = expectation(description: "Publishes the latest page count")
        let coordinator = PDFReaderView.Coordinator(
            attachmentID: nil,
            pageIndex: .constant(0),
            onNoteSelectionChanged: nil
        )
        coordinator.onDocumentPageCountChanged = {
            publishedPageCounts.append($0)
            callbackExpectation.fulfill()
        }

        coordinator.scheduleDocumentPageCountUpdate(4)
        coordinator.scheduleDocumentPageCountUpdate(12)
        await fulfillment(of: [callbackExpectation], timeout: 1)

        XCTAssertEqual(publishedPageCounts, [12])

        coordinator.scheduleDocumentPageCountUpdate(12)
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(publishedPageCounts, [12])
    }

    @MainActor
    func testPDFReaderCoordinatorRestoresOnlyWhenRequestedPageDiffers() throws {
        let document = createPDFDocument(withPageCount: 10)
        let pdfView = PDFView()
        pdfView.document = document
        pdfView.go(to: try XCTUnwrap(document.page(at: 4)))

        let coordinator = PDFReaderView.Coordinator(
            attachmentID: nil,
            pageIndex: .constant(4),
            onNoteSelectionChanged: nil
        )

        XCTAssertFalse(coordinator.shouldRestorePageIndex(4, in: pdfView))
        XCTAssertTrue(coordinator.shouldRestorePageIndex(5, in: pdfView))

        pdfView.go(to: try XCTUnwrap(document.page(at: 9)))
        XCTAssertFalse(coordinator.shouldRestorePageIndex(99, in: pdfView))
    }

    func testPDFTranslationCoverageRequiresExplicitPartialPageMetadata() {
        XCTAssertFalse(PDFTranslationCoverage.isPartial(
            translatedLastPage: nil,
            originalPageCount: 12
        ))
        XCTAssertTrue(PDFTranslationCoverage.isPartial(
            translatedLastPage: 8,
            originalPageCount: 12
        ))
        XCTAssertFalse(PDFTranslationCoverage.isPartial(
            translatedLastPage: 12,
            originalPageCount: 12
        ))
    }

    func testDualPDFSplitLayoutKeepsBothPanesUsable() {
        let totalWidth: CGFloat = 1_000

        XCTAssertEqual(
            DualPDFSplitLayout.leadingWidth(totalWidth: totalWidth, fraction: 0.5),
            (totalWidth - DualPDFSplitLayout.dividerWidth) / 2,
            accuracy: 0.001
        )

        let draggedAllTheWayLeft = DualPDFSplitLayout.fraction(
            afterDraggingBy: -2_000,
            totalWidth: totalWidth,
            currentFraction: 0.5
        )
        let draggedAllTheWayRight = DualPDFSplitLayout.fraction(
            afterDraggingBy: 2_000,
            totalWidth: totalWidth,
            currentFraction: 0.5
        )

        XCTAssertEqual(
            DualPDFSplitLayout.leadingWidth(totalWidth: totalWidth, fraction: draggedAllTheWayLeft),
            DualPDFSplitLayout.minimumPaneWidth,
            accuracy: 0.001
        )
        XCTAssertEqual(
            totalWidth - DualPDFSplitLayout.dividerWidth
                - DualPDFSplitLayout.leadingWidth(totalWidth: totalWidth, fraction: draggedAllTheWayRight),
            DualPDFSplitLayout.minimumPaneWidth,
            accuracy: 0.001
        )
    }

    func testDualPDFSplitDragUpdatesAreLimitedToDisplayCadence() {
        XCTAssertTrue(DualPDFSplitLayout.shouldEmitDragUpdate(
            lastTimestamp: nil,
            currentTimestamp: 1
        ))
        XCTAssertFalse(DualPDFSplitLayout.shouldEmitDragUpdate(
            lastTimestamp: 1,
            currentTimestamp: 1 + (1.0 / 120.0)
        ))
        XCTAssertTrue(DualPDFSplitLayout.shouldEmitDragUpdate(
            lastTimestamp: 1,
            currentTimestamp: 1 + (1.0 / 60.0)
        ))
    }

    func testAutomaticScalingRestoresOnlyWhenCurrentScaleIsNearFit() {
        XCTAssertTrue(PDFAutomaticScalingPolicy.shouldRestore(
            currentScale: 0.55,
            fittedScale: 0.5
        ))
        XCTAssertFalse(PDFAutomaticScalingPolicy.shouldRestore(
            currentScale: 0.7,
            fittedScale: 0.5
        ))
        XCTAssertFalse(PDFAutomaticScalingPolicy.shouldRestore(
            currentScale: 1,
            fittedScale: 0
        ))
    }

    func testPDFDisplayAppearanceOnlyCompositesWhenAnOverlayNeedsBlending() {
        XCTAssertFalse(PDFDisplayAppearance.defaultMode.requiresOverlayCompositing)
        #if os(macOS)
        XCTAssertFalse(PDFDisplayAppearance.paper.requiresOverlayCompositing)
        XCTAssertFalse(PDFDisplayAppearance.defaultMode.usesNativeContentFilter)
        XCTAssertTrue(PDFDisplayAppearance.paper.usesNativeContentFilter)
        #else
        XCTAssertTrue(PDFDisplayAppearance.paper.requiresOverlayCompositing)
        #endif
    }

    @MainActor
    func testPDFDisplayAppearanceUsesNativeMacOSContentFilters() {
        let pdfView = PDFView()
        let coordinator = PDFReaderView.Coordinator(
            attachmentID: nil,
            pageIndex: .constant(0),
            onNoteSelectionChanged: nil
        )

        coordinator.applyDisplayAppearance(.paper, to: pdfView)
        XCTAssertEqual(pdfView.contentFilters.first?.name, "CIColorMatrix")

        coordinator.applyDisplayAppearance(.defaultMode, to: pdfView)
        XCTAssertTrue(pdfView.contentFilters.isEmpty)
    }

    func testDualPDFSelectionOwnershipClearsPreviousSideWhenSelectionSwitches() {
        var ownership = DualPDFSelectionOwnership()

        XCTAssertNil(ownership.activate(.original))
        XCTAssertEqual(ownership.activeSource, .original)
        XCTAssertNil(ownership.activate(.original))

        XCTAssertEqual(ownership.activate(.translated), .original)
        XCTAssertEqual(ownership.activeSource, .translated)

        XCTAssertFalse(ownership.clear(.original))
        XCTAssertEqual(ownership.activeSource, .translated)
        XCTAssertTrue(ownership.clear(.translated))
        XCTAssertNil(ownership.activeSource)
    }
}
