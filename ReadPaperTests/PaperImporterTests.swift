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
    func testImportWebPageThrowsDescriptiveErrorOnNon200StatusCode() async throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockPaperImporterURLProtocol.self]
        let session = URLSession(configuration: configuration)

        MockPaperImporterURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)
            return (
                HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: ["Content-Type": "text/html"])!,
                Data()
            )
        }

        let importer = PaperImporter(
            fileStore: PaperFileStore(applicationSupportDirectory: rootURL),
            htmlLocalizer: HTMLLocalizer(session: session, fileManager: .default),
            session: session
        )
        let modelContext = ModelContext(try makeContainer())

        do {
            _ = try await importer.importWebPage("https://example.com/blocked", modelContext: modelContext)
            XCTFail("Expected error")
        } catch {
            let localized = error.localizedDescription
            XCTAssertTrue(localized.contains("403") || localized.contains("error"), "Message: \(localized)")
        }
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
private final class MockWebPageHTMLRenderer: WebPageHTMLRendering {
    let renderedHTML: String
    private(set) var renderedRequests: [URLRequest] = []

    init(renderedHTML: String) {
        self.renderedHTML = renderedHTML
    }

    func renderHTML(for request: URLRequest) async throws -> String {
        renderedRequests.append(request)
        return renderedHTML
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}
