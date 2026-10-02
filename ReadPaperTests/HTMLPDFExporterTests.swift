import PDFKit
import XCTest
@testable import ReadPaper

final class HTMLPDFExporterTests: XCTestCase {
    @MainActor
    func testExportsAllDisplayModesAndPaginatesWholeDocument() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("paper.html")
        let resources = directory.appendingPathComponent("Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try """
        <svg xmlns="http://www.w3.org/2000/svg" width="100" height="100">
        <rect width="100" height="100" fill="red"/></svg>
        """.write(to: resources.appendingPathComponent("figure.svg"), atomically: true, encoding: .utf8)
        let paragraphs = (0..<90).map {
            "<p>Paragraph \($0): This is a long article that must span multiple printed pages.</p>"
        }.joined()
        let html = """
        <!doctype html><html><head><meta charset="UTF-8"></head><body>
        <p data-rp-source="true">OriginalOnlyMarker</p>
        <p class="rp-translation-block">TranslationOnlyMarker</p>
        <img loading="lazy" src="Resources/figure.svg" width="100" height="100">
        \(paragraphs)<p>EndOfDocumentMarker</p>
        </body></html>
        """
        try html.write(to: sourceURL, atomically: true, encoding: .utf8)

        for mode in TranslationDisplayMode.allCases {
            let destination = directory.appendingPathComponent("\(mode.rawValue).pdf")
            try await HTMLPDFExporter().export(
                sourceURL: sourceURL, displayMode: mode, fontSize: 17, destinationURL: destination
            )
            let pdf = try XCTUnwrap(PDFDocument(url: destination))
            let text = try XCTUnwrap(pdf.string)
            XCTAssertGreaterThan(pdf.pageCount, 1)
            XCTAssertTrue(text.contains("EndOfDocumentMarker"))
            XCTAssertEqual(text.contains("OriginalOnlyMarker"), mode != .translated)
            XCTAssertEqual(text.contains("TranslationOnlyMarker"), mode != .original)
            let firstPage = try XCTUnwrap(pdf.page(at: 0))
            XCTAssertEqual(firstPage.bounds(for: .mediaBox).height, 841.89, accuracy: 1)
            let preview = firstPage.thumbnail(of: NSSize(width: 300, height: 425), for: .mediaBox)
            let pixels = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(preview.tiffRepresentation)))
            let containsRedImage = stride(from: 0, to: pixels.pixelsHigh, by: 5).contains { y in
                stride(from: 0, to: pixels.pixelsWide, by: 5).contains { x in
                    guard let color = pixels.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
                    return color.redComponent > 0.6
                        && color.redComponent > 2 * color.greenComponent
                        && color.redComponent > 2 * color.blueComponent
                }
            }
            XCTAssertTrue(containsRedImage, "The localized image should be rendered into the PDF")
        }
        XCTAssertEqual(try String(contentsOf: sourceURL, encoding: .utf8), html)
    }

    @MainActor
    func testMissingSourcePreservesExistingDestination() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("existing.pdf")
        let original = Data("existing export".utf8)
        try original.write(to: destination)
        do {
            try await HTMLPDFExporter().export(
                sourceURL: directory.appendingPathComponent("missing.html"),
                displayMode: .original, fontSize: 17, destinationURL: destination
            )
            XCTFail("Expected missing source to fail")
        } catch {
            XCTAssertEqual(try Data(contentsOf: destination), original)
        }
    }
}
