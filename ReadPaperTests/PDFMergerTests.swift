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
    func testReopeningPartialTranslationRestoresAvailablePageInsteadOfFirstPage() throws {
        let savedState = ReadingState(paperID: UUID(), readerMode: .bilingualPDF, pageIndex: 14)
        let translatedDocument = createPDFDocument(withPageCount: 10)
        let pdfView = PDFView()
        pdfView.document = translatedDocument
        let target = DualPDFPageIndexSync.translatedPageIndex(
            forOriginalPageIndex: savedState.pageIndex,
            translatedPageCount: translatedDocument.pageCount
        )
        let coordinator = PDFReaderView.Coordinator(
            attachmentID: nil,
            pageIndex: .constant(target),
            onNoteSelectionChanged: nil
        )
        coordinator.attach(to: pdfView)
        coordinator.prepareForProgrammaticPageRestore(to: PDFReadingPosition(pageIndex: target))
        pdfView.go(to: try XCTUnwrap(translatedDocument.page(at: target)))
        coordinator.updateCurrentPageIndexIfNeeded()

        XCTAssertEqual(translatedDocument.index(for: try XCTUnwrap(pdfView.currentPage)), 9)
        XCTAssertEqual(savedState.pageIndex, 14)
    }

    @MainActor
    func testReopeningPartialTranslationPreservesSavedOriginalPageBeyondTranslatedPages() throws {
        let savedState = ReadingState(paperID: UUID(), readerMode: .bilingualPDF, pageIndex: 14)
        let originalDocument = createPDFDocument(withPageCount: 20)
        let originalView = PDFView()
        originalView.document = originalDocument
        let coordinator = PDFReaderView.Coordinator(
            attachmentID: nil,
            pageIndex: Binding(
                get: { savedState.pageIndex },
                set: { savedState.pageIndex = $0 }
            ),
            onNoteSelectionChanged: nil
        )
        coordinator.attach(to: originalView)
        coordinator.prepareForProgrammaticPageRestore(to: PDFReadingPosition(pageIndex: savedState.pageIndex))
        originalView.go(to: try XCTUnwrap(originalDocument.page(at: savedState.pageIndex)))
        coordinator.updateCurrentPageIndexIfNeeded()

        XCTAssertEqual(originalDocument.index(for: try XCTUnwrap(originalView.currentPage)), 14)
        XCTAssertEqual(DualPDFPageIndexSync.translatedPageIndex(
            forOriginalPageIndex: savedState.pageIndex,
            translatedPageCount: 10
        ), 9)
        XCTAssertEqual(savedState.pageIndex, 14)

        // An image-only original remains navigable beyond a partial translation,
        // even though ordinary PDF translation is unavailable for scanned pages.
        let originalURL = tempDirectory.appendingPathComponent("scanned-original.pdf")
        XCTAssertTrue(originalDocument.write(to: originalURL))
        XCTAssertEqual(PDFTextLayerInspector().inspect(documentAt: originalURL), .noFonts)
        originalView.go(to: try XCTUnwrap(originalDocument.page(at: 19)))
        coordinator.updateCurrentPageIndexIfNeeded()
        XCTAssertEqual(savedState.pageIndex, 19)
        XCTAssertEqual(DualPDFPageIndexSync.translatedPageIndex(
            forOriginalPageIndex: savedState.pageIndex,
            translatedPageCount: 10
        ), 9)
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
    private func makeScrollSyncPane(pageCount: Int, width: CGFloat) -> (NSWindow, PDFView) {
        let document = PDFDocument()
        for index in 0..<pageCount {
            let image = NSImage(size: NSSize(width: 300, height: 400))
            image.lockFocus()
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: 300, height: 400).fill()
            image.unlockFocus()
            document.insert(PDFPage(image: image)!, at: index)
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 500),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let pdfView = PDFView(frame: NSRect(x: 0, y: 0, width: width, height: 500))
        pdfView.displayMode = .singlePageContinuous
        pdfView.displaysPageBreaks = true
        pdfView.autoScales = true
        window.contentView = pdfView
        pdfView.document = document
        pdfView.layoutDocumentView()
        return (window, pdfView)
    }

    @MainActor
    func testDualPDFScrollSyncKeepsFollowingPaneAtSamePlaceWithinPage() throws {
        // Differently sized panes show the pages at different scales.
        let (originalWindow, original) = makeScrollSyncPane(pageCount: 10, width: 320)
        let (translatedWindow, translated) = makeScrollSyncPane(pageCount: 10, width: 520)
        defer {
            originalWindow.close()
            translatedWindow.close()
        }
        var scrolledSide: DualPDFSelectionSource?
        var originalUserScrolls = 0
        let sync = DualPDFScrollSync()
        sync.isUserScroll = { _, side, _ in side == scrolledSide }
        sync.register(original, side: .original) { originalUserScrolls += 1 }
        sync.register(translated, side: .translated) {}

        scrolledSide = .original
        let page = try XCTUnwrap(original.document?.page(at: 4))
        original.go(to: PDFDestination(page: page, at: CGPoint(x: 0, y: 250)))

        let leading = try XCTUnwrap(DualPDFScrollSync.anchor(in: original))
        let following = try XCTUnwrap(DualPDFScrollSync.anchor(in: translated))
        XCTAssertEqual(leading.pageIndex, following.pageIndex)
        XCTAssertEqual(leading.fraction, following.fraction, accuracy: 0.02)
        XCTAssertGreaterThan(leading.fraction, 0.1)
        XCTAssertEqual(sync.leader, .original)
        XCTAssertTrue(sync.isFollowing(.translated))
        XCTAssertGreaterThan(originalUserScrolls, 0)

        // Programmatic moves, such as restoring the shared page, do not lead.
        let translatedFirstPage = try XCTUnwrap(translated.document?.page(at: 0))
        sync.withoutLeading(.translated) {
            translated.go(to: translatedFirstPage)
        }
        XCTAssertEqual(sync.leader, .original)
        XCTAssertEqual(try XCTUnwrap(DualPDFScrollSync.anchor(in: original)).pageIndex, 4)
    }

    @MainActor
    func testDualPDFScrollSyncFollowsLiveScrollsOnlyAndKeepsReplacementPane() throws {
        let (originalWindow, original) = makeScrollSyncPane(pageCount: 10, width: 400)
        let (translatedWindow, translated) = makeScrollSyncPane(pageCount: 10, width: 400)
        let (replacementWindow, replacement) = makeScrollSyncPane(pageCount: 10, width: 400)
        defer {
            originalWindow.close()
            translatedWindow.close()
            replacementWindow.close()
        }
        // The real gate: trackpad and wheel scrolls are known by their live-scroll notifications,
        // since `NSApp.currentEvent` is stale for most of such a gesture.
        let sync = DualPDFScrollSync()
        sync.register(original, side: .original) {}
        sync.register(translated, side: .translated) {}
        // SwiftUI sets up a replacement pane before tearing down the old one.
        sync.register(replacement, side: .translated) {}
        sync.unregister(translated, side: .translated)

        let scrollView = try XCTUnwrap(original.subviews.compactMap { $0 as? NSScrollView }.first)
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
        original.go(to: PDFDestination(page: try XCTUnwrap(original.document?.page(at: 5)), at: CGPoint(x: 0, y: 200)))
        let followed = try XCTUnwrap(DualPDFScrollSync.anchor(in: replacement))
        XCTAssertEqual(followed.pageIndex, 5)
        XCTAssertEqual(followed.fraction, try XCTUnwrap(DualPDFScrollSync.anchor(in: original)).fraction, accuracy: 0.02)
        XCTAssertEqual(sync.leader, .original)

        // Outside a live scroll, programmatic moves of the original do not move the other pane.
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
        original.go(to: try XCTUnwrap(original.document?.page(at: 1)))
        XCTAssertEqual(try XCTUnwrap(DualPDFScrollSync.anchor(in: replacement)), followed)
    }

    @MainActor
    func testDualPDFScrollSyncLeavesPartialTranslationAtItsLastPages() throws {
        let (originalWindow, original) = makeScrollSyncPane(pageCount: 10, width: 400)
        let (translatedWindow, translated) = makeScrollSyncPane(pageCount: 3, width: 400)
        defer {
            originalWindow.close()
            translatedWindow.close()
        }
        let sync = DualPDFScrollSync()
        sync.isUserScroll = { _, side, _ in side == .original }
        sync.register(original, side: .original) {}
        sync.register(translated, side: .translated) {}

        original.go(to: try XCTUnwrap(original.document?.page(at: 1)))
        let followed = try XCTUnwrap(DualPDFScrollSync.anchor(in: translated))
        XCTAssertEqual(followed.pageIndex, 1)

        original.go(to: try XCTUnwrap(original.document?.page(at: 7)))
        XCTAssertEqual(try XCTUnwrap(DualPDFScrollSync.anchor(in: original)).pageIndex, 7)
        XCTAssertEqual(try XCTUnwrap(DualPDFScrollSync.anchor(in: translated)), followed)
    }

    @MainActor
    func testFollowingPaneNeitherReportsNorRestoresVisiblePage() throws {
        let (originalWindow, original) = makeScrollSyncPane(pageCount: 10, width: 400)
        let (translatedWindow, translated) = makeScrollSyncPane(pageCount: 10, width: 400)
        defer {
            originalWindow.close()
            translatedWindow.close()
        }
        let sync = DualPDFScrollSync()
        sync.isUserScroll = { _, side, _ in side == .original }
        var sharedPageIndex = 3
        var translatedWrites = 0
        let coordinator = PDFReaderView.Coordinator(
            attachmentID: nil,
            pageIndex: Binding(get: { sharedPageIndex }, set: { sharedPageIndex = $0; translatedWrites += 1 }),
            onNoteSelectionChanged: nil
        )
        coordinator.attach(to: translated)
        coordinator.attachScrollSync(sync, side: .translated, to: translated)
        sync.register(original, side: .original) {}

        let page = try XCTUnwrap(original.document?.page(at: 3))
        original.go(to: PDFDestination(page: page, at: CGPoint(x: 0, y: 120)))
        XCTAssertTrue(sync.isFollowing(.translated))
        coordinator.updateCurrentPageIndexIfNeeded()
        XCTAssertEqual(translatedWrites, 0)

        // The shared page moves on while the follower still shows it: no jump to its top.
        sharedPageIndex = 4
        let visible = translated.visiblePages.compactMap { translated.document?.index(for: $0) }
        if visible.contains(4) {
            XCTAssertFalse(coordinator.shouldRestorePageIndex(4, in: translated))
        }
        XCTAssertTrue(coordinator.shouldRestorePageIndex(8, in: translated))
        coordinator.detach()
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

    /// PDFKit stops turning `autoScales` off at the start of a pinch once the view's document has
    /// been replaced, so the next layout snapped the zoom back to fit.
    @MainActor
    func testPinchZoomSurvivesLayoutAfterDocumentIsReplaced() async throws {
        let firstURL = tempDirectory.appendingPathComponent("first.pdf")
        let secondURL = tempDirectory.appendingPathComponent("second.pdf")
        try savePDFDocument(createPDFDocument(withPageCount: 3), to: firstURL)
        try savePDFDocument(createPDFDocument(withPageCount: 3), to: secondURL)
        let model = AutomaticScalingHarnessModel(fileURL: firstURL)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: AutomaticScalingHarness(model: model))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        window.contentView?.layoutSubtreeIfNeeded()
        let pdfView = try XCTUnwrap(firstDescendant(PDFView.self, in: try XCTUnwrap(window.contentView)))
        try await waitUntil { pdfView.document?.documentURL == firstURL }

        model.fileURL = secondURL
        try await waitUntil { pdfView.document?.documentURL == secondURL }
        pdfView.layoutDocumentView()
        XCTAssertTrue(pdfView.autoScales)

        // What a trackpad pinch does: NSScrollView announces a live magnify, then changes its
        // magnification without going through `PDFView.scaleFactor`.
        let scrollView = try XCTUnwrap(firstDescendant(NSScrollView.self, in: pdfView))
        let zoomedScale = pdfView.scaleFactorForSizeToFit * 1.5
        NotificationCenter.default.post(name: NSScrollView.willStartLiveMagnifyNotification, object: scrollView)
        scrollView.magnification = zoomedScale
        NotificationCenter.default.post(name: NSScrollView.didEndLiveMagnifyNotification, object: scrollView)
        pdfView.layoutDocumentView()

        XCTAssertFalse(pdfView.autoScales)
        XCTAssertEqual(pdfView.scaleFactor, zoomedScale, accuracy: 0.001)
    }

    @MainActor
    func testToolbarZoomUsesTwentyPercentStepsAndLeavesAutomaticScaling() {
        let pdfView = PDFView()
        pdfView.document = createPDFDocument(withPageCount: 1)
        pdfView.minScaleFactor = 0.25
        pdfView.maxScaleFactor = 4
        pdfView.autoScales = false
        pdfView.scaleFactor = 1
        pdfView.autoScales = true
        let coordinator = PDFReaderView.Coordinator(
            attachmentID: nil,
            pageIndex: .constant(0),
            onNoteSelectionChanged: nil
        )
        coordinator.pdfView = pdfView
        let startingScale = pdfView.scaleFactor

        coordinator.zoomPDFIn()
        XCTAssertFalse(pdfView.autoScales)
        XCTAssertEqual(pdfView.scaleFactor, startingScale * 1.2, accuracy: 0.001)

        coordinator.zoomPDFOut()
        XCTAssertEqual(pdfView.scaleFactor, startingScale, accuracy: 0.001)
    }

    @MainActor
    func testHandToolDragsThePDFScrollViewFromBlankCanvas() async throws {
        let harness = try await makeHandToolHarness()
        defer { harness.window.close() }
        let clipView = harness.scrollView.contentView
        let startingOrigin = clipView.bounds.origin
        var liveScrollNotifications: [Notification.Name] = []
        let observers = [NSScrollView.willStartLiveScrollNotification, NSScrollView.didEndLiveScrollNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: harness.scrollView, queue: nil) { notification in
                liveScrollNotifications.append(notification.name)
            }
        }
        defer { observers.forEach(NotificationCenter.default.removeObserver) }

        try harness.drag(by: 40)

        XCTAssertLessThan(clipView.bounds.origin.y, startingOrigin.y - 20)
        // The other pane of a dual reader follows live scrolls, wherever the pointer goes.
        XCTAssertEqual(liveScrollNotifications, [
            NSScrollView.willStartLiveScrollNotification,
            NSScrollView.didEndLiveScrollNotification
        ])
    }

    @MainActor
    private func makeHandToolHarness() async throws -> HandToolHarness {
        let url = tempDirectory.appendingPathComponent("hand-tool.pdf")
        try savePDFDocument(createPDFDocument(withPageCount: 12), to: url)
        let model = AutomaticScalingHarnessModel(fileURL: url, handToolEnabled: true)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: AutomaticScalingHarness(model: model))
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        let pdfView = try XCTUnwrap(firstDescendant(PDFView.self, in: try XCTUnwrap(window.contentView)))
        try await waitUntil { pdfView.document?.documentURL == url }
        pdfView.autoScales = false
        pdfView.scaleFactor = 2
        pdfView.layoutDocumentView()
        let scrollView = try XCTUnwrap(firstDescendant(NSScrollView.self, in: pdfView))
        let clipView = scrollView.contentView
        let startingOrigin = clipView.constrainBoundsRect(
            CGRect(x: clipView.bounds.origin.x, y: 160, width: clipView.bounds.width, height: clipView.bounds.height)
        ).origin
        clipView.scroll(to: startingOrigin)
        scrollView.reflectScrolledClipView(clipView)

        let visiblePage = try XCTUnwrap(pdfView.currentPage)
        let pageBounds = visiblePage.bounds(for: pdfView.displayBox)
        let blankPagePoint = CGPoint(x: pageBounds.maxX - 8, y: pageBounds.minY + 8)
        let viewPoint = pdfView.convert(blankPagePoint, from: visiblePage)
        return HandToolHarness(
            window: window,
            pdfView: pdfView,
            scrollView: scrollView,
            blankWindowPoint: pdfView.convert(viewPoint, to: nil)
        )
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

    private func firstDescendant<View: NSView>(_ type: View.Type, in view: NSView) -> View? {
        if let match = view as? View {
            return match
        }
        for subview in view.subviews {
            if let match = firstDescendant(type, in: subview) {
                return match
            }
        }
        return nil
    }

    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(3),
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while condition() == false {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting for condition")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

@MainActor
private struct HandToolHarness {
    let window: NSWindow
    let pdfView: PDFView
    let scrollView: NSScrollView
    let blankWindowPoint: CGPoint

    // Only drags the hand tool takes: PDFKit tracks other mouse downs in its own loop.
    func drag(by distance: CGFloat) throws {
        let end = CGPoint(x: blankWindowPoint.x, y: blankWindowPoint.y + distance)
        pdfView.mouseDown(with: try event(.leftMouseDown, at: blankWindowPoint, number: 1))
        pdfView.mouseDragged(with: try event(.leftMouseDragged, at: end, number: 2))
        pdfView.mouseUp(with: try event(.leftMouseUp, at: end, number: 3))
    }

    private func event(_ type: NSEvent.EventType, at location: CGPoint, number: Int) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: TimeInterval(number),
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: number,
            clickCount: 1,
            pressure: type == .leftMouseUp ? 0 : 1
        ))
    }
}

private final class AutomaticScalingHarnessModel: ObservableObject {
    @Published var fileURL: URL
    @Published var pageIndex = 0
    let handToolEnabled: Bool

    init(fileURL: URL, handToolEnabled: Bool = false) {
        self.fileURL = fileURL
        self.handToolEnabled = handToolEnabled
    }
}

private struct AutomaticScalingHarness: View {
    @ObservedObject var model: AutomaticScalingHarnessModel

    var body: some View {
        PDFReaderView(
            fileURL: model.fileURL,
            usesAutomaticScaling: true,
            pageIndex: $model.pageIndex,
            handToolEnabled: model.handToolEnabled
        )
        .frame(width: 500, height: 600)
    }
}
