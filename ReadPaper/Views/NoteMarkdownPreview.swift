import AppKit
import Foundation
import SwiftUI

enum NoteMarkdownRenderer {
    fileprivate enum Block {
        case heading(level: Int, text: String)
        case paragraph(String)
        case list([String])
        case quote([String])
        case code(String)
    }

    private static let inlineMarkdownOptions = AttributedString.MarkdownParsingOptions(
        interpretedSyntax: .inlineOnlyPreservingWhitespace,
        failurePolicy: .returnPartiallyParsedIfPossible
    )

    static func render(_ markdown: String) -> NSAttributedString {
        let blocks = blocks(for: markdown)
        let rendered = NSMutableAttributedString()

        for (index, block) in blocks.enumerated() {
            if index > 0 {
                rendered.append(NSAttributedString(string: "\n\n"))
            }
            rendered.append(render(block))
        }

        return rendered
    }

    fileprivate static func blocks(for markdown: String) -> [Block] {
        let normalized = normalize(markdown)
        return parseBlocks(from: normalized)
    }

    private static func normalize(_ markdown: String) -> String {
        markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private static func parseBlocks(from markdown: String) -> [Block] {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var blocks: [Block] = []
        var paragraphLines: [String] = []
        var listItems: [String] = []
        var quoteLines: [String] = []
        var codeLines: [String] = []
        var isInCodeBlock = false

        func flushParagraph() {
            guard paragraphLines.isEmpty == false else { return }
            blocks.append(.paragraph(paragraphLines.joined(separator: " ")))
            paragraphLines.removeAll(keepingCapacity: true)
        }

        func flushList() {
            guard listItems.isEmpty == false else { return }
            blocks.append(.list(listItems))
            listItems.removeAll(keepingCapacity: true)
        }

        func flushQuote() {
            guard quoteLines.isEmpty == false else { return }
            blocks.append(.quote(quoteLines))
            quoteLines.removeAll(keepingCapacity: true)
        }

        func flushOpenBlockContent() {
            flushParagraph()
            flushList()
            flushQuote()
        }

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if isInCodeBlock {
                if isFence(line) {
                    blocks.append(.code(codeLines.joined(separator: "\n")))
                    codeLines.removeAll(keepingCapacity: true)
                    isInCodeBlock = false
                } else {
                    codeLines.append(rawLine)
                }
                continue
            }

            if isFence(line) {
                flushOpenBlockContent()
                isInCodeBlock = true
                continue
            }

            if line.isEmpty {
                flushOpenBlockContent()
                continue
            }

            if let heading = heading(from: line) {
                flushOpenBlockContent()
                blocks.append(.heading(level: heading.level, text: heading.text))
                continue
            }

            if let listItem = listItem(from: line) {
                flushParagraph()
                flushQuote()
                listItems.append(listItem)
                continue
            }

            flushList()

            if let quoteLine = quoteLine(from: line) {
                flushParagraph()
                quoteLines.append(quoteLine)
                continue
            }

            flushQuote()
            paragraphLines.append(line)
        }

        if isInCodeBlock {
            blocks.append(.code(codeLines.joined(separator: "\n")))
        }

        flushOpenBlockContent()
        return blocks
    }

    private static func render(_ block: Block) -> NSAttributedString {
        switch block {
        case let .heading(level, text):
            let rendered = NSMutableAttributedString(attributedString: renderInline(text))
            let font = NSFont.systemFont(ofSize: headingFontSize(for: level), weight: .semibold)
            rendered.addAttribute(.font, value: font, range: NSRange(location: 0, length: rendered.length))
            return rendered

        case let .paragraph(text):
            return renderInline(text)

        case let .list(items):
            let rendered = NSMutableAttributedString()

            for (index, item) in items.enumerated() {
                if index > 0 {
                    rendered.append(NSAttributedString(string: "\n"))
                }
                rendered.append(
                    NSAttributedString(
                        string: "• ",
                        attributes: [.font: NSFont.preferredFont(forTextStyle: .body)]
                    )
                )
                rendered.append(renderInline(item))
            }

            return rendered

        case let .quote(lines):
            let rendered = NSMutableAttributedString()

            for (index, line) in lines.enumerated() {
                if index > 0 {
                    rendered.append(NSAttributedString(string: "\n"))
                }
                rendered.append(
                    NSAttributedString(
                        string: "> ",
                        attributes: [
                            .font: NSFont.preferredFont(forTextStyle: .body),
                            .foregroundColor: NSColor.secondaryLabelColor
                        ]
                    )
                )
                rendered.append(renderInline(line))
            }

            return rendered

        case let .code(text):
            return NSAttributedString(
                string: text,
                attributes: [
                    .font: NSFont.monospacedSystemFont(
                        ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize,
                        weight: .regular
                    ),
                    .backgroundColor: NSColor.controlBackgroundColor
                ]
            )
        }
    }

    private static func renderInline(_ text: String) -> NSAttributedString {
        guard text.isEmpty == false else {
            return NSAttributedString(string: "")
        }

        do {
            let rendered = NSMutableAttributedString(attributedString: try NSAttributedString(
                markdown: text,
                options: inlineMarkdownOptions,
                baseURL: nil
            ))
            applyInlinePresentationIntents(to: rendered)
            return rendered
        } catch {
            return NSAttributedString(string: text)
        }
    }

    fileprivate static func inlineAttributedString(_ text: String) -> AttributedString? {
        guard text.isEmpty == false else {
            return AttributedString("")
        }

        return try? AttributedString(markdown: text, options: inlineMarkdownOptions)
    }

    private static func applyInlinePresentationIntents(to rendered: NSMutableAttributedString) {
        let fullRange = NSRange(location: 0, length: rendered.length)
        guard fullRange.length > 0 else { return }

        let baseFont = NSFont.preferredFont(forTextStyle: .body)
        let fontManager = NSFontManager.shared
        rendered.addAttribute(.font, value: baseFont, range: fullRange)

        rendered.enumerateAttribute(.inlinePresentationIntent, in: fullRange) { value, range, _ in
            let intent: InlinePresentationIntent
            if let intentValue = value as? InlinePresentationIntent {
                intent = intentValue
            } else if let rawValue = value as? NSNumber {
                intent = InlinePresentationIntent(rawValue: rawValue.uintValue)
            } else {
                return
            }

            if intent.contains(.code) {
                rendered.addAttributes(
                    [
                        .font: NSFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .regular),
                        .backgroundColor: NSColor.controlBackgroundColor
                    ],
                    range: range
                )
                return
            }

            var traits = NSFontDescriptor.SymbolicTraits()
            if intent.contains(.stronglyEmphasized) {
                traits.insert(.bold)
            }
            if intent.contains(.emphasized) {
                traits.insert(.italic)
            }

            guard traits.isEmpty == false else { return }

            var font = baseFont
            if traits.contains(.bold) {
                font = fontManager.convert(font, toHaveTrait: .boldFontMask)
            }
            if traits.contains(.italic) {
                font = fontManager.convert(font, toHaveTrait: .italicFontMask)
            }

            rendered.addAttribute(.font, value: font, range: range)
        }
    }

    private static func heading(from line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix { $0 == "#" }
        let level = hashes.count
        guard (1...6).contains(level) else { return nil }

        let remainder = line.dropFirst(level)
        guard remainder.first?.isWhitespace == true else { return nil }

        let text = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty == false else { return nil }
        return (level, text)
    }

    private static func listItem(from line: String) -> String? {
        guard line.count >= 2 else { return nil }
        guard let marker = line.first, marker == "-" || marker == "*" else { return nil }
        guard line.dropFirst().first?.isWhitespace == true else { return nil }

        let text = line.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func quoteLine(from line: String) -> String? {
        guard line.first == ">" else { return nil }
        return line.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isFence(_ line: String) -> Bool {
        line.hasPrefix("```")
    }

    private static func headingFontSize(for level: Int) -> CGFloat {
        switch level {
        case 1:
            return 20
        case 2:
            return 18
        case 3:
            return 16
        default:
            return 14
        }
    }
}

struct NoteMarkdownPreviewView: View {
    let markdown: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(NoteMarkdownRenderer.blocks(for: markdown).enumerated()), id: \.offset) { _, block in
                    blockView(block)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: NoteMarkdownRenderer.Block) -> some View {
        switch block {
        case let .heading(level, text):
            inlineText(text)
                .font(headingFont(for: level))
                .fontWeight(.semibold)
                .fixedSize(horizontal: false, vertical: true)

        case let .paragraph(text):
            inlineText(text)
                .fixedSize(horizontal: false, vertical: true)

        case let .list(items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\u{2022}")
                            .font(.body.weight(.semibold))
                        inlineText(item)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case let .quote(lines):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 999, style: .continuous)
                    .fill(Color.secondary.opacity(0.28))
                    .frame(width: 4)

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        inlineText(line)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

        case let .code(text):
            ScrollView(.horizontal) {
                Text(verbatim: text)
                    .font(.system(.callout, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
        }
    }

    private func inlineText(_ text: String) -> Text {
        if let attributed = NoteMarkdownRenderer.inlineAttributedString(text) {
            return Text(attributed)
        }

        return Text(verbatim: text)
    }

    private func headingFont(for level: Int) -> Font {
        switch level {
        case 1:
            return .title3
        case 2:
            return .headline
        case 3:
            return .subheadline
        default:
            return .body
        }
    }
}
