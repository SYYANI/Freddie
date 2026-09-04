import XCTest
@testable import ReadPaper

final class NoteAnchorTests: XCTestCase {
    func testSelectionContextNormalizesQuoteAndAnchor() {
        let attachmentID = UUID()
        let selection = NoteSelectionContext(
            attachmentID: attachmentID,
            quote: "  A  highlighted\n passage  ",
            pageIndex: -4,
            htmlSelector: "  rp-anchor:1/2/3  ",
            localContext: "  Nearby paragraph.  "
        )

        XCTAssertEqual(selection.attachmentID, attachmentID)
        XCTAssertEqual(selection.trimmedQuote, "A highlighted passage")
        XCTAssertEqual(selection.pageIndex, 0)
        XCTAssertEqual(selection.htmlSelector, "rp-anchor:1/2/3")
        XCTAssertEqual(selection.localContext, "Nearby paragraph.")
        XCTAssertTrue(selection.hasAnchor)
    }

    func testNoteNavigationRequestUsesAvailableAnchor() throws {
        let note = Note(
            paperID: UUID(),
            attachmentID: UUID(),
            quote: "Selected quote",
            body: "Body",
            pageIndex: 5,
            htmlSelector: "rp-anchor:4/2"
        )

        let request = try XCTUnwrap(note.navigationRequest)
        XCTAssertEqual(request.attachmentID, note.attachmentID)
        XCTAssertEqual(request.pageIndex, 5)
        XCTAssertEqual(request.htmlSelector, "rp-anchor:4/2")
    }

    func testNoteWithoutAnchorDoesNotProduceNavigationRequest() {
        let note = Note(
            paperID: UUID(),
            quote: "Selected quote",
            body: "Body"
        )

        XCTAssertFalse(note.hasAnchor)
        XCTAssertNil(note.navigationRequest)
    }

    func testSelectionAssistantNotePreservesQuoteResultAndAnchor() {
        let paperID = UUID()
        let attachmentID = UUID()
        let selection = NoteSelectionContext(
            attachmentID: attachmentID,
            quote: " Selected source text ",
            pageIndex: 7,
            htmlSelector: "rp-anchor:2/4",
            localContext: "Nearby text"
        )

        let note = Note.selectionAssistantNote(
            paperID: paperID,
            selection: selection,
            result: "AI explanation"
        )

        XCTAssertEqual(note.paperID, paperID)
        XCTAssertEqual(note.attachmentID, attachmentID)
        XCTAssertEqual(note.quote, "Selected source text")
        XCTAssertEqual(note.body, "AI explanation")
        XCTAssertEqual(note.pageIndex, 7)
        XCTAssertEqual(note.htmlSelector, "rp-anchor:2/4")
    }
}
