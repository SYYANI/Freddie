import PDFKit
import SwiftUI
import WebKit
import XCTest
@testable import ReadPaper

/// The readers report the paper's own text on screen for echoes of past reading.
@MainActor
final class ReadingFocusReportingTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeModel(events: [LearningEvent] = []) -> LearningEchoModel {
        LearningEchoModel(
            load: { ([], events) },
            revision: { 0 },
            similarity: nil,
            dismissals: LearningEchoDismissalStore(rootDirectory: root),
            delay: .milliseconds(10)
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(10),
        _ condition: () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while condition() == false, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition(), "Timed out", file: file, line: line)
    }

    func testHTMLReportsVisibleOriginalTextAndFollowsScrolling() async throws {
        let fileURL = root.appendingPathComponent("paper.html")
        try """
        <!doctype html><html><head><meta charset="UTF-8"></head><body>
        <p>Visible original paragraph about model collapse.</p>
        <p class="rp-translation-block" data-rp-translation="true">关于模型崩溃的译文段落。</p>
        <p data-rp-region-hidden="true" style="display:none">Hidden region the reader removed.</p>
        <ul><li><p>Nested list paragraph.</p></li></ul>
        <p style="margin-top: 3000px">Far below paragraph on synthetic data.</p>
        </body></html>
        """.write(to: fileURL, atomically: true, encoding: .utf8)

        let model = makeModel()
        let paperID = UUID()
        let attachmentID = UUID()
        let coordinator = HTMLReaderView.Coordinator(
            scrollRatio: .constant(0),
            onNoteSelectionChanged: { _ in },
            onSelectionAssistantDismissed: nil
        )
        coordinator.loadedURL = fileURL
        coordinator.attachmentID = attachmentID
        coordinator.readingFocusSink = ReadingFocusSink(paperID: paperID, attachmentIDs: [attachmentID], model: model)
        let configuration = HTMLReaderView.makeConfiguration(coordinator: coordinator)
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        webView.loadFileURL(fileURL, allowingReadAccessTo: root)

        try await waitUntil { model.reading != nil }
        let first = try XCTUnwrap(model.reading?.focus)
        XCTAssertEqual(first.paperID, paperID)
        XCTAssertEqual(first.attachmentID, attachmentID)
        XCTAssertNil(first.pageIndex)
        XCTAssertTrue(first.text.contains("Visible original paragraph"), first.text)
        XCTAssertEqual(first.text.components(separatedBy: "Nested list paragraph").count, 2, "Reported once")
        XCTAssertFalse(first.text.contains("译文"), "Translations are not the paper's text")
        XCTAssertFalse(first.text.contains("Hidden region"))
        XCTAssertFalse(first.text.contains("Far below"), "Off screen")

        _ = try await webView.evaluateJavaScript("window.scrollTo(0, document.body.scrollHeight); true")
        try await waitUntil { model.reading?.focus.text.contains("Far below") == true }
        XCTAssertFalse(model.reading?.focus.text.contains("Visible original") ?? true)
    }

    func testPDFReportsTheTextOnScreenOfTheOriginalOnly() async throws {
        let fileURL = try writePDF(lines: ["Collapse heading on the first page", "Body text about synthetic data"])
        let model = makeModel()
        let paperID = UUID()
        let original = UUID()

        let window = host(PDFReaderView(
            fileURL: fileURL,
            paperID: paperID,
            attachmentID: original,
            pageIndex: .constant(0)
        )
        .environment(\.readingFocusSink, ReadingFocusSink(paperID: paperID, attachmentIDs: [original], model: model)))
        defer { window.close() }

        try await waitUntil { model.reading != nil }
        let focus = try XCTUnwrap(model.reading?.focus)
        XCTAssertEqual(focus.pageIndex, 0)
        XCTAssertEqual(focus.attachmentID, original)
        XCTAssertTrue(focus.text.contains("Collapse heading"), focus.text)

        let translationModel = makeModel()
        let translated = host(PDFReaderView(
            fileURL: fileURL,
            paperID: paperID,
            attachmentID: UUID(),
            pageIndex: .constant(0)
        )
        .environment(\.readingFocusSink, ReadingFocusSink(paperID: paperID, attachmentIDs: [original], model: translationModel)))
        defer { translated.close() }
        try await Task.sleep(for: .seconds(1))
        XCTAssertNil(translationModel.reading, "A translation's text is not reported")
    }

    func testWritingFocusIsTheCaretParagraphWithoutLinkTargets() {
        let text = """
        # Model collapse

        Short line.

        Training on [Shumailov et al., 2024, p. 2](readpaper://paper/ABC?p=2 "Model collapse") output degrades models over generations of synthetic data.
        """
        let caret = (text as NSString).range(of: "degrades").location

        let paragraph = WritingEchoFocus.paragraph(in: text, at: caret)
        XCTAssertTrue(paragraph.contains("[Shumailov et al., 2024, p. 2] output"), paragraph)
        XCTAssertFalse(paragraph.contains("readpaper://"))
        XCTAssertFalse(paragraph.contains("Short line"), "A long paragraph stands alone")

        let short = WritingEchoFocus.paragraph(in: text, at: (text as NSString).range(of: "Short").location)
        XCTAssertTrue(short.contains("Short line."))
        XCTAssertFalse(short.contains("Training on"))
        XCTAssertEqual(
            WritingEchoFocus.paragraph(in: "", at: 10),
            "",
            "An empty writing has nothing to search for"
        )
    }

    // MARK: - Marks beside paragraphs

    /// A passage the reader highlighted in another paper, related to `collapseParagraph`.
    private let pastHighlight = LearningEvent(
        id: "synthetic", subject: "synthetic", paperID: UUID(), kind: .highlight,
        occurredAt: Date(timeIntervalSince1970: 100), isBackfilled: false, pageIndex: 1,
        quote: "We choose not to use any synthetic data generated by language models during pretraining, and work to avoid and remove AI-generated content from the collected data sources."
    )

    private let collapseParagraph = "Model collapse: as language models write more of the web, pretraining corpora will contain synthetic data generated by earlier models, and AI-generated content becomes hard to remove from collected data sources."

    func testHTMLMarksTheParagraphWithEchoesInTheMargin() async throws {
        let fileURL = root.appendingPathComponent("paper.html")
        try """
        <!doctype html><html><head><meta charset="UTF-8">
        <style>body { margin: 0 auto; max-width: 520px; font: 16px/24px serif; }</style></head><body>
        <p id="intro">An unrelated opening paragraph about optimizers and warmup.</p>
        <p id="collapse">\(collapseParagraph)</p>
        </body></html>
        """.write(to: fileURL, atomically: true, encoding: .utf8)

        let model = makeModel(events: [pastHighlight])
        let paperID = UUID()
        let attachmentID = UUID()
        let coordinator = HTMLReaderView.Coordinator(
            scrollRatio: .constant(0),
            onNoteSelectionChanged: { _ in },
            onSelectionAssistantDismissed: nil
        )
        coordinator.loadedURL = fileURL
        coordinator.attachmentID = attachmentID
        coordinator.readingFocusSink = ReadingFocusSink(paperID: paperID, attachmentIDs: [attachmentID], model: model)
        let configuration = HTMLReaderView.makeConfiguration(coordinator: coordinator)
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 600), configuration: configuration)
        // The reader's own delegate: marks are drawn once the page has finished loading.
        webView.navigationDelegate = coordinator
        coordinator.observeEchoMarks(in: webView)
        webView.loadFileURL(fileURL, allowingReadAccessTo: root)

        try await waitUntil { model.reading?.placements.isEmpty == false }
        let blocks = try XCTUnwrap(model.reading?.focus.blocks)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertTrue(blocks.allSatisfy { $0.id.hasPrefix("rp-anchor:") }, "\(blocks.map(\.id))")
        let collapseID = try XCTUnwrap(blocks.last?.id)
        XCTAssertEqual(model.reading?.placements, [collapseID: ["synthetic"]])

        func markState() async throws -> [String: Any]? {
            let json = try await webView.evaluateJavaScript("""
            (() => {
                const marks = document.querySelectorAll('#rp-echo-layer .rp-echo-mark');
                if (marks.length !== 1) { return null; }
                const mark = marks[0].getBoundingClientRect();
                const paragraph = document.getElementById('collapse').getBoundingClientRect();
                return JSON.stringify({
                    inBody: !!document.body.querySelector('.rp-echo-mark'),
                    left: mark.right <= paragraph.left,
                    nearTop: mark.top >= paragraph.top - 4 && mark.bottom <= paragraph.top + 28,
                    seen: marks[0].dataset.seen,
                    label: marks[0].getAttribute('aria-label')
                });
            })()
            """) as? String
            return try json.flatMap { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        }
        var state: [String: Any]?
        for _ in 0..<100 where state == nil {
            state = try await markState()
            if state == nil { try await Task.sleep(for: .milliseconds(30)) }
        }
        let shown = try XCTUnwrap(state, "One mark is drawn")
        XCTAssertEqual(shown["inBody"] as? Bool, false, "Outside <body>, so anchors and find never see it")
        XCTAssertEqual(shown["left"] as? Bool, true, "In the left margin")
        XCTAssertEqual(shown["nearTop"] as? Bool, true, "Beside the first line")
        XCTAssertEqual(shown["seen"] as? String, "false")
        XCTAssertFalse((shown["label"] as? String ?? "").isEmpty, "Named for VoiceOver")

        model.markOpened(try XCTUnwrap(model.reading?.echoes.first))
        var seen = ""
        for _ in 0..<100 where seen != "true" {
            seen = (try await markState())?["seen"] as? String ?? ""
            if seen != "true" { try await Task.sleep(for: .milliseconds(30)) }
        }
        XCTAssertEqual(seen, "true", "The mark steps back once its cards were seen")
    }

    func testPDFMarksTheParagraphAndAClickOnTheMarkOpensTheFan() async throws {
        let words = collapseParagraph.split(separator: " ")
        var lines: [String] = ["An unrelated heading about optimizers"]
        var current = ""
        for word in words {
            if current.count + word.count > 70 { lines.append(current); current = "" }
            current += (current.isEmpty ? "" : " ") + word
        }
        lines.append(current)
        let fileURL = try writePDF(lines: lines, lineGap: [0: 30])
        let model = makeModel(events: [pastHighlight])
        let anchor = SelectionAnchorModel()
        let paperID = UUID()
        let original = UUID()
        let window = host(ZStack {
            PDFReaderView(fileURL: fileURL, paperID: paperID, attachmentID: original, pageIndex: .constant(0))
                .environment(\.readingFocusSink, ReadingFocusSink(
                    paperID: paperID, attachmentIDs: [original], model: model, anchorSpace: anchor
                ))
            SelectionAnchorReferenceView(model: anchor)
        })
        defer { window.close() }

        try await waitUntil { model.reading?.placements.isEmpty == false }
        XCTAssertEqual(model.reading?.focus.blocks.map(\.id), ["p0-0", "p0-1"], "The heading and the paragraph")
        XCTAssertEqual(model.reading?.placements, ["p0-1": ["synthetic"]])

        let pdfView = try XCTUnwrap(findPDFView(in: try XCTUnwrap(window.contentView)))
        let page = try XCTUnwrap(pdfView.document?.page(at: 0))
        var mark: PDFEchoMarkView?
        for _ in 0..<100 where mark == nil {
            mark = pdfView.documentView?.subviews.lazy.compactMap { $0 as? PDFEchoMarkView }.first
            if mark == nil { try await Task.sleep(for: .milliseconds(30)) }
        }
        let shown = try XCTUnwrap(mark, "A mark is drawn over the page")
        XCTAssertEqual(shown.blockID, "p0-1")
        XCTAssertTrue(page.annotations.isEmpty, "The mark is not a page annotation, which PDFKit would draw blurred when zoomed")
        let markInView = pdfView.convert(shown.frame, from: shown.superview)
        XCTAssertLessThan(pdfView.convert(markInView, to: page).maxX, 40, "In the left margin")

        // Zooming keeps the mark where it was on the page, scaled with it.
        let markEdge = pdfView.convert(CGPoint(x: markInView.maxX, y: markInView.midY), to: page)
        pdfView.scaleFactor *= 2
        let zoomed = pdfView.convert(shown.frame, from: shown.superview)
        let zoomedOnPage = pdfView.convert(zoomed, to: page)
        XCTAssertEqual(zoomedOnPage.maxX, markEdge.x, accuracy: 0.5)
        XCTAssertEqual(zoomedOnPage.midY, markEdge.y, accuracy: 0.5)
        XCTAssertEqual(zoomed.width, markInView.width * 2, accuracy: 0.5, "Scales with the page")
        pdfView.scaleFactor /= 2

        // A real click on the mark: it opens the fan instead of starting a selection.
        let markNow = pdfView.convert(shown.frame, from: shown.superview)
        let center = CGPoint(x: markNow.midX, y: markNow.midY)
        let location = pdfView.convert(center, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
            type == .leftMouseDown ? pdfView.mouseDown(with: event) : pdfView.mouseUp(with: event)
        }
        XCTAssertEqual(model.fan?.blockID, "p0-1")
        XCTAssertEqual(model.fan?.echoes.map(\.id), ["synthetic"])
        XCTAssertTrue((pdfView.currentSelection?.string ?? "").isEmpty, "No selection was started")
    }

    private func findPDFView(in view: NSView) -> PDFView? {
        if let pdfView = view as? PDFView { return pdfView }
        return view.subviews.lazy.compactMap { self.findPDFView(in: $0) }.first
    }

    // MARK: - Helpers

    private func host<Content: View>(_ view: Content) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view.frame(width: 600, height: 500))
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    /// `lineGap` adds space after the line at an index, to start a new paragraph.
    private func writePDF(lines: [String], lineGap: [Int: CGFloat] = [:]) throws -> URL {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 400, height: 600)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        context.beginPDFPage(nil)
        var y: CGFloat = 540
        for (index, line) in lines.enumerated() {
            let text = NSAttributedString(
                string: line,
                attributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.black]
            )
            context.textPosition = CGPoint(x: 40, y: y)
            y -= 12 + (lineGap[index] ?? 0)
            CTLineDraw(CTLineCreateWithAttributedString(text as CFAttributedString), context)
        }
        context.endPDFPage()
        context.closePDF()
        let url = root.appendingPathComponent("paper.pdf")
        try (data as Data).write(to: url)
        return url
    }
}

