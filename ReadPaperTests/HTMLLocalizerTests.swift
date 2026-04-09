import XCTest
@testable import ReadPaper

final class HTMLLocalizerTests: XCTestCase {
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
        XCTAssertEqual(try document.select(".rp-readability-title").text().isEmpty, false)
        XCTAssertTrue(try document.outerHtml().contains("rp-readability-content"))
        XCTAssertTrue(try document.select(".rp-readability-content").text().contains("This is article content"))
        XCTAssertFalse(try document.outerHtml().contains(">Menu<"))
        XCTAssertEqual(try document.select(".rp-readability-content a[href]").first()?.attr("href"), "https://example.com/note")
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
