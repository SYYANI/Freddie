import AppKit
import PDFKit
import SwiftUI
import WebKit
import XCTest
@testable import ReadPaper

/// Opening a citation switches papers and navigates in one step; the reader must end up
/// at the cited passage rather than at a restored reading position.
@MainActor
final class CitationNavigationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testPDFReaderLandsOnTheCitedPassageOfTheNewPaper() async throws {
        let paperA = try writePDF(named: "a.pdf", pageCount: 10, passages: [:])
        let paperB = try writePDF(named: "b.pdf", pageCount: 10, passages: [5: "Cited passage near the bottom"])
        let model = PDFSwitchModel(fileURL: paperA, paperID: UUID(), pageIndex: 7)
        let (window, pdfView) = try host(model)
        defer { window.close() }
        try await waitUntil { self.currentPageIndex(of: pdfView) == 7 }

        let paperBID = UUID()
        model.paperID = paperBID
        model.fileURL = paperB
        model.pageIndex = 5
        model.request = NoteNavigationRequest(paperID: paperBID, pageIndex: 5, quote: "Cited passage")
        try await waitUntil { pdfView.document?.documentURL == paperB }
        try await Task.sleep(for: .milliseconds(400))

        XCTAssertEqual(currentPageIndex(of: pdfView), 5)
        XCTAssertEqual(model.pageIndex, 5)
        let page = try XCTUnwrap(pdfView.document?.page(at: 5))
        let passage = try XCTUnwrap(page.selection(for: try XCTUnwrap(
            PDFNoteNavigationTextMatcher.range(of: "Cited passage", in: try XCTUnwrap(page.string))
        )))
        let passageInView = pdfView.convert(passage.bounds(for: page), from: page)
        XCTAssertTrue(pdfView.bounds.intersects(passageInView), "The cited passage is on screen: \(passageInView) in \(pdfView.bounds)")
    }

    /// Before citations, switching papers also opened the new PDF at the previous
    /// paper's page instead of its own restored page.
    func testPDFReaderOpensAnotherPaperAtItsOwnPage() async throws {
        let paperA = try writePDF(named: "a.pdf", pageCount: 10, passages: [:])
        let paperB = try writePDF(named: "b.pdf", pageCount: 10, passages: [:])
        let model = PDFSwitchModel(fileURL: paperA, paperID: UUID(), pageIndex: 7)
        let (window, pdfView) = try host(model)
        defer { window.close() }
        try await waitUntil { self.currentPageIndex(of: pdfView) == 7 }

        model.paperID = UUID()
        model.fileURL = paperB
        model.pageIndex = 2
        try await waitUntil { pdfView.document?.documentURL == paperB }
        try await Task.sleep(for: .milliseconds(400))

        XCTAssertEqual(currentPageIndex(of: pdfView), 2)
        XCTAssertEqual(model.pageIndex, 2)
    }

    func testHTMLReaderGoesToTheCitedElementOfTheNewPage() async throws {
        let pageA = try writeHTML(named: "a", paragraphs: 40)
        let pageB = try writeHTML(named: "b", paragraphs: 40)
        let model = HTMLSwitchModel(fileURL: pageA)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: HTMLSwitchHarness(model: model))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        window.contentView?.layoutSubtreeIfNeeded()
        let webView = try XCTUnwrap(findWebView(in: try XCTUnwrap(window.contentView)))
        try await waitForJavaScript(in: webView, "document.getElementById('p-a-0') !== null")

        model.initialScrollRatio = 0.8
        model.request = NoteNavigationRequest(paperID: UUID(), htmlSelector: "rp-anchor:30")
        model.fileURL = pageB

        try await waitForJavaScript(
            in: webView,
            "document.querySelector('.rp-note-anchor-target')?.id === 'p-b-30'"
        )
    }

    // MARK: - Helpers

    private func host(_ model: PDFSwitchModel) throws -> (NSWindow, PDFView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: PDFSwitchHarness(model: model))
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        let pdfView = try XCTUnwrap(findPDFView(in: try XCTUnwrap(window.contentView)))
        return (window, pdfView)
    }

    private func findWebView(in view: NSView) -> WKWebView? {
        if let webView = view as? WKWebView {
            return webView
        }
        for subview in view.subviews {
            if let webView = findWebView(in: subview) {
                return webView
            }
        }
        return nil
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

    private func writeHTML(named name: String, paragraphs: Int) throws -> URL {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let body = (0..<paragraphs)
            .map { "<p id=\"p-\(name)-\($0)\">Paragraph \($0) of page \(name), long enough to take up some room on screen.</p>" }
            .joined()
        let url = directory.appendingPathComponent("paper.html")
        try "<!doctype html><html><head><meta charset=\"UTF-8\"></head><body>\(body)</body></html>"
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func findPDFView(in view: NSView) -> PDFView? {
        if let pdfView = view as? PDFView {
            return pdfView
        }
        for subview in view.subviews {
            if let pdfView = findPDFView(in: subview) {
                return pdfView
            }
        }
        return nil
    }

    private func currentPageIndex(of pdfView: PDFView) -> Int? {
        guard let document = pdfView.document, let page = pdfView.currentPage else { return nil }
        return document.index(for: page)
    }

    private func writePDF(named name: String, pageCount: Int, passages: [Int: String]) throws -> URL {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 400, height: 1200)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        for pageIndex in 0..<pageCount {
            context.beginPDFPage(nil)
            var lines = [("Page \(pageIndex + 1) heading", CGFloat(1100))]
            if let passage = passages[pageIndex] {
                lines.append((passage, 80))
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
        let url = root.appendingPathComponent(name)
        try (data as Data).write(to: url)
        return url
    }

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
private final class PDFSwitchModel: ObservableObject {
    @Published var fileURL: URL
    @Published var paperID: UUID
    @Published var pageIndex: Int
    @Published var request: NoteNavigationRequest?

    init(fileURL: URL, paperID: UUID, pageIndex: Int) {
        self.fileURL = fileURL
        self.paperID = paperID
        self.pageIndex = pageIndex
    }
}

private struct PDFSwitchHarness: View {
    @ObservedObject var model: PDFSwitchModel

    var body: some View {
        PDFReaderView(
            fileURL: model.fileURL,
            paperID: model.paperID,
            pageIndex: $model.pageIndex,
            noteNavigationRequest: model.request
        )
        .frame(width: 600, height: 500)
    }
}

@MainActor
private final class HTMLSwitchModel: ObservableObject {
    @Published var fileURL: URL
    @Published var initialScrollRatio = 0.0
    @Published var scrollRatio = 0.0
    @Published var request: NoteNavigationRequest?

    init(fileURL: URL) {
        self.fileURL = fileURL
    }
}

private struct HTMLSwitchHarness: View {
    @ObservedObject var model: HTMLSwitchModel

    var body: some View {
        HTMLReaderView(
            fileURL: model.fileURL,
            displayMode: .original,
            reloadToken: 0,
            initialScrollRatio: model.initialScrollRatio,
            scrollRatio: $model.scrollRatio,
            segmentUpdate: nil,
            noteNavigationRequest: model.request
        )
        .frame(width: 600, height: 500)
    }
}
