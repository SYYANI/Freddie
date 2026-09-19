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
