import AppKit
import PDFKit
import SwiftUI
import WebKit
import XCTest
@testable import ReadPaper

/// "Translate on Selection": a bubble next to the selected text that holds only the
/// translation and is gone with the selection.
@MainActor
final class QuickTranslationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func selection(_ quote: String, page: Int = 0) -> NoteSelectionContext {
        NoteSelectionContext(
            attachmentID: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA"),
            quote: quote,
            pageIndex: page
        )
    }

    // MARK: - Request life cycle

    func testTranslationAppearsOnceTheSelectionSettles() async throws {
        let model = QuickTranslationModel(settleDelay: .milliseconds(20), isSelecting: { false })
        var requested: [String] = []

        model.selectionChanged(selection("gradient descent"), targetLanguage: "zh-CN") { selection, onPartial in
            requested.append(selection.quote)
            onPartial("梯度")
            return "  梯度下降\n"
        }

        XCTAssertNil(model.presentation, "Nothing is shown while the selection may still change.")
        try await waitUntil { model.presentation?.phase == .translated }
        XCTAssertEqual(model.presentation?.text, "梯度下降")
        XCTAssertEqual(requested, ["gradient descent"])
    }

    func testPartialTranslationIsShownWhileStreaming() async throws {
        let model = QuickTranslationModel(settleDelay: .milliseconds(10), isSelecting: { false })
        let gate = Gate()

        model.selectionChanged(selection("attention"), targetLanguage: "zh-CN") { _, onPartial in
            onPartial("注意")
            await gate.wait()
            return "注意力"
        }

        try await waitUntil { model.presentation?.text == "注意" }
        XCTAssertEqual(model.presentation?.phase, .loading)
        gate.open()
        try await waitUntil { model.presentation?.phase == .translated }
        XCTAssertEqual(model.presentation?.text, "注意力")
    }

    func testAChangedSelectionReplacesThePendingRequest() async throws {
        let model = QuickTranslationModel(settleDelay: .milliseconds(40), isSelecting: { false })
        var requested: [String] = []
        let translate: QuickTranslationModel.Translate = { selection, _ in
            requested.append(selection.quote)
            return "译文：" + selection.quote
        }

        // A drag publishes every intermediate selection.
        model.selectionChanged(selection("stochastic"), targetLanguage: "zh-CN", translate: translate)
        model.selectionChanged(selection("stochastic gradient"), targetLanguage: "zh-CN", translate: translate)
        model.selectionChanged(selection("stochastic gradient descent"), targetLanguage: "zh-CN", translate: translate)

        try await waitUntil { model.presentation?.phase == .translated }
        XCTAssertEqual(requested, ["stochastic gradient descent"])
        XCTAssertEqual(model.presentation?.text, "译文：stochastic gradient descent")
    }

    func testNothingIsRequestedWhileTheMouseButtonIsDown() async throws {
        var isMouseDown = true
        let model = QuickTranslationModel(settleDelay: .milliseconds(15), isSelecting: { isMouseDown })
        var requestCount = 0

        model.selectionChanged(selection("a paused drag"), targetLanguage: "zh-CN") { _, _ in
            requestCount += 1
            return "暂停的拖动"
        }

        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(requestCount, 0)
        XCTAssertNil(model.presentation)

        isMouseDown = false
        try await waitUntil { model.presentation?.phase == .translated }
        XCTAssertEqual(requestCount, 1)
    }

    func testDismissHidesTheBubbleAndDropsTheRunningRequest() async throws {
        let model = QuickTranslationModel(settleDelay: .milliseconds(10), isSelecting: { false })
        let gate = Gate()
        var requestCount = 0
        let translate: QuickTranslationModel.Translate = { _, _ in
            requestCount += 1
            await gate.wait()
            return "晚到的译文"
        }

        model.selectionChanged(selection("late answer"), targetLanguage: "zh-CN", translate: translate)
        try await waitUntil { model.presentation?.phase == .loading }

        model.dismiss()
        XCTAssertNil(model.presentation)
        gate.open()
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertNil(model.presentation, "An answer that arrives after the selection is gone is not shown.")

        // It was not remembered either: selecting the passage again asks again.
        model.selectionChanged(selection("late answer"), targetLanguage: "zh-CN", translate: translate)
        try await waitUntil { model.presentation?.phase == .translated }
        XCTAssertEqual(requestCount, 2)
    }

    func testSelectingTheSamePassageAgainDoesNotAskAgain() async throws {
        let model = QuickTranslationModel(settleDelay: .milliseconds(10), isSelecting: { false })
        var requestCount = 0
        let translate: QuickTranslationModel.Translate = { _, _ in
            requestCount += 1
            return "反向传播"
        }

        model.selectionChanged(selection("backpropagation"), targetLanguage: "zh-CN", translate: translate)
        try await waitUntil { model.presentation?.phase == .translated }
        model.dismiss()

        model.selectionChanged(selection("backpropagation"), targetLanguage: "zh-CN", translate: translate)
        XCTAssertEqual(model.presentation?.text, "反向传播", "A remembered translation shows without a delay.")
        XCTAssertEqual(requestCount, 1)

        // Another target language is another translation.
        model.selectionChanged(selection("backpropagation"), targetLanguage: "ja", translate: translate)
        XCTAssertNil(model.presentation)
        try await waitUntil { model.presentation?.phase == .translated }
        XCTAssertEqual(requestCount, 2)
    }

    func testOnlyTheLastTranslationsAreRemembered() async throws {
        let model = QuickTranslationModel(settleDelay: .milliseconds(1), isSelecting: { false })
        var requested: [String] = []
        let translate: QuickTranslationModel.Translate = { selection, _ in
            requested.append(selection.quote)
            return "译文"
        }

        for index in 0...QuickTranslationModel.cacheLimit {
            model.selectionChanged(selection("passage \(index)"), targetLanguage: "zh-CN", translate: translate)
            try await waitUntil { model.presentation?.phase == .translated }
        }
        model.dismiss()

        model.selectionChanged(selection("passage 0"), targetLanguage: "zh-CN", translate: translate)
        try await waitUntil { model.presentation?.phase == .translated }
        XCTAssertEqual(requested.filter { $0 == "passage 0" }.count, 2)
    }

    func testAFailedRequestShowsItsReason() async throws {
        let model = QuickTranslationModel(settleDelay: .milliseconds(10), isSelecting: { false })
        var requestCount = 0
        let translate: QuickTranslationModel.Translate = { _, _ in
            requestCount += 1
            throw StubTranslationError(errorDescription: "No reading assistant model is selected.")
        }

        model.selectionChanged(selection("no route"), targetLanguage: "zh-CN", translate: translate)
        try await waitUntil { model.presentation?.phase == .failed }
        XCTAssertEqual(model.presentation?.text, "No reading assistant model is selected.")

        // A failure is not remembered.
        model.dismiss()
        model.selectionChanged(selection("no route"), targetLanguage: "zh-CN", translate: translate)
        try await waitUntil { model.presentation?.phase == .failed }
        XCTAssertEqual(requestCount, 2)
    }

    // MARK: - Which selections get a bubble

    func testEligibility() {
        let sentence = "We train the model with stochastic gradient descent and a cosine schedule."
        XCTAssertTrue(QuickTranslationEligibility.canTranslate(quote: sentence, attachmentKind: .pdf, targetLanguage: "zh-CN"))
        XCTAssertTrue(QuickTranslationEligibility.canTranslate(quote: sentence, attachmentKind: .html, targetLanguage: "zh-CN"))
        // The corrected transcription of a scanned paper is a resource attachment.
        XCTAssertTrue(QuickTranslationEligibility.canTranslate(quote: sentence, attachmentKind: .resource, targetLanguage: "zh-CN"))
        XCTAssertFalse(QuickTranslationEligibility.canTranslate(quote: sentence, attachmentKind: .translatedPDF, targetLanguage: "zh-CN"))

        XCTAssertFalse(QuickTranslationEligibility.canTranslate(quote: "x", attachmentKind: .pdf, targetLanguage: "zh-CN"))
        let page = String(repeating: "word ", count: 500)
        XCTAssertFalse(QuickTranslationEligibility.canTranslate(quote: page, attachmentKind: .pdf, targetLanguage: "zh-CN"))
    }

    func testTextAlreadyInTheTargetLanguageIsLeftAlone() {
        let translated = "我们使用随机梯度下降和余弦学习率调度来训练模型，并在验证集上选择最优的超参数。"
        XCTAssertFalse(QuickTranslationEligibility.canTranslate(quote: translated, attachmentKind: .html, targetLanguage: "zh-CN"))
        XCTAssertTrue(QuickTranslationEligibility.canTranslate(quote: translated, attachmentKind: .html, targetLanguage: "en"))

        let source = "We train the model with stochastic gradient descent and choose hyperparameters on the validation set."
        XCTAssertFalse(QuickTranslationEligibility.canTranslate(quote: source, attachmentKind: .html, targetLanguage: "en-US"))
        // A target the recognizer cannot be compared with never suppresses the bubble.
        XCTAssertTrue(QuickTranslationEligibility.canTranslate(quote: source, attachmentKind: .html, targetLanguage: "Simplified Chinese"))
    }

    func testContextIsCutToTheNeighbourhoodOfTheSelection() throws {
        let before = String(repeating: "Earlier page text. ", count: 200)
        let after = String(repeating: " Later page text.", count: 200)
        let pages = before + "The loss is minimised with\nstochastic  gradient descent over mini-batches." + after

        let context = try XCTUnwrap(QuickTranslationContext.nearby(
            quote: "stochastic gradient descent",
            in: pages,
            radius: 60
        ))
        XCTAssertTrue(context.contains("The loss is minimised with stochastic gradient descent over mini-batches."))
        XCTAssertLessThanOrEqual(context.count, 60 + "stochastic gradient descent".count + 60)

        XCTAssertNil(QuickTranslationContext.nearby(quote: "not on these pages", in: pages, radius: 60))
        XCTAssertEqual(
            QuickTranslationContext.nearby(quote: "not here", in: "A  short\nparagraph.", radius: 60),
            "A short paragraph."
        )
        XCTAssertNil(QuickTranslationContext.nearby(quote: "anything", in: nil))
    }

    // MARK: - Placement

    private let container = CGSize(width: 900, height: 700)

    private func place(anchor: CGRect, bubble: CGSize) -> CGRect {
        QuickTranslationBubblePlacement.frame(anchor: anchor, container: container) { maximumWidth, maximumHeight in
            CGSize(
                width: min(bubble.width, maximumWidth),
                height: maximumHeight.map { min(bubble.height, $0) } ?? bubble.height
            )
        }
    }

    func testBubbleSitsJustBelowTheSelection() {
        let anchor = CGRect(x: 400, y: 200, width: 180, height: 16)
        let narrower = place(anchor: anchor, bubble: CGSize(width: 120, height: 34))

        XCTAssertEqual(narrower.minY, anchor.maxY + QuickTranslationBubblePlacement.gap)
        XCTAssertEqual(narrower.midX, anchor.midX)
        XCTAssertEqual(narrower.size, CGSize(width: 120, height: 34))

        // A translation wider than the selection starts where the selection starts.
        let wider = place(anchor: anchor, bubble: CGSize(width: 300, height: 52))
        XCTAssertEqual(wider.minX, anchor.minX)
        XCTAssertEqual(wider.minY, anchor.maxY + QuickTranslationBubblePlacement.gap)
    }

    func testBubbleGoesAboveWhenThereIsNoRoomBelow() {
        let anchor = CGRect(x: 300, y: 640, width: 200, height: 30)
        let frame = place(anchor: anchor, bubble: CGSize(width: 200, height: 80))

        XCTAssertEqual(frame.maxY, anchor.minY - QuickTranslationBubblePlacement.gap)
    }

    func testBubbleStaysInsideTheReader() {
        let margin = QuickTranslationBubblePlacement.margin
        let atLeftEdge = place(anchor: CGRect(x: 2, y: 100, width: 30, height: 16), bubble: CGSize(width: 240, height: 34))
        XCTAssertEqual(atLeftEdge.minX, margin)
        let atRightEdge = place(anchor: CGRect(x: 880, y: 100, width: 18, height: 16), bubble: CGSize(width: 240, height: 34))
        XCTAssertEqual(atRightEdge.maxX, container.width - margin)

        // A translation taller than the room on either side is cut to the larger side.
        let anchor = CGRect(x: 100, y: 300, width: 500, height: 200)
        let tall = place(anchor: anchor, bubble: CGSize(width: 500, height: 2_000))
        XCTAssertEqual(tall.maxY, anchor.minY - QuickTranslationBubblePlacement.gap)
        XCTAssertGreaterThanOrEqual(tall.minY, margin)
    }

    func testBubbleWidthFollowsTheSelection() {
        var limits: [CGFloat] = []
        func limit(forAnchorWidth width: CGFloat) -> CGFloat {
            _ = QuickTranslationBubblePlacement.frame(
                anchor: CGRect(x: 100, y: 100, width: width, height: 16),
                container: container
            ) { maximumWidth, _ in
                limits.append(maximumWidth)
                return CGSize(width: maximumWidth, height: 30)
            }
            return limits.removeLast()
        }

        XCTAssertEqual(limit(forAnchorWidth: 40), QuickTranslationBubblePlacement.narrowWidthLimit)
        XCTAssertEqual(limit(forAnchorWidth: 420), 420)
        XCTAssertEqual(limit(forAnchorWidth: 800), QuickTranslationBubblePlacement.wideWidthLimit)
    }

    // MARK: - Readers report where the selection is

    func testPDFReaderReportsTheSelectionAndFollowsScrolling() async throws {
        let anchor = SelectionAnchorModel()
        let fileURL = try writePDF(pageCount: 3, passage: "The selected passage of the paper")
        let window = makeWindow(ReaderHarness(anchor: anchor) {
            PDFReaderView(
                fileURL: fileURL,
                paperID: UUID(),
                attachmentID: UUID(),
                pageIndex: .constant(0)
            )
        })
        defer { window.close() }
        let pdfView = try XCTUnwrap(find(PDFView.self, in: try XCTUnwrap(window.contentView)))
        let reference = try XCTUnwrap(anchor.referenceView)
        try await waitUntil { pdfView.document?.pageCount == 3 }
        XCTAssertNil(anchor.rect)

        let page = try XCTUnwrap(pdfView.document?.page(at: 0))
        let text = try XCTUnwrap(page.string) as NSString
        let range = text.range(of: "selected passage")
        XCTAssertNotEqual(range.location, NSNotFound)
        let selection = try XCTUnwrap(page.selection(for: range))
        pdfView.setCurrentSelection(selection, animate: false)

        try await waitUntil { anchor.rect != nil }
        func expectedRect() -> CGRect {
            pdfView.convert(pdfView.convert(selection.bounds(for: page), from: page), to: reference)
        }
        assertEqual(try XCTUnwrap(anchor.rect), expectedRect(), accuracy: 1)

        let scrollView = try XCTUnwrap(find(NSScrollView.self, in: pdfView))
        let before = try XCTUnwrap(anchor.rect)
        var origin = scrollView.contentView.bounds.origin
        origin.y += scrollView.documentView?.isFlipped == true ? 30 : -30
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)

        try await waitUntil { anchor.rect.map { abs($0.minY - before.minY) > 1 } ?? false }
        assertEqual(try XCTUnwrap(anchor.rect), expectedRect(), accuracy: 1)

        pdfView.clearSelection()
        try await waitUntil { anchor.rect == nil }
    }

    func testHTMLReaderReportsTheSelectionAndFollowsScrolling() async throws {
        let anchor = SelectionAnchorModel()
        let fileURL = try writeHTML(paragraphs: 80)
        var published: [NoteSelectionContext?] = []
        let window = makeWindow(ReaderHarness(anchor: anchor) {
            HTMLReaderView(
                fileURL: fileURL,
                attachmentID: UUID(),
                displayMode: .original,
                reloadToken: 0,
                initialScrollRatio: 0,
                scrollRatio: .constant(0),
                segmentUpdate: nil,
                onNoteSelectionChanged: { published.append($0) }
            )
        })
        defer { window.close() }
        let webView = try XCTUnwrap(find(WKWebView.self, in: try XCTUnwrap(window.contentView)))
        try await waitForJavaScript(in: webView, "window.__rpReaderToolsInstalled && document.querySelectorAll('p').length === 80")

        _ = try await webView.evaluateJavaScript("""
        (() => {
            const text = document.querySelectorAll('p')[4].firstChild;
            const range = document.createRange();
            range.setStart(text, 0);
            range.setEnd(text, 11);
            const selection = window.getSelection();
            selection.removeAllRanges();
            selection.addRange(range);
            return true;
        })()
        """)

        try await waitUntil { anchor.rect != nil }
        XCTAssertEqual(published.last??.quote, "Paragraph 4")
        func pageRect() async throws -> CGRect {
            let values = try await webView.evaluateJavaScript("""
            (() => {
                const rect = window.getSelection().getRangeAt(0).getBoundingClientRect();
                return [rect.left, rect.top, rect.width, rect.height];
            })()
            """) as? [Double]
            let rect = try XCTUnwrap(values)
            return CGRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3])
        }
        // The web view fills the harness, so viewport and reference coordinates coincide.
        assertEqual(try XCTUnwrap(anchor.rect), try await pageRect(), accuracy: 1)

        let before = try XCTUnwrap(anchor.rect)
        _ = try await webView.evaluateJavaScript("window.scrollBy(0, 40); true")
        try await waitUntil { anchor.rect.map { abs($0.minY - (before.minY - 40)) <= 1 } ?? false }

        // Scrolled out of the reader, there is nothing to put a bubble next to.
        _ = try await webView.evaluateJavaScript("window.scrollBy(0, 4000); true")
        try await waitUntil { anchor.rect == nil }
        _ = try await webView.evaluateJavaScript("window.scrollTo(0, 0); true")
        try await waitUntil { anchor.rect != nil }

        _ = try await webView.evaluateJavaScript("window.getSelection().removeAllRanges(); true")
        try await waitUntil { anchor.rect == nil }
        XCTAssertNil(try XCTUnwrap(published.last))
    }

    func testViewportRectIsConvertedForUnflippedViews() {
        let body: [String: Any] = ["x": 20.0, "y": 100.0, "width": 240.0, "height": 18.0]
        XCTAssertEqual(
            HTMLReaderView.Coordinator.selectionRect(from: body, viewHeight: 600, isFlipped: true),
            CGRect(x: 20, y: 100, width: 240, height: 18)
        )
        XCTAssertEqual(
            HTMLReaderView.Coordinator.selectionRect(from: body, viewHeight: 600, isFlipped: false),
            CGRect(x: 20, y: 482, width: 240, height: 18)
        )
        XCTAssertNil(HTMLReaderView.Coordinator.selectionRect(from: NSNull(), viewHeight: 600, isFlipped: true))
        XCTAssertNil(HTMLReaderView.Coordinator.selectionRect(
            from: ["x": 0.0, "y": 0.0, "width": 0.0, "height": 0.0],
            viewHeight: 600,
            isFlipped: true
        ))
    }

    func testOnlyTheReaderHoldingTheSelectionClearsIt() throws {
        let anchor = SelectionAnchorModel()
        let window = makeWindow(ReaderHarness(anchor: anchor) { Color.clear })
        defer { window.close() }
        let reference = try XCTUnwrap(anchor.referenceView)
        let original = NSObject()
        let translated = NSObject()

        anchor.update(CGRect(x: 10, y: 20, width: 100, height: 14), in: reference, owner: original)
        XCTAssertEqual(anchor.rect, CGRect(x: 10, y: 20, width: 100, height: 14))

        // The other column of the two-column reader has no selection of its own.
        anchor.clear(owner: translated)
        XCTAssertNotNil(anchor.rect)
        anchor.update(nil, in: reference, owner: translated)
        XCTAssertNotNil(anchor.rect)

        anchor.clear(owner: original)
        XCTAssertNil(anchor.rect)
    }

    // MARK: - Helpers

    private func assertEqual(
        _ actual: CGRect,
        _ expected: CGRect,
        accuracy: CGFloat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: accuracy, file: file, line: line)
    }

    private func makeWindow<Content: View>(_ content: Content) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content.frame(width: 600, height: 500))
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    private func find<View: NSView>(_ type: View.Type, in view: NSView) -> View? {
        if let match = view as? View {
            return match
        }
        for subview in view.subviews {
            if let match = find(type, in: subview) {
                return match
            }
        }
        return nil
    }

    private func writeHTML(paragraphs: Int) throws -> URL {
        let body = (0..<paragraphs)
            .map { "<p>Paragraph \($0) has a sentence, and this is the end of paragraph \($0).</p>" }
            .joined()
        let url = root.appendingPathComponent("paper.html")
        try "<!doctype html><html><head><meta charset=\"UTF-8\"></head><body>\(body)</body></html>"
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func writePDF(pageCount: Int, passage: String) throws -> URL {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 400, height: 600)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        for pageIndex in 0..<pageCount {
            context.beginPDFPage(nil)
            for (line, y) in [("Page \(pageIndex + 1) heading", CGFloat(540)), (passage, 480)] {
                let text = NSAttributedString(
                    string: line,
                    attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.black]
                )
                context.textPosition = CGPoint(x: 40, y: y)
                CTLineDraw(CTLineCreateWithAttributedString(text as CFAttributedString), context)
            }
            context.endPDFPage()
        }
        context.closePDF()
        let url = root.appendingPathComponent("paper.pdf")
        try (data as Data).write(to: url)
        return url
    }

    private func waitForJavaScript(in webView: WKWebView, _ condition: String) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if (try? await webView.evaluateJavaScript("Boolean(\(condition))")) as? Bool == true {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for: \(condition)")
    }

    private func waitUntil(
        timeout: Duration = .seconds(5),
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while condition() == false {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting for condition", file: file, line: line)
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// A reader with the bubble's reference area over it, as in the reader pane.
private struct ReaderHarness<Reader: View>: View {
    let anchor: SelectionAnchorModel
    @ViewBuilder var reader: Reader

    var body: some View {
        ZStack {
            reader
                .environment(\.selectionAnchorModel, anchor)
            SelectionAnchorReferenceView(model: anchor)
        }
    }
}

private struct StubTranslationError: LocalizedError {
    var errorDescription: String?
}

/// Holds a fake request open until the test lets it finish.
@MainActor
private final class Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard isOpen == false else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}
