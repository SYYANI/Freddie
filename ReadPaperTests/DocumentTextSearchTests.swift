import AppKit
import PDFKit
import XCTest
@testable import ReadPaper

final class DocumentTextSearchTests: XCTestCase {
    // MARK: - PDF spacing artifacts

    func testFindsWordSplitByExtraSpaces() {
        XCTAssertEqual(
            matchedStrings("transformer", in: "The T ransformer model"),
            ["T ransformer"]
        )
        XCTAssertEqual(matchedStrings("effect", in: "the e ff ect of"), ["e ff ect"])
    }

    func testFindsPhraseWhenPDFDroppedTheSpace() {
        let text = "we use theattention layer and the attention head"
        XCTAssertEqual(matchedStrings("the attention", in: text), ["theattention", "the attention"])
        XCTAssertEqual(
            DocumentSearchText(text).matches(of: "the attention").map(\.kind),
            [.spacingTolerant, .exact]
        )
    }

    func testFindsWordsAcrossLineBreaksAndHyphenation() {
        XCTAssertEqual(matchedStrings("attention", in: "multi-head atten-\ntion is"), ["atten-\ntion"])
        XCTAssertEqual(matchedStrings("neural network", in: "a neural\nnetwork"), ["neural\nnetwork"])
        XCTAssertEqual(matchedStrings("pre-training", in: "pre-\ntraining and pretraining"), ["pre-\ntraining", "pretraining"])
    }

    func testNormalizesLigaturesQuotesDashesAndDetachedAccents() {
        XCTAssertEqual(matchedStrings("fine-tuning", in: "ﬁne-tuning"), ["ﬁne-tuning"])
        XCTAssertEqual(matchedStrings("don't", in: "don’t stop"), ["don’t"])
        XCTAssertEqual(matchedStrings("2019-2020", in: "from 2019–2020"), ["2019–2020"])
        XCTAssertEqual(matchedStrings("naive", in: "a na¨ıve and naïve baseline"), ["na¨ıve", "naïve"])
    }

    func testIgnoresLayoutSpacesBetweenCJKCharacters() {
        XCTAssertEqual(matchedStrings("注意力", in: "使用 注 意 力 机制"), ["注 意 力"])
        XCTAssertEqual(
            DocumentSearchText("使用 注 意 力 机制").matches(of: "注意力").map(\.kind),
            [.exact]
        )
    }

    // MARK: - Precision guards

    func testShortQueriesDoNotMatchAcrossUnrelatedWords() {
        XCTAssertEqual(matchedStrings("form", in: "for model"), [])
        XCTAssertEqual(matchedStrings("form", in: "transformation form"), ["form", "form"])
        XCTAssertEqual(matchedStrings("at", in: "a table"), [])
    }

    func testMatchesNeverCrossHardBreaks() {
        let text = "the end\(DocumentSearchText.hardBreak)of"
        XCTAssertEqual(DocumentSearchText(text).matches(of: "end of"), [])
        XCTAssertEqual(DocumentSearchText(text).matches(of: "endof"), [])
    }

    func testEmptyOrSeparatorOnlyQueriesHaveNoMatches() {
        XCTAssertEqual(DocumentSearchText("a - b").matches(of: "  "), [])
        XCTAssertEqual(DocumentSearchText("a - b").matches(of: "-"), [])
    }

    // MARK: - Options

    func testMatchCaseOption() {
        XCTAssertEqual(matchedStrings("BERT", in: "bert and BERT"), ["bert", "BERT"])
        XCTAssertEqual(matchedStrings("BERT", in: "bert and BERT", options: .init(matchCase: true)), ["BERT"])
    }

    func testWholeWordsOption() {
        let text = "network net neural-net nets"
        XCTAssertEqual(matchedStrings("net", in: text, options: .init(wholeWords: true)), ["net", "net"])
        XCTAssertEqual(
            matchedStrings("transformer", in: "a T ransformer block", options: .init(wholeWords: true)),
            ["T ransformer"]
        )
    }

    // MARK: - Segmented (HTML) text

    func testSegmentMatchesSpanInlineNodesButNotBlocks() {
        let text = DocumentSearchSegmentedText(
            segments: ["Self-atten", "tion is", "all you need"],
            breaksBefore: [false, false, true]
        )

        XCTAssertEqual(text.matches(of: "attention"), [
            .init(start: .init(segment: 0, offset: 5), end: .init(segment: 1, offset: 4), kind: .exact),
        ])
        XCTAssertEqual(text.matches(of: "is all"), [])
        XCTAssertEqual(text.matches(of: "you"), [
            .init(start: .init(segment: 2, offset: 4), end: .init(segment: 2, offset: 7), kind: .exact),
        ])
    }

    func testSegmentOffsetsUseUTF16Units() {
        let text = DocumentSearchSegmentedText(segments: ["😀 数据", "集 set"], breaksBefore: [false, false])

        XCTAssertEqual(text.matches(of: "数据集"), [
            .init(start: .init(segment: 0, offset: 3), end: .init(segment: 1, offset: 1), kind: .exact),
        ])
    }

    // MARK: - PDFKit integration

    @MainActor
    func testPDFPageMatchesMapToSelectableRanges() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentTextSearchTests-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try makePDF(lines: [["Multi-head atten-", "tion is used."], ["No match here."]]).write(to: url)

        let loadedPages = await PDFDocumentSearchTextLoader.loadPages(from: url)
        let pages = try XCTUnwrap(loadedPages)
        XCTAssertEqual(pages.count, 2)
        let matches = pages[0].matches(of: "attention")
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(pages[1].matches(of: "attention"), [])

        let document = try XCTUnwrap(PDFDocument(url: url))
        let selection = try XCTUnwrap(document.page(at: 0)?.selection(for: try XCTUnwrap(matches.first).sourceRange))
        let selectedText = try XCTUnwrap(selection.string)
            .components(separatedBy: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-")))
            .joined()
        XCTAssertEqual(selectedText, "attention")
    }

    // MARK: - Helpers

    private func matchedStrings(
        _ query: String,
        in text: String,
        options: DocumentSearchOptions = DocumentSearchOptions()
    ) -> [String] {
        let source = text as NSString
        return DocumentSearchText(text)
            .matches(of: query, options: options)
            .map { source.substring(with: $0.sourceRange) }
    }

    private func makePDF(lines pages: [[String]]) throws -> Data {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 320, height: 160)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))

        for lines in pages {
            context.beginPDFPage(nil)
            for (index, line) in lines.enumerated() {
                let text = NSAttributedString(
                    string: line,
                    attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.black]
                )
                context.textPosition = CGPoint(x: 20, y: 120 - CGFloat(index) * 24)
                CTLineDraw(CTLineCreateWithAttributedString(text as CFAttributedString), context)
            }
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }
}
