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

    func testRenderKeepsMarkdownLinkAttribute() {
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
}
