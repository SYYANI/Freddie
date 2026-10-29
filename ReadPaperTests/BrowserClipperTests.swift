import CoreGraphics
import Foundation
import SwiftData
import SwiftSoup
import XCTest
@testable import ReadPaper

final class BrowserClipperTests: XCTestCase {
    private var rootURL: URL!
    private var originalLanguageOverride: String?
    /// Saving starts author extraction in the background, which can outlive the test; a
    /// container's `mainContext` does not keep the container alive on its own.
    private var containers: [ModelContainer] = []

    override func setUp() {
        super.setUp()
        rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        originalLanguageOverride = AppLocalization.currentLanguageOverride()
        AppLocalization.setLanguageOverride("en")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: rootURL)
        AppLocalization.setLanguageOverride(originalLanguageOverride)
        super.tearDown()
    }

    // MARK: HTTP

    func testParseWaitsForTheWholeBody() {
        let head = "POST /save HTTP/1.1\r\nHost: 127.0.0.1:23240\r\nContent-Length: 10\r\nX-Freddie-Clipper: 1\r\n\r\n"
        XCTAssertEqual(BrowserClipperHTTPRequest.parse(Data("POST /save HTTP/1.1\r\nHost".utf8)), .incomplete)
        XCTAssertEqual(BrowserClipperHTTPRequest.parse(Data((head + "{\"a\":").utf8)), .incomplete)

        guard case .complete(let request) = BrowserClipperHTTPRequest.parse(Data((head + "{\"a\":true}").utf8)) else {
            return XCTFail("Expected a complete request")
        }
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/save")
        XCTAssertEqual(request.headers["x-freddie-clipper"], "1")
        XCTAssertEqual(String(data: request.body, encoding: .utf8), "{\"a\":true}")
    }

    func testParseDropsQueryAndRejectsMalformedRequests() {
        guard case .complete(let request) = BrowserClipperHTTPRequest.parse(Data("GET /folders?x=1 HTTP/1.1\r\nHost: localhost:23240\r\n\r\n".utf8)) else {
            return XCTFail("Expected a complete request")
        }
        XCTAssertEqual(request.path, "/folders")
        XCTAssertTrue(request.body.isEmpty)

        XCTAssertEqual(BrowserClipperHTTPRequest.parse(Data("NONSENSE\r\n\r\n".utf8)), .invalid(status: 400))
        XCTAssertEqual(
            BrowserClipperHTTPRequest.parse(Data("POST /save HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)),
            .invalid(status: 501)
        )
        XCTAssertEqual(
            BrowserClipperHTTPRequest.parse(Data("POST /save HTTP/1.1\r\nContent-Length: 100\r\n\r\n".utf8), maxBodyLength: 10),
            .invalid(status: 413)
        )
    }

    func testOnlyTheExtensionMayCallTheAPI() {
        func request(_ headers: [String: String]) -> BrowserClipperHTTPRequest {
            BrowserClipperHTTPRequest(method: "GET", path: "/ping", headers: headers, body: Data())
        }
        let port: UInt16 = 23240
        let valid = ["host": "127.0.0.1:23240", "x-freddie-clipper": "1"]

        XCTAssertNil(BrowserClipperRequestHandler.rejection(for: request(valid), port: port))
        XCTAssertNil(BrowserClipperRequestHandler.rejection(
            for: request(valid.merging(["origin": "chrome-extension://abcdef"]) { $1 }),
            port: port
        ))
        XCTAssertNil(BrowserClipperRequestHandler.rejection(
            for: request(["host": "localhost:23240", "x-freddie-clipper": "1", "origin": "moz-extension://1234"]),
            port: port
        ))

        // A web page, a page that rebinds its domain to 127.0.0.1, and a request without the header.
        XCTAssertEqual(BrowserClipperRequestHandler.rejection(
            for: request(valid.merging(["origin": "https://evil.example"]) { $1 }),
            port: port
        )?.status, 403)
        XCTAssertEqual(BrowserClipperRequestHandler.rejection(
            for: request(["host": "evil.example:23240", "x-freddie-clipper": "1"]),
            port: port
        )?.status, 403)
        XCTAssertEqual(BrowserClipperRequestHandler.rejection(
            for: request(["host": "127.0.0.1:23240"]),
            port: port
        )?.status, 403)
    }

    // MARK: Routing

    @MainActor
    func testPingFoldersAndUnknownRoutes() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        context.insert(PaperFolder(name: "Reading"))
        context.insert(PaperFolder(name: "Archive"))
        try context.save()
        let handler = makeHandler(container: container)

        let ping = await handler.response(to: apiRequest("GET", "/ping"))
        XCTAssertEqual(ping.status, 200)
        XCTAssertEqual(try json(ping)["api"] as? Int, BrowserClipperAPI.version)

        let folders = await handler.response(to: apiRequest("GET", "/folders"))
        let names = (try json(folders)["folders"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
        XCTAssertEqual(names, ["Archive", "Reading"])

        let wrongMethod = await handler.response(to: apiRequest("GET", "/save"))
        XCTAssertEqual(wrongMethod.status, 405)
        let missing = await handler.response(to: apiRequest("GET", "/nope"))
        XCTAssertEqual(missing.status, 404)
        let badBody = await handler.response(to: apiRequest("POST", "/save", body: Data("{".utf8)))
        XCTAssertEqual(badBody.status, 400)
    }

    // MARK: Saving

    @MainActor
    func testSelectionClipKeepsExactlyTheSelectionInTheReadingLayout() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let folder = PaperFolder(name: "Clips")
        context.insert(folder)
        try context.save()
        let handler = makeHandler(container: container)

        let response = await handler.response(to: apiRequest("POST", "/save", json: [
            "kind": "html",
            "url": "https://example.com/post#comments",
            "title": "A Short Quote",
            "extraction": "selection",
            "html": """
            <!DOCTYPE html><html><head><title>A Short Quote</title><script>alert(1)</script></head>
            <body><p>Attention is all you need.</p></body></html>
            """,
            "metadata": [
                "authors": ["Ashish Vaswani", " "],
                "doi": "https://doi.org/10.48550/arXiv.1706.03762",
                "publishedDate": "2017/06/12"
            ],
            "folderID": folder.id.uuidString
        ]))

        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(try json(response)["status"] as? String, "saved")
        let paper = try XCTUnwrap(context.fetch(FetchDescriptor<Paper>()).first)
        XCTAssertEqual(try json(response)["openURL"] as? String, "readpaper://paper/\(paper.id.uuidString)")
        XCTAssertEqual(paper.title, "A Short Quote")
        XCTAssertEqual(paper.htmlURLString, "https://example.com/post")
        XCTAssertEqual(paper.authors, ["Ashish Vaswani"])
        XCTAssertEqual(paper.doi, "10.48550/arXiv.1706.03762")
        XCTAssertEqual(paper.publishedAt, BrowserClipImporter.parseDate("2017-06-12"))
        XCTAssertEqual(try context.fetch(FetchDescriptor<PaperFolderMembership>()).first?.folderID, folder.id)

        let attachment = try XCTUnwrap(context.fetch(FetchDescriptor<PaperAttachment>()).first)
        XCTAssertEqual(attachment.kind, .html)
        XCTAssertEqual(attachment.source, .webPage)
        // Far shorter than Readability accepts, but the reader chose it.
        let document = try SwiftSoup.parse(String(contentsOf: attachment.fileURL, encoding: .utf8))
        XCTAssertEqual(try document.select(".rp-readability-content").text(), "Attention is all you need.")
        XCTAssertTrue(try document.select("script").isEmpty())
    }

    @MainActor
    func testArticleClipIsSimplifiedAndFullPageKeepsItsLayout() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let handler = makeHandler(container: container)
        let paragraphs = (1...6).map {
            "<p>Paragraph \($0) explains the method in enough detail for Readability to keep it as article text.</p>"
        }.joined()
        let page = """
        <!DOCTYPE html><html><head><title>Method Notes</title></head>
        <body class="site-theme"><article><div class="share">Share on social media</div>\(paragraphs)</article></body></html>
        """

        _ = await handler.response(to: apiRequest("POST", "/save", json: [
            "kind": "html", "url": "https://example.com/article", "extraction": "article", "html": page
        ]))
        _ = await handler.response(to: apiRequest("POST", "/save", json: [
            "kind": "html", "url": "https://example.com/page", "extraction": "page", "html": page
        ]))

        let papers = try context.fetch(FetchDescriptor<Paper>())
        let article = try XCTUnwrap(papers.first { $0.htmlURLString == "https://example.com/article" })
        let fullPage = try XCTUnwrap(papers.first { $0.htmlURLString == "https://example.com/page" })
        XCTAssertEqual(article.title, "Method Notes")

        let articleHTML = try savedHTML(for: article, in: context)
        XCTAssertTrue(articleHTML.contains("rp-readability-content"))
        XCTAssertTrue(articleHTML.contains("Paragraph 6 explains"))

        let pageDocument = try SwiftSoup.parse(savedHTML(for: fullPage, in: context))
        XCTAssertTrue(try pageDocument.select(".rp-readability-content").isEmpty())
        XCTAssertEqual(pageDocument.body()?.hasClass("site-theme"), true)
        XCTAssertTrue(try pageDocument.select(".share").text().contains("Share on social media"))
    }

    @MainActor
    func testSavingAPageTwiceAsksBeforeDuplicating() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let handler = makeHandler(container: container)
        let clip: [String: Any] = [
            "kind": "html", "url": "https://example.com/again", "extraction": "selection",
            "html": "<html><head><title>Again</title></head><body><p>Saved twice.</p></body></html>"
        ]

        let first = try json(await handler.response(to: apiRequest("POST", "/save", json: clip)))
        let second = try json(await handler.response(to: apiRequest("POST", "/save", json: clip)))
        XCTAssertEqual(second["status"] as? String, "exists")
        XCTAssertEqual(second["paperID"] as? String, first["paperID"] as? String)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Paper>()), 1)

        var forced = clip
        forced["allowDuplicate"] = true
        let third = try json(await handler.response(to: apiRequest("POST", "/save", json: forced)))
        XCTAssertEqual(third["status"] as? String, "saved")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Paper>()), 2)
    }

    @MainActor
    func testPDFClipUsesTheBrowsersCopyAndThePagesMetadata() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let handler = makeHandler(container: container)

        let response = await handler.response(to: apiRequest("POST", "/save", json: [
            "kind": "pdf",
            "url": "https://publisher.example/article/42",
            "pdfURL": "https://publisher.example/article/42.pdf",
            "pdfBase64": try makePDF().base64EncodedString(),
            "title": "A Paywalled Paper",
            "metadata": ["authors": ["Ada Lovelace"], "doi": "10.1000/xyz123", "abstract": "We study engines."]
        ]))

        XCTAssertEqual(response.status, 200)
        let paper = try XCTUnwrap(context.fetch(FetchDescriptor<Paper>()).first)
        XCTAssertEqual(paper.title, "A Paywalled Paper")
        XCTAssertEqual(paper.authors, ["Ada Lovelace"])
        XCTAssertEqual(paper.doi, "10.1000/xyz123")
        XCTAssertEqual(paper.abstractText, "We study engines.")
        XCTAssertEqual(paper.pdfURLString, "https://publisher.example/article/42.pdf")
        XCTAssertEqual(paper.htmlURLString, "https://publisher.example/article/42")
        let attachment = try XCTUnwrap(context.fetch(FetchDescriptor<PaperAttachment>()).first)
        XCTAssertEqual(attachment.kind, .pdf)
        XCTAssertTrue(FileManager.default.fileExists(atPath: attachment.fileURL.path))

        // The same DOI from another address is the same paper.
        let again = try json(await handler.response(to: apiRequest("POST", "/save", json: [
            "kind": "pdf", "url": "https://mirror.example/42", "pdfBase64": try makePDF().base64EncodedString(),
            "metadata": ["doi": "10.1000/XYZ123"]
        ])))
        XCTAssertEqual(again["status"] as? String, "exists")
    }

    @MainActor
    func testPDFOfAClippedPageJoinsTheSamePaper() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let handler = makeHandler(container: container)
        let first = try json(await handler.response(to: apiRequest("POST", "/save", json: [
            "kind": "html", "url": "https://journal.example/paper/7", "extraction": "selection", "title": "My Title",
            "html": "<html><body><p>The abstract, clipped first.</p></body></html>",
            "metadata": ["authors": ["Grace Hopper"]]
        ])))

        let second = try json(await handler.response(to: apiRequest("POST", "/save", json: [
            "kind": "pdf", "url": "https://journal.example/paper/7", "pdfURL": "https://journal.example/paper/7.pdf",
            "pdfBase64": try makePDF().base64EncodedString(), "title": "Publisher Title",
            "metadata": ["authors": ["G. Hopper"], "doi": "10.1000/seven"]
        ])))

        XCTAssertEqual(second["status"] as? String, "saved")
        XCTAssertEqual(second["paperID"] as? String, first["paperID"] as? String)
        let paper = try XCTUnwrap(context.fetch(FetchDescriptor<Paper>()).first)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Paper>()), 1)
        XCTAssertEqual(paper.title, "My Title")
        XCTAssertEqual(paper.authors, ["Grace Hopper"])
        XCTAssertEqual(paper.doi, "10.1000/seven")
        XCTAssertEqual(paper.pdfURLString, "https://journal.example/paper/7.pdf")
        XCTAssertEqual(Set(try context.fetch(FetchDescriptor<PaperAttachment>()).map(\.kind)), [.html, .pdf])
    }

    @MainActor
    func testFailedPDFClipLeavesNothingBehind() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let handler = makeHandler(container: container)

        let response = await handler.response(to: apiRequest("POST", "/save", json: [
            "kind": "pdf", "url": "https://example.com/login", "pdfBase64": Data("<html>Sign in</html>".utf8).base64EncodedString()
        ]))

        XCTAssertEqual(response.status, 500)
        XCTAssertEqual(try json(response)["error"] as? String, BrowserClipError.notAPDF.errorDescription)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Paper>()), 0)
        let libraryContents = try? FileManager.default.contentsOfDirectory(
            atPath: rootURL.appendingPathComponent("Library").path
        )
        XCTAssertEqual(libraryContents ?? [], [])
    }

    @MainActor
    func testClipIntoADeletedFolderStaysUnfiled() async throws {
        let container = try makeContainer()
        let handler = makeHandler(container: container)

        let response = await handler.response(to: apiRequest("POST", "/save", json: [
            "kind": "html", "url": "https://example.com/unfiled", "extraction": "selection",
            "html": "<html><body><p>Unfiled clip.</p></body></html>", "folderID": UUID().uuidString
        ]))

        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<PaperFolderMembership>()), 0)
    }

    func testParseDateAcceptsCommonMetadataFormats() {
        let calendar = Calendar(identifier: .gregorian)
        func components(_ value: String) -> DateComponents? {
            BrowserClipImporter.parseDate(value).map {
                var utc = calendar
                utc.timeZone = TimeZone(secondsFromGMT: 0)!
                return utc.dateComponents([.year, .month, .day], from: $0)
            }
        }
        XCTAssertEqual(components("2017-06-12"), DateComponents(year: 2017, month: 6, day: 12))
        XCTAssertEqual(components("2017/06/12"), DateComponents(year: 2017, month: 6, day: 12))
        XCTAssertEqual(components("2017-06-12T08:00:00Z"), DateComponents(year: 2017, month: 6, day: 12))
        XCTAssertEqual(components("2017-06"), DateComponents(year: 2017, month: 6, day: 1))
        XCTAssertEqual(components("2017"), DateComponents(year: 2017, month: 1, day: 1))
        XCTAssertNil(BrowserClipImporter.parseDate("sometime"))
    }

    // MARK: Socket

    @MainActor
    func testServerAnswersOnTheLoopbackInterface() async throws {
        let server = BrowserClipperServer()
        let port = UInt16.random(in: 41000...48000)
        server.start(modelContainer: try makeContainer(), port: port)
        defer { server.stop() }
        for _ in 0..<40 where server.state != .listening(port: port) {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(server.state, .listening(port: port))

        var request = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/ping")))
        request.setValue("1", forHTTPHeaderField: "X-Freddie-Clipper")
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(object?["app"] as? String, "Freddie")

        var withoutHeader = request
        withoutHeader.setValue(nil, forHTTPHeaderField: "X-Freddie-Clipper")
        let (_, rejected) = try await URLSession(configuration: .ephemeral).data(for: withoutHeader)
        XCTAssertEqual((rejected as? HTTPURLResponse)?.statusCode, 403)
    }

    // MARK: Helpers

    private func makeContainer() throws -> ModelContainer {
        let container = try ModelContainer(
            for: ReadPaperModelStore.schema,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        containers.append(container)
        return container
    }

    @MainActor
    private func makeHandler(container: ModelContainer) -> BrowserClipperRequestHandler {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let root = rootURL!
        return BrowserClipperRequestHandler(
            modelContainer: container,
            makeImporter: {
                BrowserClipImporter(
                    fileStore: PaperFileStore(applicationSupportDirectory: root),
                    htmlLocalizer: HTMLLocalizer(session: session, resourceTimeBudget: .seconds(1)),
                    session: session
                )
            }
        )
    }

    private func apiRequest(_ method: String, _ path: String, json: [String: Any]) -> BrowserClipperHTTPRequest {
        apiRequest(method, path, body: (try? JSONSerialization.data(withJSONObject: json)) ?? Data())
    }

    private func apiRequest(_ method: String, _ path: String, body: Data = Data()) -> BrowserClipperHTTPRequest {
        BrowserClipperHTTPRequest(
            method: method,
            path: path,
            headers: ["host": "127.0.0.1:\(BrowserClipperAPI.port)", "x-freddie-clipper": "1", "origin": "chrome-extension://test"],
            body: body
        )
    }

    private func json(_ response: BrowserClipperHTTPResponse) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    }

    @MainActor
    private func savedHTML(for paper: Paper, in context: ModelContext) throws -> String {
        let paperID = paper.id
        let attachment = try XCTUnwrap(context.fetch(FetchDescriptor<PaperAttachment>(
            predicate: #Predicate { $0.paperID == paperID }
        )).first)
        return try String(contentsOf: attachment.fileURL, encoding: .utf8)
    }

    private func makePDF() throws -> Data {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 200, height: 200)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        context.beginPDFPage(nil)
        context.fill(CGRect(x: 20, y: 20, width: 40, height: 40))
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }
}

/// Page resources are not needed to save a clip; every download fails.
private final class OfflineURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}
