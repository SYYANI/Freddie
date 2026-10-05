import AppKit
import XCTest
@testable import ReadPaper

final class NoteMarkdownRendererTests: XCTestCase {
    func testRenderNormalizesCommonMarkdownBlocks() {
        let rendered = NoteMarkdownRenderer.render(
            """
            # Heading

            - First item
            * Second item

            > Quoted line

            ```swift
            print("hello")
            ```
            """
        )

        XCTAssertTrue(rendered.string.contains("Heading"))
        XCTAssertTrue(rendered.string.contains("• First item"))
        XCTAssertTrue(rendered.string.contains("• Second item"))
        XCTAssertTrue(rendered.string.contains("> Quoted line"))
        XCTAssertTrue(rendered.string.contains("print(\"hello\")"))
        XCTAssertFalse(rendered.string.contains("# Heading"))
        XCTAssertFalse(rendered.string.contains("```"))
    }

    func testRenderKeepsMarkdownLinkAttribute() throws {
        let rendered = NoteMarkdownRenderer.render("Visit [OpenAI](https://openai.com/docs)")
        let range = NSRange(try XCTUnwrap(rendered.string.range(of: "OpenAI")), in: rendered.string)
        let link = rendered.attribute(.link, at: range.location, effectiveRange: nil) as? URL

        XCTAssertEqual(link?.absoluteString, "https://openai.com/docs")
    }

    func testRenderAppliesInlineEmphasisTraits() throws {
        let rendered = NoteMarkdownRenderer.render("**Bold** and *Italic*")
        let boldRange = NSRange(try XCTUnwrap(rendered.string.range(of: "Bold")), in: rendered.string)
        let italicRange = NSRange(try XCTUnwrap(rendered.string.range(of: "Italic")), in: rendered.string)

        let boldFont = try XCTUnwrap(rendered.attribute(.font, at: boldRange.location, effectiveRange: nil) as? NSFont)
        let italicFont = try XCTUnwrap(rendered.attribute(.font, at: italicRange.location, effectiveRange: nil) as? NSFont)

        XCTAssertTrue(boldFont.fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertTrue(italicFont.fontDescriptor.symbolicTraits.contains(.italic))
    }

    func testHTMLRendersBlocksAndInlineStylesForMarginNotes() {
        let html = NoteMarkdownRenderer.html(
            """
            ## Idea

            **Bold**, *italic* and `x < y`
            - item [link](https://example.com/a?b=1&c=2)

            > quoted
            """
        )

        XCTAssertEqual(
            html,
            "<h2>Idea</h2>"
                + "<p><strong>Bold</strong>, <em>italic</em> and <code>x &lt; y</code></p>"
                + "<ul><li>item <a href=\"https://example.com/a?b=1&amp;c=2\">link</a></li></ul>"
                + "<blockquote>quoted</blockquote>"
        )
    }

    func testHTMLEscapesRawMarkupAndDropsUnsafeLinks() {
        let html = NoteMarkdownRenderer.html(
            "<script>alert(1)</script> [run](javascript:void)\n\n```\n<b>code</b>\n```"
        )

        XCTAssertFalse(html.contains("<script>"))
        XCTAssertFalse(html.contains("javascript:"))
        XCTAssertTrue(html.contains("&lt;script&gt;"))
        XCTAssertTrue(html.contains("<pre><code>&lt;b&gt;code&lt;/b&gt;</code></pre>"))
    }
}
