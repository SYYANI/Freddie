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
        XCTAssertEqual(request.quote, "Selected quote")
    }

    func testPDFNavigationTextMatcherMapsNormalizedWhitespaceToSourceRange() throws {
        let pageText = "Before  Selected\nquote\tcontinues. After"
        let range = try XCTUnwrap(
            PDFNoteNavigationTextMatcher.range(
                of: " Selected   quote continues. ",
                in: pageText
            )
        )

        XCTAssertEqual((pageText as NSString).substring(with: range), "Selected\nquote\tcontinues.")
    }

    func testPDFNavigationTextMatcherReturnsNilForMissingQuote() {
        XCTAssertNil(PDFNoteNavigationTextMatcher.range(of: "Missing", in: "Page text"))
    }

    func testAssistantSourceUsesDedicatedNavigationQuoteInsteadOfContextExcerpt() throws {
        let source = AssistantSource(
            id: "paper-page-2",
            kind: .paperPDF,
            title: "Page 2",
            excerpt: "Previous page context\n\nExact target passage\n\nNext page context",
            attachmentID: UUID(),
            pageIndex: 1,
            navigationQuote: "Exact target passage"
        )

        let request = try XCTUnwrap(source.navigationRequest)
        XCTAssertEqual(request.quote, "Exact target passage")
        XCTAssertNotNil(PDFNoteNavigationTextMatcher.range(
            of: try XCTUnwrap(request.quote),
            in: "Heading\nExact target passage\nFooter"
        ))
    }

    func testAssistantSourceDecodesLegacyPayloadWithoutNavigationQuote() throws {
        let data = Data(#"""
        {
          "id": "legacy-source",
          "kind": "paperPDF",
          "title": "Page 1",
          "excerpt": "Legacy page excerpt",
          "sectionPath": [],
          "pageIndex": 0,
          "isLowConfidence": true
        }
        """#.utf8)

        let source = try JSONDecoder().decode(AssistantSource.self, from: data)
        XCTAssertNil(source.navigationQuote)
        XCTAssertEqual(source.navigationRequest?.quote, "Legacy page excerpt")
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
