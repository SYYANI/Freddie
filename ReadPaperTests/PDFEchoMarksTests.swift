import PDFKit
import XCTest
@testable import ReadPaper

final class PDFEchoMarksTests: XCTestCase {
    /// A line 12pt high, its top at `top` (page coordinates, origin at the bottom left).
    private func line(_ text: String, x: CGFloat = 72, top: CGFloat, width: CGFloat = 220) -> PDFEchoLine {
        PDFEchoLine(bounds: CGRect(x: x, y: top - 12, width: width, height: 12), text: text)
    }

    func testLinesGroupIntoParagraphsAtGapsIndentsAndColumns() {
        let lines = [
            line("First paragraph starts here and", top: 700),
            line("goes on.", top: 686, width: 60),
            // Indented after a short line: a new paragraph without a gap.
            line("Second paragraph is indented and", x: 84, top: 672, width: 208),
            line("continues.", top: 658, width: 80),
            // A gap taller than a line.
            line("Third after a gap.", top: 620),
            // Back up the page in another column.
            line("Right column text.", x: 320, top: 700),
        ]

        let paragraphs = PDFEchoParagraphs.group(lines, pageIndex: 3)

        XCTAssertEqual(paragraphs.map(\.text), [
            "First paragraph starts here and goes on.",
            "Second paragraph is indented and continues.",
            "Third after a gap.",
            "Right column text.",
        ])
        XCTAssertEqual(paragraphs.map(\.id), ["p3-0", "p3-1", "p3-2", "p3-3"])
        XCTAssertEqual(paragraphs[0].firstLine, lines[0].bounds)
        XCTAssertEqual(PDFEchoParagraphs.pageIndex(of: "p3-2"), 3)
        XCTAssertNil(PDFEchoParagraphs.pageIndex(of: "rp-anchor:1"))
    }

    func testAHeadingIsNotPartOfTheParagraphBelowIt() {
        let heading = PDFEchoLine(bounds: CGRect(x: 72, y: 686, width: 120, height: 16), text: "2 Background")
        let lines = [heading, line("Body text right under the heading", top: 684), line("and its second line.", top: 670)]

        XCTAssertEqual(PDFEchoParagraphs.group(lines, pageIndex: 0).map(\.text), [
            "2 Background",
            "Body text right under the heading and its second line.",
        ])

        // A line made taller by inline math stays in its paragraph.
        let math = [
            line("Everyone learns many operations in school: fractions,", top: 700, width: 468),
            // Reaches 4pt into the line above.
            PDFEchoLine(bounds: CGRect(x: 72, y: 666, width: 468, height: 26), text: "roots and ∑ sums, each with its own"),
            line("button on a scientific calculator.", top: 670),
        ]
        XCTAssertEqual(PDFEchoParagraphs.group(math, pageIndex: 0).count, 1)

        // Same size as the text, but alone and short.
        let sameSize = [line("3 Method", top: 700, width: 60), line("We start from a pretrained model and", top: 684)]
        XCTAssertEqual(PDFEchoParagraphs.group(sameSize, pageIndex: 0).count, 2)
    }

    func testPiecesOfOnePrintedLineAreOneLineButTableCellsAreNot() {
        let pieces = [
            line("trigonometric functions (+, −", x: 72, top: 700, width: 150),
            line(", ×, /, sin, cos) each with its own", x: 224, top: 701, width: 300),
            line("button on a calculator.", top: 686),
        ]
        XCTAssertEqual(PDFEchoParagraphs.group(pieces, pageIndex: 0).map(\.text), [
            "trigonometric functions (+, − , ×, /, sin, cos) each with its own button on a calculator.",
        ])

        let row = [line("Dimension", x: 86, top: 700, width: 45), line("Evidence", x: 220, top: 700, width: 47)]
        XCTAssertEqual(PDFEchoParagraphs.mergingPiecesOfALine(row).count, 2)
    }

    func testADenseColumnIsCutSoMarksStayNearTheirPassage() {
        let lines = (0..<30).map { line("Line \($0) of a column without breaks", top: 700 - CGFloat($0) * 14) }

        let paragraphs = PDFEchoParagraphs.group(lines, pageIndex: 0)

        XCTAssertEqual(paragraphs.count, 3)
        XCTAssertEqual(paragraphs.map { $0.text.components(separatedBy: "Line ").count - 1 }, [12, 12, 6])
    }

    func testMarksSitInTheMarginOnTheSideOfTheirColumn() {
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        func paragraph(x: CGFloat, width: CGFloat) -> PDFEchoParagraph {
            let first = CGRect(x: x, y: 688, width: width, height: 12)
            return PDFEchoParagraph(id: "p0-0", pageIndex: 0, text: "", bounds: first.union(first.offsetBy(dx: 0, dy: -40)), firstLine: first)
        }

        let single = PDFEchoParagraphs.markRect(for: paragraph(x: 72, width: 468), pageBounds: page)
        XCTAssertEqual(single.maxX, 64, "Left of a full-width column")
        XCTAssertEqual(single.midY, 694, "Centred on the first line")

        let left = PDFEchoParagraphs.markRect(for: paragraph(x: 54, width: 240), pageBounds: page)
        XCTAssertEqual(left.maxX, 46)
        let right = PDFEchoParagraphs.markRect(for: paragraph(x: 318, width: 240), pageBounds: page)
        XCTAssertEqual(right.minX, 566, "The outer margin for a right-hand column")

        let edge = PDFEchoParagraphs.markRect(for: paragraph(x: 4, width: 604), pageBounds: page)
        XCTAssertTrue(page.contains(edge), "Never off the page")
    }

    func testMarkAnnotationsAreNotPrinted() {
        let mark = PDFEchoMarkAnnotation(bounds: CGRect(x: 0, y: 0, width: 16, height: 16), blockID: "p0-0", isSeen: true)
        XCTAssertFalse(mark.shouldPrint)
        XCTAssertEqual(mark.blockID, "p0-0")
        XCTAssertTrue(mark.isSeen)
    }
}
