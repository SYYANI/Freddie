import PDFKit
import XCTest
@testable import ReadPaper

final class PDFWordSpacingTests: XCTestCase {
    /// Justified text the way pdfTeX writes it: words in one `TJ`, separated by
    /// 0.3 em offsets and no space characters, in a font whose unused code 32 is wide.
    private let justifiedLine = "[(An)-300(architectural)-300(change)-300(touches)] TJ"

    func testRestoresSpacesPDFKitDropsWhenCodeThirtyTwoIsWide() throws {
        let page = try makePage(content: "BT /F1 10 Tf 72 700 Td \(justifiedLine) ET")
        try XCTSkipIf(
            page.string?.contains(" ") == true,
            "PDFKit now spaces this line itself"
        )

        XCTAssertEqual(PDFWordSpacing.text(of: page), "An architectural change touches")
    }

    func testSelectionTextGainsSpaces() throws {
        let page = try makePage(content: "BT /F1 10 Tf 72 700 Td \(justifiedLine) ET")
        let pageText = try XCTUnwrap(page.string) as NSString
        let range = pageText.range(of: "architecturalchange")
        try XCTSkipIf(range.location == NSNotFound, "PDFKit now spaces this line itself")

        let selection = try XCTUnwrap(page.selection(for: range))
        XCTAssertEqual(PDFWordSpacing.text(of: selection), "architectural change")
    }

    func testLeavesEvenlyLetterspacedTextWhole() throws {
        let page = try makePage(content: """
        BT /F1 10 Tf 72 700 Td [(T)-300(R)-300(A)-300(C)-300(K)-300(E)-300(D)] TJ ET
        """)
        let original = try XCTUnwrap(page.string)

        XCTAssertEqual(PDFWordSpacing.text(of: page), original)
    }

    func testLeavesTextWithSpaceCharactersUnchanged() throws {
        let page = try makePage(
            content: "BT /F1 10 Tf 72 700 Td (An architectural change) Tj ET",
            spaceWidth: 600
        )

        XCTAssertEqual(PDFWordSpacing.text(of: page), page.string)
    }

    func testMeasuresGapsFromTextMatrixAndTJOffsets() throws {
        let page = try makePage(content: """
        BT /F1 10 Tf 2 0 0 1 72 700 Tm [(ab)-300(cd)] TJ ET
        """)
        let layout = PDFWordSpacing.layout(of: try XCTUnwrap(page.pageRef))

        XCTAssertEqual(layout.glyphs.count, 4)
        let gap = try XCTUnwrap(layout.gaps.first)
        XCTAssertEqual(layout.gaps.count, 1)
        // Two 6 pt glyphs at double horizontal scale, then a 3 pt TJ offset, also doubled.
        XCTAssertEqual(gap.minX, 72 + 24, accuracy: 0.001)
        XCTAssertEqual(gap.width, 6, accuracy: 0.001)
        XCTAssertEqual(gap.baseline, 700, accuracy: 0.001)
    }

    // MARK: - Fixture

    private func makePage(content: String, spaceWidth: Int = 2000) throws -> PDFPage {
        let document = try XCTUnwrap(PDFDocument(data: Self.pdf(content: content, spaceWidth: spaceWidth)))
        return try XCTUnwrap(document.page(at: 0))
    }

    /// One page in Courier with explicit widths: 600 per glyph, `spaceWidth` for code 32.
    private static func pdf(content: String, spaceWidth: Int) -> Data {
        let widths = ([spaceWidth] + Array(repeating: 600, count: 94)).map(String.init).joined(separator: " ")
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Courier /FirstChar 32 /LastChar 126 /Widths [\(widths)] /Encoding /WinAnsiEncoding >>",
        ]
        var pdf = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(pdf.utf8.count)
            pdf += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xref = pdf.utf8.count
        pdf += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets {
            pdf += String(format: "%010d 00000 n \n", offset)
        }
        pdf += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(pdf.utf8)
    }
}
