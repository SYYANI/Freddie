import Foundation
import SwiftData
import XCTest
@testable import ReadPaper

final class PaperImporterTests: XCTestCase {
    private var originalLanguageOverride: String?

    override func setUp() {
        super.setUp()
        originalLanguageOverride = AppLocalization.currentLanguageOverride()
        AppLocalization.setLanguageOverride("en")
    }

    override func tearDown() {
        AppLocalization.setLanguageOverride(originalLanguageOverride)
        super.tearDown()
        MockPaperImporterURLProtocol.reset()
    }

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

    @MainActor
    func testExtractDOIRecognizesExplicitDOI() {
        let doi = PaperImporter.extractDOI(
            from: "Published version doi:10.1145/3731715.3733394"
        )

        XCTAssertEqual(doi, "10.1145/3731715.3733394")
    }

    @MainActor
    func testExtractDOIRecognizesWrappedDOIURL() {
        let doi = PaperImporter.extractDOI(
            from: """
            ACM ISBN 979-8-4007-1877-9/2025/06
            https://doi.org/10.
            1145/3731715.3733394
            """
        )

        XCTAssertEqual(doi, "10.1145/3731715.3733394")
    }

    @MainActor
    func testPaperUsesDOIAsFallbackDisplayIdentifier() {
        let paper = Paper(
            doi: "10.1145/3731715.3733394",
            title: "MoAFCL"
        )

        XCTAssertEqual(paper.sidebarIdentifierText, "DOI 10.1145/3731715.3733394")
        XCTAssertEqual(paper.metadataIdentifierText, "DOI: 10.1145/3731715.3733394")
    }

    @MainActor
    func testImportArxivReportsProgressAcrossFallbackHTMLImport() async throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockPaperImporterURLProtocol.self]
        let session = URLSession(configuration: configuration)

        MockPaperImporterURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)

            switch (url.host, url.path) {
            case ("export.arxiv.org", "/api/query"):
                let xml = """
                <?xml version="1.0" encoding="UTF-8"?>
                <feed xmlns="http://www.w3.org/2005/Atom">
                  <entry>
                    <id>http://arxiv.org/abs/2303.08774v1</id>
                    <updated>2023-03-15T00:00:00Z</updated>
                    <published>2023-03-15T00:00:00Z</published>
                    <title> Progress Aware Import </title>
                    <summary> A test summary. </summary>
                    <author><name>Author One</name></author>
                    <link href="http://arxiv.org/abs/2303.08774v1" rel="alternate" type="text/html"/>
                    <link title="pdf" href="http://arxiv.org/pdf/2303.08774v1" rel="related" type="application/pdf"/>
                  </entry>
                </feed>
                """
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/atom+xml"])!,
                    Data(xml.utf8)
                )
            case ("arxiv.org", "/pdf/2303.08774v1"):
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/pdf"])!,
                    Data("%PDF-1.4 progress test".utf8)
                )
            case ("arxiv.org", "/html/2303.08774"):
                return (
                    HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!,
                    Data()
                )
            case ("ar5iv.labs.arxiv.org", "/html/2303.08774"):
                let html = """
                <html>
                <head><title>Fallback HTML</title></head>
                <body>
                <article>
                <h1>Progress Aware Import</h1>
                <p>This fallback HTML body is long enough to survive readability extraction and should be saved locally.</p>
                </article>
                </body>
                </html>
                """
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/html"])!,
                    Data(html.utf8)
                )
            default:
                XCTFail("Unexpected request: \(url.absoluteString)")
                throw URLError(.badURL)
            }
        }

        let importer = PaperImporter(
            fileStore: PaperFileStore(applicationSupportDirectory: rootURL),
            arxivClient: ArxivClient(session: session, minimumRequestInterval: 0),
            htmlLocalizer: HTMLLocalizer(session: session, fileManager: .default),
            session: session
        )
        let modelContext = ModelContext(try makeContainer())
        var progressEvents: [ArxivImportProgress] = []

        let paper = try await importer.importArxiv("2303.08774", modelContext: modelContext) { progress in
            progressEvents.append(progress)
        }

        XCTAssertEqual(
            progressEvents.map(\.stage),
            [
                .resolvingInput,
                .resolvingInput,
                .fetchingMetadata,
                .creatingLibraryEntry,
                .downloadingPDF,
                .importingHTML,
                .importingHTML,
                .finalizing
            ]
        )
        XCTAssertEqual(progressEvents[safe: 5]?.title, "Fetching reader HTML")
        XCTAssertEqual(progressEvents[safe: 6]?.title, "Trying backup HTML source")
        XCTAssertEqual(progressEvents.last?.detail, "Saving the paper, PDF, and localized HTML to your library.")
        XCTAssertEqual(paper.title, "Progress Aware Import")
        XCTAssertEqual(paper.htmlURLString, "https://ar5iv.labs.arxiv.org/html/2303.08774")

        let attachments = try modelContext.fetch(FetchDescriptor<PaperAttachment>())
        XCTAssertEqual(attachments.count, 2)
        XCTAssertTrue(attachments.contains(where: { $0.kind == .pdf }))
        XCTAssertTrue(attachments.contains(where: { $0.kind == .html }))
    }

    @MainActor
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            Paper.self,
            PaperAttachment.self
        ])
        return try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
    }
}

private final class MockPaperImporterURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    static func reset() {
        requestHandler = nil
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}
