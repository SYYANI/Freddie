import CoreGraphics
import XCTest
@testable import ReadPaper

final class PDFTextLayerInspectorTests: XCTestCase {
    func testDviStyleType3FontWithoutUnicodeMappingIsRejected() throws {
        // dvips/Distiller bitmap fonts number glyphs in first-use order.
        let document = try makeDocument(fonts: [
            type3Font(differences: "0 /a0 /a1 /a2 /a3", glyphNames: ["a0", "a1", "a2", "a3"]),
        ])

        XCTAssertEqual(PDFTextLayerInspector().inspect(document), .undecodableFonts)
    }

    func testType3FontWithAdobeGlyphNamesIsAccepted() throws {
        let document = try makeDocument(fonts: [
            type3Font(differences: "65 /A /B /C", glyphNames: ["A", "B", "C"]),
        ])

        XCTAssertEqual(PDFTextLayerInspector().inspect(document), .extractable)
    }

    func testPdfTeXStyleType3FontKeepingLetterCodesIsAccepted() throws {
        let document = try makeDocument(fonts: [
            type3Font(differences: "97 /a97 /a98 /a99", glyphNames: ["a97", "a98", "a99"]),
        ])

        XCTAssertEqual(PDFTextLayerInspector().inspect(document), .extractable)
    }

    func testType3FontWithToUnicodeIsAccepted() throws {
        let document = try makeDocument(fonts: [
            type3Font(differences: "0 /a0 /a1", glyphNames: ["a0", "a1"], extra: "/ToUnicode 5 0 R"),
        ])

        XCTAssertEqual(PDFTextLayerInspector().inspect(document), .extractable)
    }

    func testOneDecodableFontIsEnoughToAllowTranslation() throws {
        let document = try makeDocument(fonts: [
            type3Font(differences: "0 /a0 /a1", glyphNames: ["a0", "a1"]),
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        ])

        XCTAssertEqual(PDFTextLayerInspector().inspect(document), .extractable)
    }

    func testPageWithoutFontsIsRejected() throws {
        let document = try makeDocument(fonts: [])

        XCTAssertEqual(PDFTextLayerInspector().inspect(document), .noFonts)
    }

    func testFontsInheritedFromPageTreeAreInspected() throws {
        let document = try makeDocument(
            fonts: ["<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"],
            resourcesOnPagesNode: true
        )

        XCTAssertEqual(PDFTextLayerInspector().inspect(document), .extractable)
    }

    func testRequireExtractableTextThrowsForUndecodableDocument() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try makePDFData(fonts: [
            type3Font(differences: "0 /a0", glyphNames: ["a0"]),
        ]).write(to: url)

        XCTAssertThrowsError(try PDFTextLayerInspector().requireExtractableText(at: url)) { error in
            XCTAssertEqual(error as? PDFTextLayerError, .noExtractableText)
        }
    }

    func testGlyphNameClassification() {
        for name in ["A", "z", "fi", "eacute", "Udieresis", "uni4E2D", "u1F600", "one", "A.sc", "f_i"] {
            XCTAssertTrue(PDFGlyphName.isMeaningful(name), name)
        }
        for name in ["a0", "a12", "g37", "cid123", ".notdef", "", "uniXYZW"] {
            XCTAssertFalse(PDFGlyphName.isMeaningful(name), name)
        }
    }

    // MARK: - Fixtures

    private func type3Font(differences: String, glyphNames: [String], extra: String = "") -> String {
        let charProcs = glyphNames.map { "/\($0) 4 0 R" }.joined(separator: " ")
        return """
        << /Type /Font /Subtype /Type3 /FontBBox [0 0 1000 1000] /FontMatrix [0.001 0 0 0.001 0 0] \
        /CharProcs << \(charProcs) >> /Encoding << /Type /Encoding /Differences [\(differences)] >> \
        /FirstChar 0 /LastChar 255 /Widths [] \(extra) >>
        """
    }

    private func makeDocument(fonts: [String], resourcesOnPagesNode: Bool = false) throws -> CGPDFDocument {
        let data = try makePDFData(fonts: fonts, resourcesOnPagesNode: resourcesOnPagesNode)
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        return try XCTUnwrap(CGPDFDocument(provider))
    }

    /// Objects 1-3 are the catalog, page tree and page; 4 is a shared empty
    /// glyph procedure, 5 a stub ToUnicode stream, fonts start at 6.
    private func makePDFData(fonts: [String], resourcesOnPagesNode: Bool = false) throws -> Data {
        let fontEntries = fonts.indices.map { "/F\($0) \($0 + 6) 0 R" }.joined(separator: " ")
        let resources = "/Resources << /Font << \(fontEntries) >> >>"
        var objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 \(resourcesOnPagesNode ? resources : "") >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] \(resourcesOnPagesNode ? "" : resources) >>",
            "<< /Length 0 >>\nstream\n\nendstream",
            "<< /Length 0 >>\nstream\n\nendstream",
        ]
        objects.append(contentsOf: fonts)

        var output = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(output.utf8.count)
            output += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xrefOffset = output.utf8.count
        output += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets {
            output += String(format: "%010d 00000 n \n", offset)
        }
        output += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xrefOffset)\n%%EOF\n"
        return Data(output.utf8)
    }
}
