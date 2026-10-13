import AppKit
import PDFKit
import SwiftUI
import WebKit
import XCTest
@testable import ReadPaper

/// Passages cited in writings are underlined in the reader, and a click on one reports it.
@MainActor
final class CitationMarkTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func mark(
        _ index: Int,
        pageIndex: Int? = nil,
        htmlSelector: String? = nil,
        passage: String,
        attachmentID: UUID? = nil,
        writingID: UUID = UUID()
    ) -> WritingCitationMark {
        let citation = PaperCitation(
            paperID: UUID(),
            attachmentID: attachmentID,
            pageIndex: pageIndex,
            htmlSelector: htmlSelector,
            quotePrefix: passage
        )
        return WritingCitationMark(
            writingID: writingID,
            index: index,
            record: WritingCitationRecord(citation: citation, passage: passage)
        )
    }

    // MARK: - HTML

    func testHTMLReaderUnderlinesCitedPassagesAndReportsClicks() async throws {
        let page = try writeHTML(paragraphs: 12)
        let attachmentID = UUID()
        let inParagraph = mark(0, htmlSelector: "rp-anchor:3", passage: "Paragraph 3 has a sentence", attachmentID: attachmentID)
        let acrossParagraphs = mark(
            1,
            htmlSelector: "rp-anchor:5",
            passage: "the end of paragraph 5. Paragraph 6 has a sentence"
        )
        let otherAttachment = mark(2, htmlSelector: "rp-anchor:7", passage: "Paragraph 7 has a sentence", attachmentID: UUID())
        let model = HTMLMarkModel(fileURL: page, attachmentID: attachmentID, marks: [inParagraph, acrossParagraphs, otherAttachment])
        let (window, webView) = try host(HTMLMarkHarness(model: model))
        defer { window.close() }

        try await waitForJavaScript(in: webView, "CSS.highlights.get('rp-citation')?.size === 2")
        let markedText = try await webView.evaluateJavaScript(
            "Array.from(CSS.highlights.get('rp-citation')).map(range => range.toString().replace(/\\s+/g, ' ')).sort().join('|')"
        ) as? String
        // The page has no space between the paragraphs that the quote has.
        XCTAssertEqual(markedText, "Paragraph 3 has a sentence|the end of paragraph 5.Paragraph 6 has a sentence")

        let point = try await webView.evaluateJavaScript("""
        (() => {
            const range = Array.from(CSS.highlights.get('rp-citation')).find(range => range.toString().startsWith('Paragraph 3'));
            const rect = range.getClientRects()[0];
            return [rect.left + 4, rect.top + rect.height / 2];
        })()
        """) as? [Double]
        let x = try XCTUnwrap(point?.first)
        let y = try XCTUnwrap(point?.last)
        _ = try await webView.evaluateJavaScript("""
        document.elementFromPoint(\(x), \(y)).dispatchEvent(new MouseEvent('click', {
            bubbles: true, cancelable: true, clientX: \(x), clientY: \(y), detail: 1, button: 0
        }))
        """)
        try await waitUntil { model.activatedIDs == [inParagraph.id] }

        // A double click selects a word instead of opening the writing.
        model.activatedIDs = nil
        _ = try await webView.evaluateJavaScript("""
        (() => {
            const target = document.elementFromPoint(\(x), \(y));
            for (const detail of [1, 2]) {
                target.dispatchEvent(new MouseEvent('click', {
                    bubbles: true, cancelable: true, clientX: \(x), clientY: \(y), detail, button: 0
                }));
            }
        })()
        """)
        try await Task.sleep(for: .milliseconds(HTMLReaderView.Coordinator.citationMarkClickDelayMilliseconds + 250))
        XCTAssertNil(model.activatedIDs)

        model.marks = []
        try await waitForJavaScript(in: webView, "!CSS.highlights.has('rp-citation')")
    }

    // MARK: - PDF

    func testPDFReaderUnderlinesCitedPassagesNearTheCurrentPage() async throws {
        let attachmentID = UUID()
        let url = try writePDF(pageCount: 6, passages: [0: "A cited passage on the first page", 5: "A passage far away"])
        let marks = [
            mark(0, pageIndex: 0, passage: "cited passage on the first", attachmentID: attachmentID),
            mark(1, pageIndex: 5, passage: "passage far away"),
            mark(2, pageIndex: 0, passage: "A cited passage", attachmentID: UUID()),
        ]
        let model = PDFMarkModel(fileURL: url, attachmentID: attachmentID, marks: marks)
        let (window, pdfView) = try hostPDF(PDFMarkHarness(model: model))
        defer { window.close() }

        let firstPage = try XCTUnwrap(pdfView.document?.page(at: 0))
        try await waitUntil { self.citationUnderlines(on: firstPage).count == 1 }
        let lastPage = try XCTUnwrap(pdfView.document?.page(at: 5))
        XCTAssertTrue(citationUnderlines(on: lastPage).isEmpty, "Pages far from the current one wait until they are near")

        pdfView.go(to: lastPage)
        try await waitUntil { self.citationUnderlines(on: lastPage).count == 1 }

        model.marks = []
        try await waitUntil { self.citationUnderlines(on: firstPage).isEmpty && self.citationUnderlines(on: lastPage).isEmpty }
    }

    // MARK: - Drops

    /// Over the writing editor in the main window, the window-wide PDF catcher hands image
    /// drags on to the editor.
    func testImageDragsOverTheWritingEditorReachTheEditor() throws {
        let image = root.appendingPathComponent("figure.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: image)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        window.contentView = content
        let textView = WritingTextView(frame: NSRect(x: 300, y: 0, width: 300, height: 400))
        var inserted: [[WritingImageSource]] = []
        textView.onInsertImages = { sources, _ in inserted.append(sources) }
        content.addSubview(textView)
        let catcher = PDFFileDropCatcherView(frame: content.bounds)
        content.addSubview(catcher)

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("CitationMarkTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects([image as NSURL])

        let elsewhere = PointDraggingInfo(pasteboard: pasteboard, sequenceNumber: 1, location: NSPoint(x: 100, y: 200))
        XCTAssertEqual(catcher.draggingEntered(elsewhere), [])
        XCTAssertFalse(catcher.performDragOperation(elsewhere))

        let overEditor = PointDraggingInfo(pasteboard: pasteboard, sequenceNumber: 2, location: NSPoint(x: 400, y: 200))
        XCTAssertEqual(catcher.draggingEntered(overEditor), .copy)
        XCTAssertTrue(catcher.prepareForDragOperation(overEditor))
        XCTAssertTrue(catcher.performDragOperation(overEditor))
        catcher.draggingEnded(overEditor)
        XCTAssertEqual(inserted, [[.file(image)]])
    }

    // MARK: - Helpers

    private func citationUnderlines(on page: PDFPage) -> [PDFAnnotation] {
        page.annotations.filter { $0.type == "Underline" }
    }

    private func host<Content: View>(_ content: Content) throws -> (NSWindow, WKWebView) {
        let window = makeWindow(content)
        let webView = try XCTUnwrap(find(WKWebView.self, in: try XCTUnwrap(window.contentView)))
        return (window, webView)
    }

    private func hostPDF<Content: View>(_ content: Content) throws -> (NSWindow, PDFView) {
        let window = makeWindow(content)
        let pdfView = try XCTUnwrap(find(PDFView.self, in: try XCTUnwrap(window.contentView)))
        return (window, pdfView)
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

    private func writePDF(pageCount: Int, passages: [Int: String]) throws -> URL {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 400, height: 600)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        for pageIndex in 0..<pageCount {
            context.beginPDFPage(nil)
            var lines = [("Page \(pageIndex + 1) heading", CGFloat(540))]
            if let passage = passages[pageIndex] {
                lines.append((passage, 300))
            }
            for (line, y) in lines {
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

    private func waitUntil(timeout: Duration = .seconds(5), _ condition: @MainActor () -> Bool) async throws {
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
private final class HTMLMarkModel: ObservableObject {
    let fileURL: URL
    let attachmentID: UUID
    @Published var marks: [WritingCitationMark]
    @Published var scrollRatio = 0.0
    var activatedIDs: [String]?

    init(fileURL: URL, attachmentID: UUID, marks: [WritingCitationMark]) {
        self.fileURL = fileURL
        self.attachmentID = attachmentID
        self.marks = marks
    }
}

private struct HTMLMarkHarness: View {
    @ObservedObject var model: HTMLMarkModel

    var body: some View {
        HTMLReaderView(
            fileURL: model.fileURL,
            attachmentID: model.attachmentID,
            displayMode: .original,
            reloadToken: 0,
            initialScrollRatio: 0,
            scrollRatio: $model.scrollRatio,
            segmentUpdate: nil,
            citationMarks: model.marks,
            onCitationMarksActivated: { ids in
                model.activatedIDs = ids
            }
        )
    }
}

@MainActor
private final class PDFMarkModel: ObservableObject {
    let fileURL: URL
    let attachmentID: UUID
    @Published var marks: [WritingCitationMark]
    @Published var pageIndex = 0

    init(fileURL: URL, attachmentID: UUID, marks: [WritingCitationMark]) {
        self.fileURL = fileURL
        self.attachmentID = attachmentID
        self.marks = marks
    }
}

private struct PDFMarkHarness: View {
    @ObservedObject var model: PDFMarkModel

    var body: some View {
        PDFReaderView(
            fileURL: model.fileURL,
            paperID: UUID(uuidString: "00000000-0000-0000-0000-000000000001"),
            attachmentID: model.attachmentID,
            pageIndex: $model.pageIndex,
            citationMarks: model.marks
        )
    }
}

@MainActor
private final class PointDraggingInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingSequenceNumber: Int
    let draggingLocation: NSPoint
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0

    init(pasteboard: NSPasteboard, sequenceNumber: Int, location: NSPoint) {
        draggingPasteboard = pasteboard
        draggingSequenceNumber = sequenceNumber
        draggingLocation = location
    }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .every }
    var draggedImageLocation: NSPoint { .zero }
    nonisolated var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    func slideDraggedImage(to screenPoint: NSPoint) {}

    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions,
        for view: NSView?,
        classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}

    func resetSpringLoading() {}
}
