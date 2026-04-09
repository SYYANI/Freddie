import XCTest
@testable import ReadPaper

final class PaperImporterTests: XCTestCase {
    @MainActor
    func testExtractArxivIDRecognizesExplicitArxivPrefix() {
        let identifier = PaperImporter.extractArxivID(
            from: "This draft appeared as arXiv:2303.08774v2 [cs.CL]."
        )

        XCTAssertEqual(identifier?.baseID, "2303.08774")
        XCTAssertEqual(identifier?.version, "v2")
    }

    @MainActor
    func testExtractArxivIDRecognizesArxivURL() {
        let identifier = PaperImporter.extractArxivID(
            from: "Source PDF: https://arxiv.org/pdf/2303.08774v2.pdf"
        )

        XCTAssertEqual(identifier?.baseID, "2303.08774")
        XCTAssertEqual(identifier?.version, "v2")
    }

    @MainActor
    func testExtractArxivIDDoesNotTreatDOIAsArxivID() {
        let identifier = PaperImporter.extractArxivID(
            from: "doi:10.1145/3731715.3733394"
        )

        XCTAssertNil(identifier)
    }
}
