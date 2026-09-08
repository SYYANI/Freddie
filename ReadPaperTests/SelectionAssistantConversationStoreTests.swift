import Foundation
import XCTest
@testable import ReadPaper

final class SelectionAssistantConversationStoreTests: XCTestCase {
    @MainActor
    func testConversationRoundTripsByPaperAndSelectionWithoutSwiftData() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SelectionAssistantConversationStoreTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileStore = PaperFileStore(applicationSupportDirectory: root)
        let store = SelectionAssistantConversationStore(fileStore: fileStore)
        let paperID = UUID()
        let source = AssistantSource(
            id: "source",
            kind: .paperHTML,
            title: "§3 Method",
            excerpt: "Supporting evidence.",
            attachmentID: UUID(),
            htmlSelector: "[data-rp-assistant-block-id=\"source\"]"
        )
        let snapshot = SelectionAssistantConversationSnapshot(
            selectionIdentity: "selection-identity",
            attachmentID: source.attachmentID,
            quote: "Supporting evidence.",
            htmlSelector: source.htmlSelector,
            action: .ask,
            scope: .fullPaper,
            turns: [
                SelectionAssistantConversationTurn(
                    question: "Where is the evidence?",
                    result: SelectionAssistantResult(
                        answer: "It appears in the method [S1].",
                        sources: [source],
                        scope: .fullPaper
                    )
                )
            ]
        )

        try store.save(snapshot, paperID: paperID)
        let loaded = try XCTUnwrap(store.conversation(
            paperID: paperID,
            selectionIdentity: snapshot.selectionIdentity
        ))

        XCTAssertEqual(loaded.action, .ask)
        XCTAssertEqual(loaded.scope, .fullPaper)
        XCTAssertEqual(loaded.turns.first?.answer, "It appears in the method [S1].")
        XCTAssertEqual(loaded.turns.first?.result.sources.first?.htmlSelector, source.htmlSelector)
        let historyAnchor = try XCTUnwrap(store.historyAnchors(
            paperID: paperID,
            attachmentID: source.attachmentID
        ).first)
        XCTAssertEqual(historyAnchor.quote, "Supporting evidence.")
        XCTAssertEqual(historyAnchor.htmlSelector, source.htmlSelector)
    }
}
