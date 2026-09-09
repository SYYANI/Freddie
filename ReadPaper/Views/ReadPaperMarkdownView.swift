import AppKit
import SwiftUI
import SwiftStreamingMarkdown

enum ReadPaperMarkdownStyle {
    static let config: MarkdownRenderConfig = makeConfig()

    private static func makeConfig() -> MarkdownRenderConfig {
        let body = textFonts(size: 14)
        let paragraph = MarkdownRenderConfig.MarkdownTextStyle(
            textFonts: body,
            textColor: .primary
        )
        let blockQuote = MarkdownRenderConfig.MarkdownTextStyle(
            textFonts: body,
            textColor: .secondary
        )
        let heading = MarkdownRenderConfig.MarkdownHeadingTextStyle(
            h1Font: textFonts(size: 18, weight: .semibold),
            h2Font: textFonts(size: 16, weight: .semibold),
            h3Font: textFonts(size: 15, weight: .semibold),
            h4Font: textFonts(size: 14, weight: .semibold),
            h5Font: textFonts(size: 14, weight: .semibold),
            h6Font: textFonts(size: 14, weight: .semibold),
            textColor: .primary
        )

        return MarkdownRenderConfig.default
            .withShouldAnimateText(value: false)
            .withBlockQuoteStyle(value: blockQuote)
            .withHeadingStyle(value: heading)
            .withOrderedListStyle(value: paragraph)
            .withParagraphStyle(value: paragraph)
            .withBlockSpacing(value: 12)
    }

    private static func textFonts(
        size: CGFloat,
        weight: MDFont.Weight = .regular,
        boldWeight: MDFont.Weight = .semibold
    ) -> TextFonts {
        let normal = MDFont.systemFont(ofSize: size, weight: weight)
        let bold = MDFont.systemFont(ofSize: size, weight: boldWeight)
        return TextFonts(
            normal: normal,
            italic: italicFont(from: normal),
            bold: bold,
            boldItalic: italicFont(from: bold),
            preferredLetterSpacing: nil,
            preferredLineHeight: nil
        )
    }

    private static func italicFont(from font: MDFont) -> MDFont? {
        let descriptor = font.fontDescriptor.withSymbolicTraits(.italic)
        return MDFont(descriptor: descriptor, size: font.pointSize)
    }
}

struct ReadPaperMarkdownView: View {
    let markdown: String

    var body: some View {
        MarkdownView(text: markdown, config: ReadPaperMarkdownStyle.config)
    }
}
