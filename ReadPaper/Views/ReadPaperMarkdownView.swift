import AppKit
import SwiftUI
import SwiftStreamingMarkdown

enum ReadPaperMarkdownStyle {
    static let config: MarkdownRenderConfig = makeConfig(design: .default)

    static func config(for displayAppearance: PDFDisplayAppearance) -> MarkdownRenderConfig {
        displayAppearance == .paper ? makeConfig(design: .serif) : config
    }

    private static func makeConfig(design: Font.Design) -> MarkdownRenderConfig {
        let body = textFonts(size: 14, design: design)
        let paragraph = MarkdownRenderConfig.MarkdownTextStyle(
            textFonts: body,
            textColor: .primary
        )
        let blockQuote = MarkdownRenderConfig.MarkdownTextStyle(
            textFonts: body,
            textColor: .secondary
        )
        let heading = MarkdownRenderConfig.MarkdownHeadingTextStyle(
            h1Font: textFonts(size: 18, weight: .semibold, design: design),
            h2Font: textFonts(size: 16, weight: .semibold, design: design),
            h3Font: textFonts(size: 15, weight: .semibold, design: design),
            h4Font: textFonts(size: 14, weight: .semibold, design: design),
            h5Font: textFonts(size: 14, weight: .semibold, design: design),
            h6Font: textFonts(size: 14, weight: .semibold, design: design),
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
        boldWeight: MDFont.Weight = .semibold,
        design: Font.Design = .default
    ) -> TextFonts {
        let normal = makeFont(size: size, weight: weight, design: design)
        let bold = makeFont(size: size, weight: boldWeight, design: design)
        return TextFonts(
            normal: normal,
            italic: italicFont(from: normal),
            bold: bold,
            boldItalic: italicFont(from: bold),
            preferredLetterSpacing: nil,
            preferredLineHeight: nil
        )
    }

    private static func makeFont(
        size: CGFloat,
        weight: MDFont.Weight,
        design: Font.Design
    ) -> MDFont {
        guard design == .serif,
              let paperFont = MDFont(name: "New York", size: size) else {
            return MDFont.systemFont(ofSize: size, weight: weight)
        }

        guard weight != .regular else {
            return paperFont
        }
        let descriptor = paperFont.fontDescriptor.withSymbolicTraits(.bold)
        return MDFont(descriptor: descriptor, size: size) ?? paperFont
    }

    private static func italicFont(from font: MDFont) -> MDFont? {
        let descriptor = font.fontDescriptor.withSymbolicTraits(.italic)
        return MDFont(descriptor: descriptor, size: font.pointSize)
    }
}

struct ReadPaperMarkdownView: View {
    let markdown: String
    @Environment(\.pdfDisplayAppearance) private var displayAppearance

    var body: some View {
        MarkdownView(
            text: markdown,
            config: ReadPaperMarkdownStyle.config(for: displayAppearance)
        )
    }
}
