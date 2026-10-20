import CoreGraphics
import CoreText
import Foundation
import XCTest
@testable import ReadPaper

final class PaperFullTextSearchServiceTests: XCTestCase {
    @MainActor
    func testHTMLIndexPreservesStructureNeighborsAndNavigableSelector() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaperFullTextSearchServiceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileStore = PaperFileStore(applicationSupportDirectory: root)
        let paper = Paper(title: "Structured Paper")
        paper.localDirectoryPath = try fileStore.directory(for: paper.id).path
        let htmlURL = try fileStore.write(Data(Self.sampleHTML.utf8), named: "paper.html", for: paper.id)
        let attachment = PaperAttachment(
            paperID: paper.id,
            kind: .html,
            source: .webPage,
            filename: "paper.html",
            filePath: htmlURL.path
        )
        let service = PaperFullTextSearchService(fileStore: fileStore)

        let index = try XCTUnwrap(service.rebuild(paper: paper, attachments: [attachment]))
        XCTAssertEqual(index.blocks.map(\.kind), [.heading, .paragraph, .heading, .paragraph, .figureCaption, .listItem])
        XCTAssertEqual(index.blocks[3].sectionPath, ["Methods", "Evaluation"])

        let hits = service.search(query: "held-out benchmark validation", in: index, topK: 1)
        let hit = try XCTUnwrap(hits.first)
        XCTAssertEqual(hit.block.text, "We validate the conclusion on a held-out benchmark.")
        XCTAssertEqual(hit.previousBlocks.last?.text, "Evaluation")
        XCTAssertEqual(hit.nextBlocks.first?.text, "Figure 2: Accuracy on the benchmark.")
        XCTAssertTrue(hit.block.htmlSelector?.contains("data-rp-assistant-block-id") == true)

        let indexedHTML = try String(contentsOf: htmlURL, encoding: .utf8)
        XCTAssertTrue(indexedHTML.contains("data-rp-assistant-block-id"))
        XCTAssertFalse(index.blocks.contains(where: { $0.text.contains("已有译文") }))
    }

    @MainActor
    func testHTMLIndexLeavesOutHiddenRegions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaperFullTextSearchHiddenTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileStore = PaperFileStore(applicationSupportDirectory: root)
        let paper = Paper(title: "Edited Page")
        paper.localDirectoryPath = try fileStore.directory(for: paper.id).path
        let html = """
        <!doctype html>
        <html><head><meta charset="UTF-8"></head><body>
          <h1>Results</h1>
          <div data-rp-region-hidden="true"><p>Subscribe for weekly updates.</p></div>
          <p>The decoder improves accuracy.</p>
          <ul><li>Ablation summary <p data-rp-region-hidden="true">Related posts you may like.</p></li></ul>
        </body></html>
        """
        let htmlURL = try fileStore.write(Data(html.utf8), named: "paper.html", for: paper.id)
        let attachment = PaperAttachment(
            paperID: paper.id,
            kind: .html,
            source: .webPage,
            filename: "paper.html",
            filePath: htmlURL.path
        )

        let index = try XCTUnwrap(PaperFullTextSearchService(fileStore: fileStore).rebuild(paper: paper, attachments: [attachment]))

        XCTAssertEqual(index.blocks.map(\.text), ["Results", "The decoder improves accuracy.", "Ablation summary"])
    }

    @MainActor
    func testLoadOrRebuildUsesPersistedSidecarUntilSourceChanges() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaperFullTextSearchCacheTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileStore = PaperFileStore(applicationSupportDirectory: root)
        let paper = Paper(title: "Cached Paper")
        paper.localDirectoryPath = try fileStore.directory(for: paper.id).path
        let htmlURL = try fileStore.write(Data(Self.sampleHTML.utf8), named: "paper.html", for: paper.id)
        let attachment = PaperAttachment(
            paperID: paper.id,
            kind: .html,
            source: .webPage,
            filename: "paper.html",
            filePath: htmlURL.path
        )
        let service = PaperFullTextSearchService(fileStore: fileStore)

        let first = try XCTUnwrap(service.rebuild(paper: paper, attachments: [attachment]))
        let cached = try XCTUnwrap(service.loadOrRebuild(paper: paper, attachments: [attachment]))
        XCTAssertEqual(cached.createdAt, first.createdAt)

        var changedHTML = try String(contentsOf: htmlURL, encoding: .utf8)
        changedHTML = changedHTML.replacingOccurrences(of: "held-out benchmark", with: "new external dataset")
        try changedHTML.write(to: htmlURL, atomically: true, encoding: .utf8)
        let rebuilt = try XCTUnwrap(service.loadOrRebuild(paper: paper, attachments: [attachment]))
        XCTAssertNotEqual(rebuilt.sourceFingerprint, first.sourceFingerprint)
        XCTAssertTrue(rebuilt.blocks.contains(where: { $0.text.contains("new external dataset") }))
    }

    /// A scanned PDF has no text; its corrected transcription has the text, page for page.
    @MainActor
    func testPDFIndexPrefersTheScanTranscriptionText() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaperFullTextSearchTranscriptionTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileStore = PaperFileStore(applicationSupportDirectory: root)
        let paper = Paper(title: "Scanned Paper")
        let directory = try fileStore.directory(for: paper.id)
        paper.localDirectoryPath = directory.path
        let scanURL = directory.appendingPathComponent("paper.pdf")
        try Self.makePDF(at: scanURL, pages: ["", ""])
        let transcriptionURL = directory.appendingPathComponent("transcription.pdf")
        try Self.makePDF(at: transcriptionURL, pages: ["Applicative languages define functions", "by recursion equations"])
        let scan = PaperAttachment(paperID: paper.id, kind: .pdf, source: .localImport, filename: "paper.pdf", filePath: scanURL.path)
        let transcription = PaperAttachment(
            paperID: paper.id, kind: .resource, source: .scanRebuild, filename: "transcription.pdf", filePath: transcriptionURL.path
        )
        let service = PaperFullTextSearchService(fileStore: fileStore)

        let index = try XCTUnwrap(service.loadOrRebuild(paper: paper, attachments: [scan, transcription]))
        XCTAssertEqual(index.blocks.map(\.pageIndex), [0, 1])
        XCTAssertEqual(Set(index.blocks.map(\.attachmentID)), [transcription.id])
        let hit = try XCTUnwrap(service.search(query: "recursion equations", in: index, topK: 1).first)
        XCTAssertEqual(hit.block.pageIndex, 1)

        try FileManager.default.removeItem(at: transcriptionURL)
        let withoutTranscription = try XCTUnwrap(service.rebuild(paper: paper, attachments: [scan, transcription]))
        XCTAssertTrue(withoutTranscription.blocks.isEmpty)
    }

    private static func makePDF(at url: URL, pages: [String]) throws {
        var box = CGRect(x: 0, y: 0, width: 300, height: 400)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        for text in pages {
            context.beginPDFPage(nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Times-Roman" as CFString, 11, nil),
            ]))
            context.textPosition = CGPoint(x: 30, y: 340)
            CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF()
    }

    @MainActor
    func testKeywordMatchPotentialRecognizesCrossLanguageMismatch() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaperFullTextSearchServiceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileStore = PaperFileStore(applicationSupportDirectory: root)
        let paper = Paper(title: "Structured Paper")
        paper.localDirectoryPath = try fileStore.directory(for: paper.id).path
        let htmlURL = try fileStore.write(Data(Self.sampleHTML.utf8), named: "paper.html", for: paper.id)
        let attachment = PaperAttachment(
            paperID: paper.id,
            kind: .html,
            source: .webPage,
            filename: "paper.html",
            filePath: htmlURL.path
        )
        let service = PaperFullTextSearchService(fileStore: fileStore)
        let index = try XCTUnwrap(service.rebuild(paper: paper, attachments: [attachment]))

        XCTAssertTrue(PaperFullTextSearchService.canKeywordMatch(
            query: "held-out benchmark validation",
            in: index
        ))
        XCTAssertFalse(PaperFullTextSearchService.canKeywordMatch(
            query: "作者使用了什么方法",
            in: index
        ))
    }

    private static let sampleHTML = """
    <!doctype html>
    <html><head><meta charset="UTF-8"></head><body>
      <h1>Methods</h1>
      <p>The model uses a constrained decoder.</p>
      <h2>Evaluation</h2>
      <p>We validate the conclusion on a held-out benchmark.</p>
      <p class="rp-translation-block" data-rp-translation="true">已有译文</p>
      <figcaption>Figure 2: Accuracy on the benchmark.</figcaption>
      <ul><li>Ablation confirms the decoder contribution.</li></ul>
    </body></html>
    """
}
