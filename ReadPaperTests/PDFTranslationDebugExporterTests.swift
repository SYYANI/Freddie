#if DEBUG
import PDFKit
import XCTest
@testable import ReadPaper

@MainActor
final class PDFTranslationDebugExporterTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PDFTranslationDebugExporterTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    func testNormalizedBoundsRoundTripAcrossDifferentPageSizes() {
        let translatedPage = CGRect(x: 10, y: 20, width: 600, height: 800)
        let translatedSelection = CGRect(x: 70, y: 100, width: 180, height: 240)
        let originalPage = CGRect(x: 0, y: 0, width: 300, height: 400)

        let normalized = PDFTranslationDebugExporter.normalizedBounds(
            translatedSelection,
            within: translatedPage
        )
        let originalSelection = PDFTranslationDebugExporter.bounds(
            fromNormalized: normalized,
            within: originalPage
        )

        XCTAssertEqual(normalized.minX, 0.1, accuracy: 0.0001)
        XCTAssertEqual(normalized.minY, 0.1, accuracy: 0.0001)
        XCTAssertEqual(originalSelection, CGRect(x: 30, y: 40, width: 90, height: 120))
    }

    func testExportWritesReproductionBundleAndDiagnostics() throws {
        let originalURL = temporaryDirectory.appendingPathComponent("original.pdf")
        let translatedURL = temporaryDirectory.appendingPathComponent("translated.pdf")
        try writeBlankPDF(to: originalURL, pageBounds: CGRect(x: 0, y: 0, width: 300, height: 400))
        try writeBlankPDF(to: translatedURL, pageBounds: CGRect(x: 0, y: 0, width: 600, height: 800))

        let diagnosticsURL = translatedURL.appendingPathExtension("diagnostics.json")
        try Data(#"{"candidateCount":2,"translatedCount":1}"#.utf8).write(to: diagnosticsURL)

        let request = PDFTranslationDebugExportRequest(
            paperID: UUID(),
            paperTitle: "Debug Paper",
            arxivID: "2608.12345",
            doi: nil,
            originalAttachmentID: UUID(),
            translatedAttachmentID: UUID(),
            originalPDFURL: originalURL,
            translatedPDFURL: translatedURL,
            diagnosticsURL: diagnosticsURL,
            translatedLastPage: 1,
            selection: PDFDebugRegionSelection(
                pageIndex: 0,
                pageBounds: CGRect(x: 0, y: 0, width: 600, height: 800),
                selectedBounds: CGRect(x: 60, y: 80, width: 180, height: 240)
            )
        )

        let exportURL = try PDFTranslationDebugExporter(
            bundle: Bundle(for: Self.self)
        ).export(
            request,
            to: temporaryDirectory,
            exportedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let expectedFiles = [
            "manifest.json",
            "translated-region.png",
            "translated-page.pdf",
            "translated-text.txt",
            "original-region.png",
            "original-page.pdf",
            "original-text.txt",
            "babeldoc-diagnostics.json"
        ]
        for filename in expectedFiles {
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: exportURL.appendingPathComponent(filename).path
                ),
                "Missing \(filename)"
            )
        }

        let manifestData = try Data(contentsOf: exportURL.appendingPathComponent("manifest.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(PDFTranslationDebugManifest.self, from: manifestData)

        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(manifest.paper.title, "Debug Paper")
        XCTAssertEqual(manifest.selection.pageNumber, 1)
        XCTAssertEqual(
            manifest.selection.normalizedBounds.cgRect,
            CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3)
        )
        XCTAssertEqual(
            manifest.selection.originalBounds?.cgRect,
            CGRect(x: 30, y: 40, width: 90, height: 120)
        )
        XCTAssertEqual(manifest.files["babelDocDiagnostics"], "babeldoc-diagnostics.json")
    }

    private func writeBlankPDF(to url: URL, pageBounds: CGRect) throws {
        let document = PDFDocument()
        let page = PDFPage()
        page.setBounds(pageBounds, for: .mediaBox)
        page.setBounds(pageBounds, for: .cropBox)
        document.insert(page, at: 0)
        guard document.write(to: url) else {
            XCTFail("Unable to write test PDF")
            return
        }
    }
}
#endif
