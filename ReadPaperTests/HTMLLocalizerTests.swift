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

    func testLocalizeSplitsReadabilityMarkdownPreIntoParagraphs() async throws {
        let firstParagraph = String(repeating: "DwarfStar local inference prose with a preserved link. ", count: 8)
        let secondParagraph = String(repeating: "Follow-up prose should become a separate translatable paragraph. ", count: 8)
        let html = """
        <html>
        <head><title>A few words on DS4 - &lt;antirez&gt;</title></head>
        <body>
        <div id="content">
        <section id="newslist"><article data-news-id="165"><h2><a href="/news/165">A few words on DS4</a></h2></article></section>
        <topcomment>
        <article class="comment" data-comment-id="165-" id="165-">
        <span class="info"><span class="username"><a href="/user/antirez">antirez</a></span> 16 hours ago. 109571 views.</span>
        <pre>\(firstParagraph)<a rel="nofollow" href="https://github.com/antirez/ds4">https://github.com/antirez/ds4</a>

        \(secondParagraph)</pre>
        </article>
        </topcomment>
        </div>
        </body>
        </html>
        """

        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let resourcesURL = rootURL.appendingPathComponent("Resources", isDirectory: true)
        let outputURL = rootURL.appendingPathComponent("paper.html")

        _ = try await HTMLLocalizer().localize(
            htmlData: Data(html.utf8),
            sourceURL: URL(string: "https://antirez.com/news/165")!,
            outputURL: outputURL,
            resourcesDirectory: resourcesURL
        )

        let output = try String(contentsOf: outputURL, encoding: .utf8)
        let document = try SwiftSoup.parse(output)
        XCTAssertEqual(try document.select(".rp-readability-excerpt").count, 0)
        XCTAssertEqual(try document.select(".rp-readability-content pre[data-readability-pre-type=markdown]").count, 0)

        let style = try XCTUnwrap(try document.getElementById("rp-readability-style"))
        XCTAssertTrue(style.data().contains(".rp-readability-content p.rp-readability-prose-paragraph"))

        let paragraphs = try document.select(".rp-readability-content article.comment > p.rp-readability-prose-paragraph").array()
        XCTAssertEqual(paragraphs.count, 2)
        XCTAssertTrue(try paragraphs[0].text().contains("DwarfStar local inference prose"))
        XCTAssertTrue(try paragraphs[1].text().contains("Follow-up prose should become a separate"))
        XCTAssertEqual(try paragraphs[0].select("a[href]").first()?.attr("href"), "https://github.com/antirez/ds4")
    }

    func testLocalizeTunesEmbeddedMediaForReaderPerformance() async throws {
        let paragraph = String(repeating: "This is article content that should survive readability extraction. ", count: 12)
        let html = """
        <html>
        <body>
        <article>
        <h1>Readable Title</h1>
        <p>\(paragraph)</p>
        <img src="/figure.png">
        <video controls src="https://cdn.example.com/demo.mp4"></video>
        <audio src="https://cdn.example.com/demo.mp3"></audio>
        </article>
        </body>
        </html>
        """

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockHTMLLocalizerURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockHTMLLocalizerURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(url.path, "/figure.png")
            return (
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "image/png"])!,
                Data([0x89, 0x50, 0x4E, 0x47])
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

        let image = try XCTUnwrap(try document.select("img").first())
        XCTAssertEqual(try image.attr("loading"), "lazy")
        XCTAssertEqual(try image.attr("decoding"), "async")
        XCTAssertTrue(try image.attr("src").hasPrefix("Resources/"))

        let video = try XCTUnwrap(try document.select("video").first())
        XCTAssertEqual(try video.attr("preload"), "none")

        let audio = try XCTUnwrap(try document.select("audio").first())
        XCTAssertEqual(try audio.attr("preload"), "none")
    }

    func testLocalizePrefersDownloadedImageOverResponsiveRemoteCandidates() async throws {
        let html = """
        <html>
        <body>
        <article>
        <p>Short article body.</p>
        <picture>
        <source type="image/webp" srcset="https://substackcdn.com/image/fetch/$s_!abc!, w_424, c_limit, f_webp, q_auto:good/https%3A%2F%2Fsubstack-post-media.s3.amazonaws.com%2Fpublic%2Fimages%2Ffigure.jpeg 424w, https://substackcdn.com/image/fetch/$s_!abc!, w_848, c_limit, f_webp, q_auto:good/https%3A%2F%2Fsubstack-post-media.s3.amazonaws.com%2Fpublic%2Fimages%2Ffigure.jpeg 848w" sizes="100vw">
        <img src="/public/images/figure.jpeg" srcset="https://substackcdn.com/image/fetch/$s_!abc!,w_424,c_limit,f_auto,q_auto:good/https%3A%2F%2Fsubstack-post-media.s3.amazonaws.com%2Fpublic%2Fimages%2Ffigure.jpeg 424w, https://substackcdn.com/image/fetch/$s_!abc!,w_848,c_limit,f_auto,q_auto:good/https%3A%2F%2Fsubstack-post-media.s3.amazonaws.com%2Fpublic%2Fimages%2Ffigure.jpeg 848w" sizes="100vw">
        </picture>
        </article>
        </body>
        </html>
        """

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockHTMLLocalizerURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockHTMLLocalizerURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(url.host, "example.com")
            XCTAssertEqual(url.path, "/public/images/figure.jpeg")
            return (
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "image/jpeg"])!,
                Data([0xFF, 0xD8, 0xFF, 0xD9])
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

        XCTAssertFalse(output.contains("substackcdn.com/image/fetch"))
        XCTAssertEqual(try document.select("picture source").count, 0)

        let image = try XCTUnwrap(try document.select("picture img").first())
        XCTAssertTrue(try image.attr("src").hasPrefix("Resources/"))
        XCTAssertEqual(try image.attr("srcset"), "")
        XCTAssertEqual(try image.attr("sizes"), "")
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
