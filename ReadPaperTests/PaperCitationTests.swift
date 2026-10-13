import XCTest
@testable import ReadPaper

final class PaperCitationTests: XCTestCase {
    private let paperID = UUID(uuidString: "9F2C6A1E-5B7D-4C1F-8E2A-3D4B5C6D7E8F")!
    private let attachmentID = UUID(uuidString: "2B71E0C4-1A2B-4C3D-9E8F-0A1B2C3D4E5F")!

    func testPDFCitationRoundTripsThroughItsLink() throws {
        let citation = PaperCitation(
            paperID: paperID,
            attachmentID: attachmentID,
            pageIndex: 1,
            quotePrefix: "based solely on attention mechanisms, dispensing with recurrence"
        )

        let destination = citation.linkDestination
        XCTAssertEqual(destination, "readpaper://paper/\(paperID.uuidString)?att=\(attachmentID.uuidString)&p=2")
        XCTAssertEqual(citation.linkTitle, "based solely on attention mechanisms, di")
        XCTAssertEqual(PaperCitation(linkDestination: destination, title: citation.linkTitle), citation)
    }

    /// The quote stays readable in the title; the destination is ASCII, which every
    /// Markdown app and `URL` parse the same way.
    func testHTMLCitationLinksStayASCII() throws {
        let citation = PaperCitation(
            paperID: paperID,
            attachmentID: attachmentID,
            htmlSelector: "rp-anchor:0/4/12/3",
            quotePrefix: "注意力机制（Attention）[1] 是核心"
        )

        let destination = citation.linkDestination
        XCTAssertEqual(destination, "readpaper://paper/\(paperID.uuidString)?att=\(attachmentID.uuidString)&anchor=rp-anchor:0/4/12/3")
        XCTAssertEqual(try XCTUnwrap(URL(string: destination)).absoluteString, destination)
        XCTAssertEqual(PaperCitation(linkDestination: destination, title: citation.linkTitle), citation)

        let unusualAnchor = PaperCitation(paperID: paperID, htmlSelector: "[data-id=\"段落 1\"]")
        XCTAssertTrue(unusualAnchor.linkDestination.allSatisfy(\.isASCII), unusualAnchor.linkDestination)
        XCTAssertEqual(PaperCitation(linkDestination: unusualAnchor.linkDestination), unusualAnchor)
    }

    func testLegacyQuoteParameterAndAngleBracketsStillParse() throws {
        let parsed = PaperCitation(linkDestination: "<readpaper://paper/\(paperID.uuidString)?p=1&q=%E4%B8%AD%E6%96%87%20%E5%BC%95%E7%94%A8>")
        XCTAssertEqual(parsed, PaperCitation(paperID: paperID, pageIndex: 0, quotePrefix: "中文 引用"))
    }

    func testInvalidLinksAreRejectedAndUnknownParametersIgnored() {
        XCTAssertNil(PaperCitation(linkDestination: "https://arxiv.org/abs/1706.03762"))
        XCTAssertNil(PaperCitation(linkDestination: "readpaper://paper/not-a-uuid?p=2"))
        XCTAssertNil(PaperCitation(linkDestination: "readpaper://note/\(paperID.uuidString)"))

        let parsed = PaperCitation(linkDestination: "READPAPER://paper/\(paperID.uuidString)?p=0&future=1&q=%E4")
        XCTAssertEqual(parsed?.paperID, paperID)
        XCTAssertNil(parsed?.pageIndex)
        XCTAssertEqual(parsed?.quotePrefix, "%E4")
    }

    func testCitationsAreFoundInMarkdownInOrder() {
        let other = UUID()
        let markdown = """
        # Review

        > A quote
        >
        > — [Vaswani et al., 2017, p. 2](readpaper://paper/\(paperID.uuidString)?p=2 "A quote")

        As shown by [Ho 2020](readpaper://paper/\(other.uuidString)) and [again](<readpaper://paper/\(paperID.uuidString)>),
        see [the web](https://example.com).
        """

        let citations = PaperCitation.citations(in: markdown)
        XCTAssertEqual(citations.map(\.paperID), [paperID, other, paperID])
        XCTAssertEqual(citations.first?.pageIndex, 1)
        XCTAssertEqual(PaperCitation.citedPaperIDs(in: markdown), [paperID, other])
    }

    func testNavigationRequestCarriesThePaperAndPrefersTheFullQuote() {
        let citation = PaperCitation(paperID: paperID, attachmentID: attachmentID, pageIndex: 3, quotePrefix: "Short prefix")

        let fromPrefix = citation.navigationRequest()
        XCTAssertEqual(fromPrefix.paperID, paperID)
        XCTAssertEqual(fromPrefix.attachmentID, attachmentID)
        XCTAssertEqual(fromPrefix.pageIndex, 3)
        XCTAssertEqual(fromPrefix.quote, "Short prefix")

        XCTAssertEqual(citation.navigationRequest(quote: "Short prefix  and the rest").quote, "Short prefix and the rest")
    }

    func testLabelsUseFamilyNamesYearAndPage() {
        XCTAssertEqual(
            PaperCitation.label(authors: ["Ashish Vaswani", "Noam Shazeer", "Niki Parmar"], title: "Attention", year: 2017, pageIndex: 1),
            "Vaswani et al., 2017, p. 2"
        )
        XCTAssertEqual(
            PaperCitation.label(authors: ["Ho, Jonathan", "Ajay Jain"], title: "Diffusion", year: 2020, pageIndex: nil),
            "Ho & Jain, 2020"
        )
        XCTAssertEqual(PaperCitation.label(authors: ["张 三", "李四", "王五"], title: "", year: nil, pageIndex: nil), "张三等")
        XCTAssertEqual(
            PaperCitation.label(authors: [], title: "A Very Long Title That Keeps Going On And On", year: nil, pageIndex: 0),
            "A Very Long Title That Keeps Goi…, p. 1"
        )
    }

    func testQuoteMarkdownEscapesTextThatWouldBecomeSyntax() {
        let markdown = PaperCitation.quoteMarkdown(
            quote: "1. Results cost $5 for *all* [x]_i ~~not~~",
            label: "Doe [2020]",
            citation: PaperCitation(paperID: paperID)
        )

        XCTAssertEqual(
            markdown,
            "> 1\\. Results cost \\$5 for \\*all\\* \\[x\\]\\_i \\~\\~not\\~\\~\n>\n> — [Doe \\[2020\\]](readpaper://paper/\(paperID.uuidString))"
        )
        XCTAssertEqual(MarkdownEscaping.escapedBlockText("# heading"), "\\# heading")
        XCTAssertEqual(MarkdownEscaping.escapedBlockText("- item"), "\\- item")
        XCTAssertEqual(MarkdownEscaping.escapedBlockText("~5% faster"), "~5% faster")
    }

    func testLinkTitleKeepsQuotesAndReadsBack() throws {
        let citation = PaperCitation(paperID: paperID, pageIndex: 2, quotePrefix: #"called "attention" \ here"#)
        let markdown = PaperCitation.inlineMarkdown(label: "Vaswani", citation: citation)

        XCTAssertEqual(markdown, #"[Vaswani](readpaper://paper/\#(paperID.uuidString)?p=3 "called \"attention\" \\ here")"#)
        let span = try XCTUnwrap(MarkdownLiveSyntax.parse(markdown, fence: nil).line.spans.first)
        guard case let .citation(destination, title) = span.kind else {
            return XCTFail("Expected a citation, got \(span.kind)")
        }
        XCTAssertEqual(PaperCitation(linkDestination: destination, title: title), citation)
    }

    func testEscapedQuoteReadsBackAsThePlainQuote() {
        let quote = "Use *only* the [CLS] token's state, i.e. h_0 — 2. not 3."
        let markdown = "> " + MarkdownEscaping.escapedBlockText(quote)
        let line = MarkdownLiveSyntax.parse(markdown, fence: nil).line

        XCTAssertTrue(line.spans.isEmpty)
        XCTAssertEqual(WritingTitle.visibleText(of: markdown, line: line), quote)
    }
}
