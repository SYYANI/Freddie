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

    private func makeModel() -> LearningEchoModel {
        LearningEchoModel(
            load: { ([], []) },
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

    private func writePDF(lines: [String]) throws -> URL {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 400, height: 600)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        context.beginPDFPage(nil)
        for (index, line) in lines.enumerated() {
            let text = NSAttributedString(
                string: line,
                attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.black]
            )
            context.textPosition = CGPoint(x: 40, y: 540 - CGFloat(index) * 24)
            CTLineDraw(CTLineCreateWithAttributedString(text as CFAttributedString), context)
        }
        context.endPDFPage()
        context.closePDF()
        let url = root.appendingPathComponent("paper.pdf")
        try (data as Data).write(to: url)
        return url
    }
}
