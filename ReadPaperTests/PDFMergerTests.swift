import PDFKit
import XCTest
@testable import ReadPaper

final class PDFMergerTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    // MARK: - Helper Methods

    private func createPDFDocument(withPageCount pageCount: Int) -> PDFDocument {
        let document = PDFDocument()
        for i in 0..<pageCount {
            let page = PDFPage(image: createTestImage(withText: "Page \(i + 1)"))!
            document.insert(page, at: i)
        }
        return document
    }

    private func createTestImage(withText text: String) -> NSImage {
        let size = NSSize(width: 200, height: 100)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.black
        ]
        text.draw(at: NSPoint(x: 10, y: 40), withAttributes: attributes)
        image.unlockFocus()
        return image
    }

    private func savePDFDocument(_ document: PDFDocument, to url: URL) throws {
        guard document.write(to: url) else {
            throw NSError(domain: "PDFMergerTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to write PDF"])
        }
    }

    // MARK: - Tests

    func testMergeWithPDFDocumentParameter() throws {
        // Create existing PDF with 3 pages
        let existingDoc = createPDFDocument(withPageCount: 3)

        // Create increment PDF file with 2 pages
        let incrementDoc = createPDFDocument(withPageCount: 2)
        let incrementURL = tempDirectory.appendingPathComponent("increment.pdf")
        try savePDFDocument(incrementDoc, to: incrementURL)

        // Merge
        let outputURL = tempDirectory.appendingPathComponent("merged.pdf")
        let resultURL = try PDFMerger.merge(existing: existingDoc, increment: incrementURL, output: outputURL)

        // Verify
        XCTAssertEqual(resultURL, outputURL)
        let mergedDoc = PDFDocument(url: resultURL)
        XCTAssertNotNil(mergedDoc)
        XCTAssertEqual(mergedDoc?.pageCount, 5)
    }

    func testMergeWithURLParameter() throws {
        // Create existing PDF file with 4 pages
        let existingDoc = createPDFDocument(withPageCount: 4)
        let existingURL = tempDirectory.appendingPathComponent("existing.pdf")
        try savePDFDocument(existingDoc, to: existingURL)

        // Create increment PDF file with 3 pages
        let incrementDoc = createPDFDocument(withPageCount: 3)
        let incrementURL = tempDirectory.appendingPathComponent("increment.pdf")
        try savePDFDocument(incrementDoc, to: incrementURL)

        // Merge
        let outputURL = tempDirectory.appendingPathComponent("merged.pdf")
        let resultURL = try PDFMerger.merge(existing: existingURL, increment: incrementURL, output: outputURL)

        // Verify
        XCTAssertEqual(resultURL, outputURL)
        let mergedDoc = PDFDocument(url: resultURL)
        XCTAssertNotNil(mergedDoc)
        XCTAssertEqual(mergedDoc?.pageCount, 7)
    }

    func testMergeWithEmptyExistingDocument() throws {
        // Create empty existing PDF
        let existingDoc = PDFDocument()

        // Create increment PDF with 2 pages
        let incrementDoc = createPDFDocument(withPageCount: 2)
        let incrementURL = tempDirectory.appendingPathComponent("increment.pdf")
        try savePDFDocument(incrementDoc, to: incrementURL)

        // Merge
        let outputURL = tempDirectory.appendingPathComponent("merged.pdf")
        let resultURL = try PDFMerger.merge(existing: existingDoc, increment: incrementURL, output: outputURL)

        // Verify only increment pages exist
        let mergedDoc = PDFDocument(url: resultURL)
        XCTAssertNotNil(mergedDoc)
        XCTAssertEqual(mergedDoc?.pageCount, 2)
    }

    func testMergeWithEmptyIncrementDocument() throws {
        // Create existing PDF with 3 pages
        let existingDoc = createPDFDocument(withPageCount: 3)

        // Create empty increment PDF
        let incrementDoc = PDFDocument()
        let incrementURL = tempDirectory.appendingPathComponent("increment.pdf")
        try savePDFDocument(incrementDoc, to: incrementURL)

        // Merge
        let outputURL = tempDirectory.appendingPathComponent("merged.pdf")
        let resultURL = try PDFMerger.merge(existing: existingDoc, increment: incrementURL, output: outputURL)

        // Verify only existing pages exist (empty PDF may still have a placeholder page)
        let mergedDoc = PDFDocument(url: resultURL)
        XCTAssertNotNil(mergedDoc)
        // Empty PDF may be saved with 1 page or 0 pages depending on PDFKit implementation
        // The important thing is the existing pages are preserved
        XCTAssertGreaterThanOrEqual(mergedDoc?.pageCount ?? 0, 3)
    }

    func testMergeFailsWithNonExistentIncrementFile() throws {
        // Create existing PDF
        let existingDoc = createPDFDocument(withPageCount: 3)

        // Use non-existent increment URL
        let nonExistentURL = tempDirectory.appendingPathComponent("nonexistent.pdf")

        // Merge should throw
        let outputURL = tempDirectory.appendingPathComponent("merged.pdf")
        XCTAssertThrowsError(try PDFMerger.merge(existing: existingDoc, increment: nonExistentURL, output: outputURL)) { error in
            guard case PDFMergerError.failedToOpenFile(let path) = error else {
                XCTFail("Expected PDFMergerError.failedToOpenFile, got \(error)")
                return
            }
            XCTAssertEqual(path, nonExistentURL.path)
        }
    }

    func testMergeFailsWithNonExistentExistingFile() throws {
        // Use non-existent existing URL
        let nonExistentURL = tempDirectory.appendingPathComponent("nonexistent.pdf")

        // Create increment PDF
        let incrementDoc = createPDFDocument(withPageCount: 2)
        let incrementURL = tempDirectory.appendingPathComponent("increment.pdf")
        try savePDFDocument(incrementDoc, to: incrementURL)

        // Merge should throw
        let outputURL = tempDirectory.appendingPathComponent("merged.pdf")
        XCTAssertThrowsError(try PDFMerger.merge(existing: nonExistentURL, increment: incrementURL, output: outputURL)) { error in
            guard case PDFMergerError.failedToOpenFile(let path) = error else {
                XCTFail("Expected PDFMergerError.failedToOpenFile, got \(error)")
                return
            }
            XCTAssertEqual(path, nonExistentURL.path)
        }
    }

    func testMergeErrorLocalizedDescription() {
        let openError = PDFMergerError.failedToOpenFile("/path/to/file.pdf")
        XCTAssertNotNil(openError.errorDescription)
        XCTAssertTrue(openError.errorDescription?.contains("file.pdf") ?? false)

        let writeError = PDFMergerError.failedToWriteOutput("/path/to/output.pdf")
        XCTAssertNotNil(writeError.errorDescription)
        XCTAssertTrue(writeError.errorDescription?.contains("output.pdf") ?? false)
    }
}
