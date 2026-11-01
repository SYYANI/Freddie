import Foundation
import Network
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
    func testSupportedLocalPDFsFiltersNonPDFAndRemoteURLs() throws {
        let pdf = URL(fileURLWithPath: "/tmp/Paper.PDF")
        let duplicatePDF = URL(fileURLWithPath: "/tmp/./Paper.PDF")
        let textFile = URL(fileURLWithPath: "/tmp/notes.txt")
        let remotePDF = try XCTUnwrap(URL(string: "https://example.com/paper.pdf"))

        XCTAssertEqual(
            PaperImporter.supportedLocalPDFs(
                from: [pdf, duplicatePDF, textFile, remotePDF]
            ),
            [pdf]
        )
    }

    @MainActor
    func testArxivLinkImportRequestRecognizesSupportedPaperLinks() throws {
        let absRequest = try XCTUnwrap(ArxivLinkImportRequest(
            url: XCTUnwrap(URL(string: "https://arxiv.org/abs/2303.08774v2#references"))
        ))
        XCTAssertEqual(absRequest.identifier.baseID, "2303.08774")
        XCTAssertEqual(absRequest.identifier.version, "v2")

        let legacyPDFRequest = try XCTUnwrap(ArxivLinkImportRequest(
            url: XCTUnwrap(URL(string: "https://export.arxiv.org/pdf/hep-th/9901001.pdf"))
        ))
        XCTAssertEqual(legacyPDFRequest.importValue, "hep-th/9901001")

        let ar5ivRequest = try XCTUnwrap(ArxivLinkImportRequest(
            url: XCTUnwrap(URL(string: "https://ar5iv.labs.arxiv.org/html/2404.12365"))
        ))
        XCTAssertEqual(ar5ivRequest.importValue, "2404.12365")
    }

    @MainActor
    func testArxivLinkImportRequestRejectsLookalikeAndUnrelatedHosts() throws {
        XCTAssertNil(ArxivLinkImportRequest(
            url: try XCTUnwrap(URL(string: "https://arxiv.org.example.com/abs/2303.08774"))
        ))
        XCTAssertNil(ArxivLinkImportRequest(
            url: try XCTUnwrap(URL(string: "https://doi.org/10.1145/3731715.3733394"))
        ))
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
    func testImportArxivCanIncludeHTMLWhenExplicitlyEnabled() async throws {
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

        let paper = try await importer.importArxiv(
            "2303.08774",
            modelContext: modelContext,
            includeHTML: true
        ) { progress in
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
    func testDefaultImportArxivDownloadsPDFOnlyWhenAPIFallsBackToAbsPage() async throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockPaperImporterURLProtocol.self]
        let session = URLSession(configuration: configuration)

        MockPaperImporterURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)

            switch (url.host, url.path) {
            case ("export.arxiv.org", "/api/query"):
                XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/atom+xml,application/xml;q=0.9,*/*;q=0.8")
                return (
                    HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil, headerFields: ["Content-Type": "text/html"])!,
                    Data("Rate exceeded.".utf8)
                )
            case ("arxiv.org", "/abs/2404.12365"):
                XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), BrowserRequestHeaders.chromeUserAgent)
                let html = """
                <!doctype html>
                <html>
                <head>
                  <title>[2404.12365] When LLMs are Unfit Use FastFit: Fast and Effective Text Classification with Many Classes</title>
                  <link rel="canonical" href="https://arxiv.org/abs/2404.12365">
                  <meta property="og:url" content="https://arxiv.org/abs/2404.12365v1">
                  <meta name="citation_title" content="When LLMs are Unfit Use FastFit: Fast and Effective Text Classification with Many Classes">
                  <meta name="citation_author" content="Yehudai, Asaf">
                  <meta name="citation_author" content="Bendel, Elron">
                  <meta name="citation_date" content="2024/04/18">
                  <meta name="citation_pdf_url" content="https://arxiv.org/pdf/2404.12365">
                </head>
                <body>
                  <blockquote class="abstract mathjax">
                    <span class="descriptor">Abstract:</span>
                    We present FastFit, a method for fast and accurate few-shot classification.
                  </blockquote>
                  <table><tr><td class="tablecell subjects">
                    Computation and Language (cs.CL); Artificial Intelligence (cs.AI); Information Retrieval (cs.IR)
                  </td></tr></table>
                </body>
                </html>
                """
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/html"])!,
                    Data(html.utf8)
                )
            case ("arxiv.org", "/pdf/2404.12365"):
                XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), BrowserRequestHeaders.chromeUserAgent)
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/pdf"])!,
                    Data("%PDF-1.4 fastfit test".utf8)
                )
            case ("arxiv.org", "/html/2404.12365"),
                ("ar5iv.labs.arxiv.org", "/html/2404.12365"):
                XCTFail("Default arXiv import should not request HTML: \(url.absoluteString)")
                throw URLError(.badURL)
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

        let paper = try await importer.importArxiv("2404.12365", modelContext: modelContext) { progress in
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
                .finalizing
            ]
        )
        XCTAssertEqual(paper.arxivID, "2404.12365")
        XCTAssertEqual(paper.arxivVersion, "v1")
        XCTAssertEqual(paper.title, "When LLMs are Unfit Use FastFit: Fast and Effective Text Classification with Many Classes")
        XCTAssertEqual(paper.authors, ["Yehudai, Asaf", "Bendel, Elron"])
        XCTAssertEqual(paper.categories, ["cs.CL", "cs.AI", "cs.IR"])
        XCTAssertTrue(paper.abstractText.contains("We present FastFit"))
        XCTAssertEqual(paper.pdfURLString, "https://arxiv.org/pdf/2404.12365")
        XCTAssertEqual(paper.htmlURLString, "https://arxiv.org/abs/2404.12365")
        XCTAssertEqual(progressEvents.last?.stepLabel, "Step 5 of 5")
        XCTAssertEqual(progressEvents.last?.detail, "Saving the paper metadata and PDF to your library.")

        let attachments = try modelContext.fetch(FetchDescriptor<PaperAttachment>())
        let attachment = try XCTUnwrap(attachments.first)
        XCTAssertEqual(attachments.count, 1)
        XCTAssertEqual(attachment.kind, .pdf)
        XCTAssertEqual(attachment.source, .arxivPDF)
    }

    @MainActor
    func testImportWebPageLocalizesStaticURLWithReadability() async throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockPaperImporterURLProtocol.self]
        let session = URLSession(configuration: configuration)

        MockPaperImporterURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), BrowserRequestHeaders.chromeUserAgent)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Language"), BrowserRequestHeaders.englishAcceptLanguage)

            switch (url.host, url.path) {
            case ("example.com", "/paper"):
                XCTAssertEqual(
                    request.value(forHTTPHeaderField: "Accept"),
                    "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
                )
                let paragraph = String(repeating: "This static page content should survive readability extraction. ", count: 12)
                let html = """
                <html>
                <head><title>Readable Static Page</title></head>
                <body>
                <nav>Site navigation should not be part of the saved article.</nav>
                <article>
                <h1>Readable Static Page</h1>
                <p>\(paragraph)</p>
                <img src="/figure.png">
                </article>
                </body>
                </html>
                """
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/html"])!,
                    Data(html.utf8)
                )
            case ("example.com", "/figure.png"):
                XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "*/*")
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "image/png"])!,
                    Data([0x89, 0x50, 0x4E, 0x47])
                )
            default:
                XCTFail("Unexpected request: \(url.absoluteString)")
                throw URLError(.badURL)
            }
        }

        let importer = PaperImporter(
            fileStore: PaperFileStore(applicationSupportDirectory: rootURL),
            htmlLocalizer: HTMLLocalizer(session: session, fileManager: .default),
            session: session
        )
        let modelContext = ModelContext(try makeContainer())
        var progressEvents: [WebPageImportProgress] = []

        let paper = try await importer.importWebPage("https://example.com/paper#comments", modelContext: modelContext) { progress in
            progressEvents.append(progress)
        }

        XCTAssertEqual(
            progressEvents.map(\.stage),
            [
                .validatingURL,
                .validatingURL,
                .fetchingHTML,
                .creatingLibraryEntry,
                .finalizing
            ]
        )
        XCTAssertEqual(paper.htmlURLString, "https://example.com/paper")
        XCTAssertTrue(paper.title.contains("Readable Static Page"))

        let attachments = try modelContext.fetch(FetchDescriptor<PaperAttachment>())
        let attachment = try XCTUnwrap(attachments.first)
        XCTAssertEqual(attachments.count, 1)
        XCTAssertEqual(attachment.kind, .html)
        XCTAssertEqual(attachment.source, .webPage)

        let localizedHTML = try String(contentsOf: attachment.fileURL, encoding: .utf8)
        XCTAssertTrue(localizedHTML.contains("rp-readability-content"))
        XCTAssertFalse(localizedHTML.contains("Site navigation"))
        XCTAssertTrue(localizedHTML.contains("data-rp-assistant-block-id"))
        let generatedIndexURLs = (FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: nil
        )?.allObjects as? [URL] ?? []).filter {
            $0.lastPathComponent == "assistant-search-index-v1.json"
        }
        XCTAssertEqual(generatedIndexURLs.count, 1)
    }

    @MainActor
    func testImportWebPageRendersJavaScriptAppShellBeforeReadabilityExtraction() async throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockPaperImporterURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let sourceURL = try XCTUnwrap(URL(string: "https://example.com/blog/dynamic-article"))
        let shellHTML = """
        <!doctype html>
        <html>
        <head><script type="module" src="/assets/article.js"></script></head>
        <body><div id="root"></div></body>
        </html>
        """
        let paragraph = String(repeating: "This article was rendered by the client-side application. ", count: 12)
        let renderedHTML = """
        <html>
        <head><title>Rendered Research Article</title></head>
        <body><div id="root"><article><h1>Rendered Research Article</h1><p>\(paragraph)</p></article></div></body>
        </html>
        """
        let renderer = MockWebPageHTMLRenderer(renderedHTML: renderedHTML)

        MockPaperImporterURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url, sourceURL)
            return (
                HTTPURLResponse(url: sourceURL, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/html"])!,
                Data(shellHTML.utf8)
            )
        }

        let importer = PaperImporter(
            fileStore: PaperFileStore(applicationSupportDirectory: rootURL),
            htmlLocalizer: HTMLLocalizer(session: session, fileManager: .default),
            webPageHTMLRenderer: renderer,
            session: session
        )
        let modelContext = ModelContext(try makeContainer())

        let paper = try await importer.importWebPage(sourceURL.absoluteString, modelContext: modelContext)

        XCTAssertEqual(renderer.renderedRequests.map(\.url), [sourceURL])
        XCTAssertTrue(paper.title.contains("Rendered Research Article"))

        let attachment = try XCTUnwrap(modelContext.fetch(FetchDescriptor<PaperAttachment>()).first)
        let localizedHTML = try String(contentsOf: attachment.fileURL, encoding: .utf8)
        XCTAssertTrue(localizedHTML.contains("rp-readability-content"))
        XCTAssertTrue(localizedHTML.contains("This article was rendered by the client-side application"))
        XCTAssertFalse(localizedHTML.contains("article.js"))
    }

    @MainActor
    func testImportWebPageCancelledMidImportDoesNotCreatePaper() async throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockPaperImporterURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let sourceURL = try XCTUnwrap(URL(string: "https://example.com/blog/cancelled-article"))
        let shellHTML = """
        <!doctype html>
        <html>
        <head><script type="module" src="/assets/article.js"></script></head>
        <body><div id="root"></div></body>
        </html>
        """
        let paragraph = String(repeating: "This article finished rendering after the user cancelled. ", count: 12)
        let renderedHTML = """
        <html>
        <head><title>Cancelled Article</title></head>
        <body><div id="root"><article><h1>Cancelled Article</h1><p>\(paragraph)</p></article></div></body>
        </html>
        """
        // Simulates the user dismissing the sheet while a step that ignores cancellation is running.
        let renderer = MockWebPageHTMLRenderer(renderedHTML: renderedHTML, cancelsCurrentTask: true)

        MockPaperImporterURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)
            return (
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/html"])!,
                Data(shellHTML.utf8)
            )
        }

        let importer = PaperImporter(
            fileStore: PaperFileStore(applicationSupportDirectory: rootURL),
            htmlLocalizer: HTMLLocalizer(session: session, fileManager: .default),
            webPageHTMLRenderer: renderer,
            session: session
        )
        let modelContext = ModelContext(try makeContainer())

        let task = Task { @MainActor () -> Error? in
            do {
                _ = try await importer.importWebPage(sourceURL.absoluteString, modelContext: modelContext)
                return nil
            } catch {
                return error
            }
        }
        let error = await task.value
        XCTAssertTrue(error is CancellationError, "Unexpected result: \(String(describing: error))")

        XCTAssertEqual(renderer.renderedRequests.map(\.url), [sourceURL])
        XCTAssertTrue(try modelContext.fetch(FetchDescriptor<Paper>()).isEmpty)
        XCTAssertTrue(try modelContext.fetch(FetchDescriptor<PaperAttachment>()).isEmpty)
        let leftoverHTML = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.lastPathComponent == "paper.html" } ?? []
        XCTAssertTrue(leftoverHTML.isEmpty)
    }

    @MainActor
    func testImportWebPageRepairsExistingBlankJavaScriptImport() async throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockPaperImporterURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let sourceURL = try XCTUnwrap(URL(string: "https://example.com/blog/dynamic-article"))
        let shellHTML = """
        <!doctype html>
        <html>
        <head><script type="module" src="/assets/article.js"></script></head>
        <body><div id="root"></div></body>
        </html>
        """
        let paragraph = String(repeating: "Recovered client-rendered article content. ", count: 16)
        let renderedHTML = """
        <html>
        <head><title>Recovered Research Article</title></head>
        <body><main><article><h1>Recovered Research Article</h1><p>\(paragraph)</p></article></main></body>
        </html>
        """
        let renderer = MockWebPageHTMLRenderer(renderedHTML: renderedHTML)
        let fileStore = PaperFileStore(applicationSupportDirectory: rootURL)
        let modelContext = ModelContext(try makeContainer())

        let existing = Paper(title: "dynamic article", htmlURLString: sourceURL.absoluteString)
        existing.localDirectoryPath = try fileStore.directory(for: existing.id).path
        let blankFile = try fileStore.write(Data(shellHTML.utf8), named: "paper.html", for: existing.id)
        modelContext.insert(existing)
        modelContext.insert(PaperAttachment(
            paperID: existing.id,
            kind: .html,
            source: .webPage,
            filename: blankFile.lastPathComponent,
            filePath: blankFile.path
        ))
        try modelContext.save()

        MockPaperImporterURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url, sourceURL)
            return (
                HTTPURLResponse(url: sourceURL, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/html"])!,
                Data(shellHTML.utf8)
            )
        }

        let importer = PaperImporter(
            fileStore: fileStore,
            htmlLocalizer: HTMLLocalizer(session: session, fileManager: .default),
            webPageHTMLRenderer: renderer,
            session: session
        )

        let repaired = try await importer.importWebPage(sourceURL.absoluteString, modelContext: modelContext)

        XCTAssertEqual(repaired.id, existing.id)
        XCTAssertEqual(renderer.renderedRequests.map(\.url), [sourceURL])
        XCTAssertEqual(try modelContext.fetch(FetchDescriptor<Paper>()).count, 1)
        let attachments = try modelContext.fetch(FetchDescriptor<PaperAttachment>())
        XCTAssertEqual(attachments.count, 1)
        let localizedHTML = try String(contentsOf: blankFile, encoding: .utf8)
        XCTAssertTrue(localizedHTML.contains("Recovered client-rendered article content"))
        XCTAssertTrue(localizedHTML.contains("rp-readability-content"))
    }

    @MainActor
    func testImportWebPageDetectsPDFContentTypeAndSavesAsPDF() async throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockPaperImporterURLProtocol.self]
        let session = URLSession(configuration: configuration)

        MockPaperImporterURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)

            switch (url.host, url.path) {
            case ("example.com", "/paper.pdf"):
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/pdf"])!,
                    Data("%PDF-1.4 test".utf8)
                )
            default:
                XCTFail("Unexpected request: \(url.absoluteString)")
                throw URLError(.badURL)
            }
        }

        let importer = PaperImporter(
            fileStore: PaperFileStore(applicationSupportDirectory: rootURL),
            htmlLocalizer: HTMLLocalizer(session: session, fileManager: .default),
            session: session
        )
        let modelContext = ModelContext(try makeContainer())
        var progressEvents: [WebPageImportProgress] = []

        let paper = try await importer.importWebPage("https://example.com/paper.pdf", modelContext: modelContext) { progress in
            progressEvents.append(progress)
        }

        XCTAssertEqual(
            progressEvents.map(\.stage),
            [
                .validatingURL,
                .validatingURL,
                .fetchingHTML,
                .fetchingHTML,
                .creatingLibraryEntry,
                .finalizing
            ]
        )
        XCTAssertEqual(progressEvents[safe: 3]?.title, "Downloading PDF")
        XCTAssertEqual(paper.htmlURLString, "https://example.com/paper.pdf")
        XCTAssertEqual(paper.pdfURLString, "https://example.com/paper.pdf")
        XCTAssertEqual(paper.title, "paper")

        let attachments = try modelContext.fetch(FetchDescriptor<PaperAttachment>())
        let attachment = try XCTUnwrap(attachments.first)
        XCTAssertEqual(attachments.count, 1)
        XCTAssertEqual(attachment.kind, .pdf)
        XCTAssertEqual(attachment.source, .webPage)
        XCTAssertTrue(attachment.filename.hasSuffix(".pdf"))
    }

    @MainActor
    func testImportForbiddenWebPageRetriesInBrowserBeforeLocalizing() async throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockPaperImporterURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let sourceURL = try XCTUnwrap(URL(string: "https://zhuanlan.zhihu.com/p/2095560295930508953"))
        let paragraph = String(repeating: "浏览器加载完成后得到的文章正文，应当经过正文提取并保存到本地。", count: 20)
        let renderer = MockWebPageHTMLRenderer(renderedHTML: """
        <html><head><title>知乎文章</title></head>
        <body><article><h1>知乎文章</h1><p>\(paragraph)</p></article></body></html>
        """)
        MockPaperImporterURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)
            return (
                HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: ["Content-Type": "text/html"])!,
                Data("<html><head><meta id='zh-zse-ck'></head><body>浏览器验证中</body></html>".utf8)
            )
        }
        let importer = PaperImporter(
            fileStore: PaperFileStore(applicationSupportDirectory: rootURL),
            htmlLocalizer: HTMLLocalizer(session: session),
            webPageHTMLRenderer: renderer,
            session: session
        )
        let context = ModelContext(try makeContainer())

        let paper = try await importer.importWebPage(sourceURL.absoluteString, modelContext: context)

        XCTAssertEqual(renderer.renderedRequests.map(\.url), [sourceURL])
        XCTAssertEqual(paper.htmlURLString, sourceURL.absoluteString)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Paper>()).count, 1)
        let attachment = try XCTUnwrap(context.fetch(FetchDescriptor<PaperAttachment>()).first)
        XCTAssertEqual(attachment.kind, .html)
        XCTAssertEqual(attachment.source, .webPage)
        let html = try String(contentsOf: attachment.fileURL, encoding: .utf8)
        XCTAssertTrue(html.contains("知乎文章"))
        XCTAssertTrue(html.contains("rp-readability-content"))
        XCTAssertTrue(html.contains(paragraph))
        XCTAssertFalse(html.contains("zh-zse-ck"))
    }

    @MainActor
    func testImportForbiddenWebPageDoesNotSaveUnsuccessfulBrowserRetry() async throws {
        let challenge = """
        <html><head><meta id="zh-zse-ck" charset="UTF-8"></head>
        <body>\(String(repeating: "知乎，让每一次点击都充满意义 —— 欢迎来到知乎，发现问题背后的世界。", count: 4))</body></html>
        """
        for (html, rendererError, cancelsTask) in [
            (challenge, nil, false),
            ("<html><body></body></html>", nil, false),
            ("", URLError(.timedOut), false),
            ("", nil, true)
        ] as [(String, Error?, Bool)] {
            let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: rootURL) }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MockPaperImporterURLProtocol.self]
            let session = URLSession(configuration: configuration)
            let renderer = MockWebPageHTMLRenderer(
                renderedHTML: html,
                cancelsCurrentTask: cancelsTask,
                error: rendererError
            )
            MockPaperImporterURLProtocol.requestHandler = { request in
                let url = try XCTUnwrap(request.url)
                return (HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: nil)!, Data())
            }
            let importer = PaperImporter(
                fileStore: PaperFileStore(applicationSupportDirectory: rootURL),
                htmlLocalizer: HTMLLocalizer(session: session),
                webPageHTMLRenderer: renderer,
                session: session
            )
            let context = ModelContext(try makeContainer())
            let task = Task { @MainActor () -> Error? in
                do {
                    _ = try await importer.importWebPage("https://example.com/blocked", modelContext: context)
                    return nil
                } catch { return error }
            }
            let error = await task.value
            if cancelsTask {
                XCTAssertTrue(error is CancellationError)
            } else if case .webPageHTTPError(let statusCode) = error as? PaperImportError {
                XCTAssertEqual(statusCode, 403)
            } else {
                XCTFail("Expected HTTP 403, got \(String(describing: error))")
            }
            XCTAssertEqual(renderer.renderedRequests.count, 1)
            XCTAssertTrue(try context.fetch(FetchDescriptor<Paper>()).isEmpty)
            XCTAssertTrue(try context.fetch(FetchDescriptor<PaperAttachment>()).isEmpty)
            let leftoverHTML = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }.filter { $0.lastPathComponent == "paper.html" } ?? []
            XCTAssertTrue(leftoverHTML.isEmpty)
        }
    }

    @MainActor
    func testImportWeChatArticleRepairsIncompleteImportsOnceWithoutBrowserRendering() async throws {
        let sourceURL = URL(string: "https://mp.weixin.qq.com/s/test-article")!
        let chromeText = String(repeating: "公众号信息、阅读原文和页面按钮。", count: 5)
        let paragraph = String(repeating: "微信正文已完整下载，静态提取时应恢复正文的可见性。", count: 20)
        // The article root is the wrapper's only child, so Readability renames it #img-content.
        let articleHTML = """
        <html><head><meta property="og:title" content="微信文章标题"></head><body id="activity-detail">
        <div id="img-content"><div id="js_content" class="rich_media_content" style="visibility: hidden; opacity: 0;">
        <p>\(paragraph)</p><h2>最后一节</h2><p>\(paragraph)</p></div></div></body></html>
        """
        let oldPages = [
            // Readability dropped the hidden article and kept the account metadata.
            """
            <html><body id="activity-detail" class="rp-readability-body">
            <article class="rp-readability-content"><div id="img-content"><p><span class="rich_media_meta">\(chromeText)</span></p></div></article>
            </body></html>
            """,
            // Readability was rejected and the page was saved with its article still hidden.
            articleHTML,
            // A CAPTCHA page saved as an article; saving removed its script.
            """
            <html><body><div class="weui-msg"><h2>环境异常</h2><p>\(String(repeating: "当前环境异常，完成验证后即可继续访问。", count: 4))</p>
            <a id="js_verify">去验证</a></div></body></html>
            """
        ]
        for oldHTML in oldPages {
            let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: rootURL) }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MockPaperImporterURLProtocol.self]
            let session = URLSession(configuration: configuration)
            let fileStore = PaperFileStore(applicationSupportDirectory: rootURL)
            let context = ModelContext(try makeContainer())
            let existing = Paper(title: "微信文章标题", htmlURLString: sourceURL.absoluteString)
            existing.localDirectoryPath = try fileStore.directory(for: existing.id).path
            let htmlFile = try fileStore.write(Data(oldHTML.utf8), named: "paper.html", for: existing.id)
            let attachment = PaperAttachment(paperID: existing.id, kind: .html, source: .webPage, filename: "paper.html", filePath: htmlFile.path)
            context.insert(existing)
            context.insert(attachment)
            try context.save()
            var requestCount = 0
            MockPaperImporterURLProtocol.requestHandler = { request in
                XCTAssertEqual(request.url, sourceURL)
                requestCount += 1
                return (HTTPURLResponse(url: sourceURL, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/html"])!, Data(articleHTML.utf8))
            }
            let renderer = MockWebPageHTMLRenderer(renderedHTML: "")
            let importer = PaperImporter(fileStore: fileStore, htmlLocalizer: HTMLLocalizer(session: session), webPageHTMLRenderer: renderer, session: session)

            let repaired = try await importer.importWebPage(sourceURL.absoluteString, modelContext: context)

            XCTAssertEqual(repaired.id, existing.id)
            XCTAssertEqual(repaired.title, "微信文章标题")
            XCTAssertTrue(renderer.renderedRequests.isEmpty)
            XCTAssertEqual(try context.fetch(FetchDescriptor<Paper>()).count, 1)
            XCTAssertEqual(try context.fetch(FetchDescriptor<PaperAttachment>()).map(\.id), [attachment.id])
            let html = try String(contentsOf: htmlFile, encoding: .utf8)
            XCTAssertTrue(html.contains(paragraph))
            XCTAssertTrue(html.contains("最后一节"))
            XCTAssertFalse(html.contains(chromeText))
            XCTAssertFalse(html.contains("环境异常"))

            // The repaired copy is complete: importing again neither downloads nor rewrites it.
            let reimported = try await importer.importWebPage(sourceURL.absoluteString, modelContext: context)
            XCTAssertEqual(reimported.id, existing.id)
            XCTAssertEqual(requestCount, 1)
            XCTAssertEqual(try String(contentsOf: htmlFile, encoding: .utf8), html)
        }
    }

    @MainActor
    func testImportWeChatVerificationPageDoesNotCreatePaper() async throws {
        let challenge = """
        <html><body><h2>环境异常</h2><p>\(String(repeating: "当前环境异常，完成验证后即可继续访问。", count: 4))</p>
        <a id="js_verify">去验证</a><script src="https://captcha.gtimg.com/TCaptcha.js"></script></body></html>
        """
        for rendererError in [nil, PaperImportError.webPageRequiresVerification] as [Error?] {
            let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: rootURL) }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MockPaperImporterURLProtocol.self]
            let session = URLSession(configuration: configuration)
            MockPaperImporterURLProtocol.requestHandler = { request in
                (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/html"])!, Data(challenge.utf8))
            }
            let renderer = MockWebPageHTMLRenderer(renderedHTML: challenge, error: rendererError)
            let importer = PaperImporter(fileStore: PaperFileStore(applicationSupportDirectory: rootURL), htmlLocalizer: HTMLLocalizer(session: session), webPageHTMLRenderer: renderer, session: session)
            let context = ModelContext(try makeContainer())
            do {
                _ = try await importer.importWebPage("https://mp.weixin.qq.com/s/test-article", modelContext: context)
                XCTFail("Expected browser verification error")
            } catch PaperImportError.webPageRequiresVerification {
                // Both a captured verification page and a verification redirect are rejected.
            }
            XCTAssertEqual(renderer.renderedRequests.count, 1)
            XCTAssertTrue(try context.fetch(FetchDescriptor<Paper>()).isEmpty)
            XCTAssertTrue(try context.fetch(FetchDescriptor<PaperAttachment>()).isEmpty)
            let files = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL } ?? []
            XCTAssertFalse(files.contains { $0.lastPathComponent == "paper.html" })
        }
    }

    @MainActor
    func testZhihuVerificationRedirectDetectionChecksHostAndPath() throws {
        for value in [
            "https://www.zhihu.com/account/unhuman?need_login=true&next=%2Fsignin",
            "https://www.zhihu.com/signin",
            "https://zhihu.com/login"
        ] {
            XCTAssertTrue(WebKitWebPageHTMLRenderer.requiresUserVerification(at: try XCTUnwrap(URL(string: value))))
        }
        for value in [
            "https://zhuanlan.zhihu.com/p/2095560295930508953",
            "https://zhihu.com.example.com/signin",
            "https://notzhihu.com/signin",
            "https://example.com/account/unhuman"
        ] {
            XCTAssertFalse(WebKitWebPageHTMLRenderer.requiresUserVerification(at: try XCTUnwrap(URL(string: value))))
        }
    }

    @MainActor
    func testWebKitRendererReturnsWeChatCaptchaWithoutWaitingForTimeout() async throws {
        let captcha = """
        <html><body><div class="weui-msg"><h2>环境异常</h2><p>\(String(repeating: "当前环境异常，完成验证后即可继续访问。", count: 4))</p>
        <a id="js_verify">去验证</a></div></body></html>
        """
        let server = try await LoopbackHTMLServer.start(serving: captcha)
        defer { server.stop() }
        let renderer = WebKitWebPageHTMLRenderer(timeout: 20)
        let started = Date()

        let html = try await renderer.renderHTML(for: URLRequest(url: server.url))

        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertTrue(HTMLLocalizer().isBrowserChallengePage(html))
    }

    @MainActor
    func testWeChatVerificationRedirectDetectionChecksHostAndPath() throws {
        XCTAssertTrue(WebKitWebPageHTMLRenderer.requiresUserVerification(at:
            URL(string: "https://mp.weixin.qq.com/mp/wappoc_appmsgcaptcha?poc_token=test")!))
        for value in [
            "https://mp.weixin.qq.com/s/test-article",
            "https://mp.weixin.qq.com.example.com/mp/wappoc_appmsgcaptcha",
            "https://example.com/mp/wappoc_appmsgcaptcha"
        ] {
            XCTAssertFalse(WebKitWebPageHTMLRenderer.requiresUserVerification(at: URL(string: value)!))
        }
    }

    @MainActor
    func testImportWebPageThrowsDescriptiveErrorOnNon200StatusCode() async throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockPaperImporterURLProtocol.self]
        let session = URLSession(configuration: configuration)

        MockPaperImporterURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)
            return (
                HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: ["Content-Type": "text/html"])!,
                Data()
            )
        }

        let renderer = MockWebPageHTMLRenderer(renderedHTML: "")
        let importer = PaperImporter(
            fileStore: PaperFileStore(applicationSupportDirectory: rootURL),
            htmlLocalizer: HTMLLocalizer(session: session, fileManager: .default),
            webPageHTMLRenderer: renderer,
            session: session
        )
        let modelContext = ModelContext(try makeContainer())

        do {
            _ = try await importer.importWebPage("https://example.com/blocked", modelContext: modelContext)
            XCTFail("Expected error")
        } catch {
            let localized = error.localizedDescription
            XCTAssertTrue(localized.contains("404"), "Message: \(localized)")
        }
        XCTAssertTrue(renderer.renderedRequests.isEmpty)
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

@MainActor
/// Answers every request on a loopback port with one HTML page, so a real web view can load it.
private final class LoopbackHTMLServer: Sendable {
    let url: URL
    private let listener: NWListener

    private init(listener: NWListener, port: UInt16) {
        self.listener = listener
        url = URL(string: "http://127.0.0.1:\(port)/s/test-article")!
    }

    static func start(serving html: String) async throws -> LoopbackHTMLServer {
        let port = UInt16.random(in: 41000...48000)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: parameters)
        let body = Data(html.utf8)
        let response = Data("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { _, _, _, _ in
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: .global())
        while listener.state != .ready {
            if case .failed(let error) = listener.state { throw error }
            try await Task.sleep(for: .milliseconds(20))
        }
        return LoopbackHTMLServer(listener: listener, port: port)
    }

    func stop() {
        listener.cancel()
    }
}

private final class MockWebPageHTMLRenderer: WebPageHTMLRendering {
    let renderedHTML: String
    let cancelsCurrentTask: Bool
    let error: Error?
    private(set) var renderedRequests: [URLRequest] = []

    init(renderedHTML: String, cancelsCurrentTask: Bool = false, error: Error? = nil) {
        self.renderedHTML = renderedHTML
        self.cancelsCurrentTask = cancelsCurrentTask
        self.error = error
    }

    func renderHTML(for request: URLRequest) async throws -> String {
        renderedRequests.append(request)
        if cancelsCurrentTask {
            withUnsafeCurrentTask { $0?.cancel() }
        }
        if let error { throw error }
        return renderedHTML
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}
