import XCTest
@testable import ReadPaper

final class MarkdownLiveSyntaxTests: XCTestCase {
    private typealias Syntax = MarkdownLiveSyntax

    private func parse(_ text: String, fence: Syntax.FenceState? = nil) -> Syntax.Line {
        Syntax.parse(text, fence: fence).line
    }

    private func range(_ location: Int, _ length: Int) -> NSRange {
        NSRange(location: location, length: length)
    }

    func testHeadingHidesItsMarkersAndKeepsInlineStyles() {
        let line = parse("## Title **bold** ##")

        XCTAssertEqual(line.headingLevel, 2)
        XCTAssertEqual(line.spans, [.init(kind: .strong, range: range(11, 4))])
        XCTAssertEqual(Set(line.markers), [range(0, 3), range(17, 3), range(9, 2), range(15, 2)])
        XCTAssertNil(parse("#hashtag").headingLevel)
        XCTAssertEqual(parse("####### seven").headingLevel, nil)
    }

    func testNestedEmphasisFollowsCommonMark() {
        let line = parse("***a***")

        XCTAssertEqual(line.spans, [
            .init(kind: .emphasis, range: range(1, 5)),
            .init(kind: .strong, range: range(3, 1)),
        ])
        XCTAssertEqual(Set(line.markers), [range(0, 1), range(1, 2), range(4, 2), range(6, 1)])
    }

    func testIntrawordUnderscoresAreNotEmphasis() {
        XCTAssertTrue(parse("snake_case_name and x_i y_j").spans.isEmpty)
        XCTAssertEqual(parse("an _italic_ word").spans, [.init(kind: .emphasis, range: range(4, 6))])
        XCTAssertEqual(parse("a*b*c").spans, [.init(kind: .emphasis, range: range(2, 1))])
    }

    func testCJKEmphasisAndUnmatchedDelimiters() {
        XCTAssertEqual(parse("这是**中文**测试").spans, [.init(kind: .strong, range: range(4, 2))])
        let unmatched = parse("**open and *close")
        XCTAssertTrue(unmatched.spans.isEmpty)
        XCTAssertTrue(unmatched.markers.isEmpty)
    }

    func testCodeSpansAndEscapesAreNotFormatted() {
        let code = parse("use `a*b*c` here")
        XCTAssertEqual(code.spans, [.init(kind: .code, range: range(5, 5))])
        XCTAssertEqual(Set(code.markers), [range(4, 1), range(10, 1)])

        let escaped = parse(#"\*not\* and \[x\]"#)
        XCTAssertTrue(escaped.spans.isEmpty)
        XCTAssertEqual(Set(escaped.markers), [range(0, 1), range(5, 1), range(12, 1), range(15, 1)])
    }

    func testLinksHideTheirDestinationAndAllowEmphasisInTheLabel() {
        let line = parse("see [the *paper*](https://x.y/a_(b)) now")

        XCTAssertEqual(line.spans, [
            .init(kind: .link(destination: "https://x.y/a_(b)", title: nil), range: range(5, 11)),
            .init(kind: .emphasis, range: range(10, 5)),
        ])
        XCTAssertEqual(line.destinations, [range(18, 17)])
        XCTAssertTrue(line.markers.contains(range(4, 1)))
        XCTAssertTrue(line.markers.contains(range(16, 20)))
    }

    func testCitationsImagesAndAutolinks() {
        let destination = "readpaper://paper/\(UUID().uuidString)?p=2"
        let citation = parse("> — [Vaswani 2017](\(destination))")
        XCTAssertEqual(citation.quoteDepth, 1)
        XCTAssertEqual(citation.spans, [.init(kind: .citation(destination: destination, title: nil), range: range(5, 12))])

        let image = parse("![alt text](figure.png)")
        XCTAssertEqual(image.spans, [.init(kind: .link(destination: "figure.png", title: nil), range: range(2, 8))])
        XCTAssertTrue(image.markers.contains(range(0, 2)))

        let autolink = parse("<https://example.com/a>")
        XCTAssertEqual(autolink.spans, [.init(kind: .link(destination: "https://example.com/a", title: nil), range: range(1, 21))])
        XCTAssertTrue(parse("a <b> c").spans.isEmpty)
    }

    func testLinkTitlesAreReadAndHiddenWithTheDestination() {
        let line = parse(#"[a](u "say \"hi\"") b"#)

        XCTAssertEqual(line.spans, [.init(kind: .link(destination: "u", title: #"say "hi""#), range: range(1, 1))])
        XCTAssertEqual(line.destinations, [range(4, 14)])
        XCTAssertTrue(line.markers.contains(range(2, 17)))
        XCTAssertTrue(parse(#"[a](u "unclosed)"#).spans.isEmpty)
    }

    func testNestedQuotesAndListItems() {
        let quote = parse("> > nested **x**")
        XCTAssertEqual(quote.quoteDepth, 2)
        XCTAssertEqual(Array(quote.markers.prefix(2)), [range(0, 2), range(2, 2)])
        XCTAssertEqual(quote.spans, [.init(kind: .strong, range: range(13, 1))])

        let bullet = parse("  - item")
        XCTAssertEqual(bullet.list, .init(isOrdered: false, range: range(2, 2), bulletLocation: 2))

        let ordered = parse("12) step")
        XCTAssertEqual(ordered.list, .init(isOrdered: true, range: range(0, 4), bulletLocation: nil))

        let quotedItem = parse("> - quoted item")
        XCTAssertEqual(quotedItem.quoteDepth, 1)
        XCTAssertEqual(quotedItem.list?.range, range(2, 2))

        XCTAssertNil(parse("-no space").list)
        XCTAssertNil(parse("**bold** start").list)
        XCTAssertEqual(parse("- ").list?.range, range(0, 2))
    }

    func testThematicBreaksAndBlankLines() {
        XCTAssertTrue(parse("---").isRule)
        XCTAssertTrue(parse("* * *").isRule)
        XCTAssertTrue(parse("- - -").isRule)
        XCTAssertFalse(parse("--").isRule)
        XCTAssertEqual(parse("___").markers, [range(0, 3)])
        XCTAssertTrue(parse("   ").isBlank)
    }

    func testFencedCodeBlocks() {
        let opening = Syntax.parse("```swift", fence: nil)
        XCTAssertTrue(opening.line.isFence)
        XCTAssertEqual(opening.fence, .init(character: 0x60, length: 3))

        let inside = Syntax.parse("let x = **y** // `z`", fence: opening.fence)
        XCTAssertTrue(inside.line.isCode)
        XCTAssertTrue(inside.line.spans.isEmpty)
        XCTAssertEqual(inside.fence, opening.fence)

        XCTAssertEqual(Syntax.parse("~~~", fence: opening.fence).fence, opening.fence)
        let closing = Syntax.parse("````", fence: opening.fence)
        XCTAssertTrue(closing.line.isFence)
        XCTAssertNil(closing.fence)

        XCTAssertNil(Syntax.parse("``` not `a` fence", fence: nil).fence)
    }

    func testStrikethroughNeedsDoubleTildes() {
        XCTAssertEqual(parse("~~gone~~ now").spans, [.init(kind: .strikethrough, range: range(2, 4))])
        XCTAssertTrue(parse("~one~ and ~5%").spans.isEmpty)
    }
}
