import Foundation
import SwiftSoup
import XCTest
@testable import ReadPaper

final class HTMLLocalizerTests: XCTestCase {
    override func tearDown() {
        MockHTMLLocalizerURLProtocol.reset()
        super.tearDown()
    }

    func testMakeDocumentForLocalizationUsesReadabilityContent() throws {
        let paragraph = String(repeating: "This is article content that should survive readability extraction. ", count: 12)
        let html = """
        <html>
        <head>
        <base href="https://example.com/paper/123/">
        <title>Original</title>
        </head>
        <body>
        <nav><a href="/menu">Menu</a></nav>
        <article>
        <h1>Readable Title</h1>
        <p>\(paragraph)</p>
        <p><a href="/note">Reference</a></p>
        </article>
        </body>
        </html>
        """

        let document = try HTMLLocalizer().makeDocumentForLocalization(
            html: html,
            sourceURL: URL(string: "https://example.com/paper/123")!
        )

        XCTAssertEqual(try document.select("base").count, 0)
        XCTAssertEqual(document.body()?.hasClass("rp-readability-body"), true)
        XCTAssertEqual(try document.select(".rp-readability-shell").count, 1)
        XCTAssertEqual(try document.select("div.rp-readability-header").count, 1)
        XCTAssertEqual(try document.select("header.rp-readability-header").count, 0)
        XCTAssertEqual(try document.select(".rp-readability-title").text().isEmpty, false)
        XCTAssertTrue(try document.outerHtml().contains("rp-readability-content"))
        XCTAssertTrue(try document.select(".rp-readability-content").text().contains("This is article content"))
        XCTAssertFalse(try document.outerHtml().contains(">Menu<"))
        XCTAssertEqual(try document.select(".rp-readability-content a[href]").first()?.attr("href"), "https://example.com/note")

        let style = try XCTUnwrap(try document.getElementById("rp-readability-style"))
        let readabilityCSS = style.data()
        XCTAssertTrue(readabilityCSS.contains(".rp-readability-content .grid > *"))
        XCTAssertFalse(try style.outerHtml().contains("&gt;"))
    }

    func testReadabilityStylesResetKnownLayoutWrappers() throws {
        let paragraph = String(repeating: "This is article content that should remain in one readable column. ", count: 12)
        let html = """
        <html>
        <head>
        <style>
        .page { display: grid; grid-template-columns: 1fr 1fr; padding: 64px 0; }
        .available-content { display: flex; }
        .pc-display-grid { display: grid; }
        </style>
        </head>
        <body>
        <article>
        <h1>Readable Title</h1>
        <div class="page">
        <div class="available-content">
        <div class="pc-display-grid">
        <p>\(paragraph)</p>
        </div>
        </div>
        </div>
        </article>
        </body>
        </html>
        """

        let document = try HTMLLocalizer().makeDocumentForLocalization(
            html: html,
            sourceURL: URL(string: "https://example.com/paper/123")!
        )

        let style = try XCTUnwrap(try document.getElementById("rp-readability-style"))
        let readabilityCSS = style.data()
        XCTAssertTrue(readabilityCSS.contains(".rp-readability-content .page"))
        XCTAssertTrue(readabilityCSS.contains(".rp-readability-content .available-content"))
        XCTAssertTrue(readabilityCSS.contains(".rp-readability-content [class~='pc-display-grid']"))
        XCTAssertTrue(readabilityCSS.contains("display: block !important"))
        XCTAssertNotNil(readabilityCSS.range(
            of: #"\.rp-readability-content\s+\.available-content\s*\{\s*padding:\s*0\s*!important;\s*\}"#,
            options: .regularExpression
        ))
        XCTAssertNil(readabilityCSS.range(
            of: #"\.rp-readability-content\s+\.page[^{]*\{[^}]*padding:\s*0\s*!important"#,
            options: .regularExpression
        ))
    }

    func testLocalizeWritesDownloadedStylesAsRawCSS() async throws {
        let paragraph = String(repeating: "This is article content that should survive readability extraction. ", count: 12)
        let html = """
        <html>
        <head>
        <link rel="stylesheet" href="/style.css">
        </head>
        <body>
        <article>
        <h1>Readable Title</h1>
        <p>\(paragraph)</p>
        </article>
        </body>
        </html>
        """

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockHTMLLocalizerURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockHTMLLocalizerURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(url.path, "/style.css")
            return (
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/css"])!,
                Data(".wrapper > * { display: block; }".utf8)
            )
        }

        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let resourcesURL = rootURL.appendingPathComponent("Resources", isDirectory: true)
        let outputURL = rootURL.appendingPathComponent("paper.html")

        _ = try await HTMLLocalizer(session: session).localize(
            htmlData: Data(html.utf8),
            sourceURL: URL(string: "https://example.com/article")!,
            outputURL: outputURL,
            resourcesDirectory: resourcesURL
        )

        let output = try String(contentsOf: outputURL, encoding: .utf8)
        let document = try SwiftSoup.parse(output)
        let downloadedStyle = try XCTUnwrap(try document.select("style").array().first { $0.data().contains(".wrapper") })
        XCTAssertTrue(downloadedStyle.data().contains(".wrapper > *"))
        XCTAssertFalse(try downloadedStyle.outerHtml().contains("&gt;"))
    }

    func testMakeDocumentForLocalizationFallsBackWhenReadabilityCannotExtract() throws {
        let html = """
        <html>
        <head><base href="https://example.com/base/"></head>
        <body><p>short</p><a href="/note">Link</a></body>
        </html>
        """

        let document = try HTMLLocalizer().makeDocumentForLocalization(
            html: html,
            sourceURL: URL(string: "https://example.com/paper/123")!
        )

        XCTAssertEqual(try document.select("base").count, 0)
        XCTAssertEqual(try document.select(".rp-readability-shell").count, 0)
        XCTAssertEqual(try document.select("p").text(), "short")
        XCTAssertEqual(try document.select("a[href]").first()?.attr("href"), "https://example.com/note")
    }
}

private final class MockHTMLLocalizerURLProtocol: URLProtocol {
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
        guard let requestHandler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try requestHandler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
