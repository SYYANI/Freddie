import AppKit
import CoreText

extension NSAttributedString.Key {
    /// Syntax characters hidden while their line is not being edited.
    static let writingMarker = NSAttributedString.Key("ReadPaperWritingMarker")
    /// An unordered list marker, drawn as a bullet while its line is not being edited.
    static let writingBullet = NSAttributedString.Key("ReadPaperWritingBullet")
    /// The destination (String) of a link label; clicking the label opens it.
    static let writingLink = NSAttributedString.Key("ReadPaperWritingLink")
    /// The title (String) of a link label; for a citation, the start of the quote.
    static let writingLinkTitle = NSAttributedString.Key("ReadPaperWritingLinkTitle")
    /// A citation label, drawn on a tinted capsule.
    static let writingCitation = NSAttributedString.Key("ReadPaperWritingCitation")
    static let writingInlineCode = NSAttributedString.Key("ReadPaperWritingInlineCode")
    /// The block quote depth (Int) of the line.
    static let writingQuoteDepth = NSAttributedString.Key("ReadPaperWritingQuoteDepth")
    /// A line in a fenced code block, fences included.
    static let writingCodeBlock = NSAttributedString.Key("ReadPaperWritingCodeBlock")
    static let writingRule = NSAttributedString.Key("ReadPaperWritingRule")
    /// The code fence open where the line starts, so restyling after an edit can stop
    /// at the first line that already has the right state.
    static let writingLineState = NSAttributedString.Key("ReadPaperWritingLineState")
}

/// Fonts and colors of the writing editor, following the reader's paper appearance.
struct WritingTypography: Equatable {
    static let quoteIndent: CGFloat = 16
    static let codeInset: CGFloat = 10

    var usesPaperAppearance: Bool
    var bodySize: CGFloat = 14

    var bodyFont: NSFont {
        font(size: bodySize, weight: .regular)
    }

    var codeFont: NSFont {
        .monospacedSystemFont(ofSize: (bodySize * 0.88).rounded(), weight: .regular)
    }

    func headingFont(level: Int) -> NSFont {
        let scale: CGFloat
        switch level {
        case 1: scale = 1.5
        case 2: scale = 1.3
        case 3: scale = 1.15
        default: scale = 1.05
        }
        return font(size: (bodySize * scale).rounded(), weight: .semibold)
    }

    func font(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        guard usesPaperAppearance,
              let descriptor = font.fontDescriptor.withDesign(.serif),
              let serif = NSFont(descriptor: descriptor, size: size) else {
            return font
        }
        return serif
    }

    func font(_ font: NSFont, bold: Bool, italic: Bool) -> NSFont {
        var traits = font.fontDescriptor.symbolicTraits
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        return NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits), size: font.pointSize) ?? font
    }

    var textColor: NSColor { .labelColor }
    var quoteTextColor: NSColor { .secondaryLabelColor }
    var markerColor: NSColor { .tertiaryLabelColor }
    var listMarkerColor: NSColor { .secondaryLabelColor }
    var linkColor: NSColor { .linkColor }
    var citationColor: NSColor { .controlAccentColor }
    var citationBackgroundColor: NSColor { NSColor.controlAccentColor.withAlphaComponent(0.12) }

    var decorationColor: NSColor {
        usesPaperAppearance
            ? NSColor(red: 0.42, green: 0.34, blue: 0.22, alpha: 0.24)
            : NSColor.black.withAlphaComponent(0.16)
    }

    var codeBackgroundColor: NSColor {
        usesPaperAppearance
            ? NSColor(red: 0.42, green: 0.34, blue: 0.22, alpha: 0.07)
            : NSColor.black.withAlphaComponent(0.045)
    }

    func paragraphStyle(indent: CGFloat = 0, hangingIndent: CGFloat = 0, spacingBefore: CGFloat = 0, isCode: Bool = false) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = isCode ? 1.12 : 1.22
        style.firstLineHeadIndent = indent
        style.headIndent = indent + hangingIndent
        style.paragraphSpacingBefore = spacingBefore
        if isCode {
            style.tailIndent = -Self.codeInset
        }
        return style
    }
}

/// Text storage of a writing: plain Markdown whose attributes are recomputed for the
/// lines around every edit, so the editor shows the formatted result as you type.
final class WritingTextStorage: NSTextStorage {
    private static let managedKeys: [NSAttributedString.Key] = [
        .font, .foregroundColor, .paragraphStyle, .strikethroughStyle, .cursor, .toolTip,
        .writingMarker, .writingBullet, .writingLink, .writingLinkTitle, .writingCitation, .writingInlineCode,
        .writingQuoteDepth, .writingCodeBlock, .writingRule, .writingLineState,
    ]

    private let backing: NSMutableAttributedString
    private let processing = ProcessingDelegate()

    var typography: WritingTypography {
        didSet {
            guard typography != oldValue, backing.length > 0 else { return }
            beginEditing()
            let styled = applyStyles(from: 0, through: backing.length, stopsEarly: false)
            edited(.editedAttributes, range: styled, changeInLength: 0)
            endEditing()
        }
    }

    /// Called after characters change, with the edited range and the change in length.
    var onCharactersEdited: ((NSRange, Int) -> Void)?

    init(markdown: String, typography: WritingTypography) {
        backing = NSMutableAttributedString(string: markdown)
        self.typography = typography
        super.init()
        processing.storage = self
        delegate = processing
        applyStyles(from: 0, through: backing.length, stopsEarly: false)
        // Edits get fallback fonts (e.g. for CJK text) when the storage processes them; the
        // initial text is never processed, so it needs them here or it would not show.
        backing.fixAttributes(in: NSRange(location: 0, length: backing.length))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @available(*, unavailable)
    required init?(pasteboardPropertyList propertyList: Any, ofType type: NSPasteboard.PasteboardType) {
        fatalError("init(pasteboardPropertyList:ofType:) is not supported")
    }

    override var string: String {
        backing.string
    }

    override func attributes(at location: Int, effectiveRange range: NSRangePointer?) -> [NSAttributedString.Key: Any] {
        backing.attributes(at: location, effectiveRange: range)
    }

    override func replaceCharacters(in range: NSRange, with str: String) {
        beginEditing()
        backing.replaceCharacters(in: range, with: str)
        edited(.editedCharacters, range: range, changeInLength: (str as NSString).length - range.length)
        endEditing()
    }

    override func setAttributes(_ attrs: [NSAttributedString.Key: Any]?, range: NSRange) {
        beginEditing()
        backing.setAttributes(attrs, range: range)
        edited(.editedAttributes, range: range, changeInLength: 0)
        endEditing()
    }

    /// Attributes for typing at `location`: those of the text before the caret on its
    /// line, or the body style on an empty line, so the caret is not as tall as the
    /// heading above it.
    func typingAttributes(at location: Int) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: typography.bodyFont,
            .foregroundColor: typography.textColor,
            .paragraphStyle: typography.paragraphStyle(),
        ]
        let text = backing.mutableString
        let clamped = min(max(0, location), text.length)
        let lineRange = text.lineRange(for: NSRange(location: clamped, length: 0))
        let contentEnd = lineRange.location + contentLength(of: lineRange, in: text)
        guard contentEnd > lineRange.location else { return attributes }
        let sample = min(max(clamped - 1, lineRange.location), contentEnd - 1)
        let existing = backing.attributes(at: sample, effectiveRange: nil)
        if let font = existing[.font] {
            attributes[.font] = font
        }
        if let paragraphStyle = existing[.paragraphStyle] {
            attributes[.paragraphStyle] = paragraphStyle
        }
        return attributes
    }

    fileprivate func restyleAfterEditing(_ editedRange: NSRange) {
        let styled = applyStyles(from: editedRange.location, through: NSMaxRange(editedRange), stopsEarly: true)
        if styled.length > 0 {
            edited(.editedAttributes, range: styled, changeInLength: 0)
        }
    }

    fileprivate func charactersDidChange(_ editedRange: NSRange, changeInLength delta: Int) {
        onCharactersEdited?(editedRange, delta)
    }

    // MARK: - Styling

    /// Styles whole lines from the one containing `start` through the one containing
    /// `end`. With `stopsEarly`, styling then continues only while the following lines
    /// had a different code fence state, e.g. after typing an opening fence.
    @discardableResult
    private func applyStyles(from start: Int, through end: Int, stopsEarly: Bool) -> NSRange {
        let text = backing.mutableString
        let length = text.length
        guard length > 0 else { return NSRange(location: 0, length: 0) }

        let firstLineStart = text.lineRange(for: NSRange(location: min(start, length), length: 0)).location
        let editEnd = min(max(end, start), length)
        var lineStart = firstLineStart
        var fence = fenceState(atLineStart: lineStart, in: text)
        var styledEnd = lineStart

        while lineStart < length {
            let lineRange = text.lineRange(for: NSRange(location: lineStart, length: 0))
            let contentRange = NSRange(location: lineRange.location, length: contentLength(of: lineRange, in: text))
            let lineText = text.substring(with: contentRange)
            let (line, nextFence) = MarkdownLiveSyntax.parse(lineText, fence: fence)
            style(line, text: lineText, lineRange: lineRange, contentStart: contentRange.location, fenceAtStart: fence)
            fence = nextFence
            styledEnd = NSMaxRange(lineRange)
            lineStart = styledEnd

            if lineStart > editEnd || (lineStart == editEnd && lineStart > firstLineStart) {
                guard stopsEarly else { continue }
                if lineStart >= length || storedState(at: lineStart) == Self.encode(fence) {
                    break
                }
            }
        }
        return NSRange(location: firstLineStart, length: styledEnd - firstLineStart)
    }

    private func style(
        _ line: MarkdownLiveSyntax.Line,
        text: String,
        lineRange: NSRange,
        contentStart: Int,
        fenceAtStart: MarkdownLiveSyntax.FenceState?
    ) {
        for key in Self.managedKeys {
            backing.removeAttribute(key, range: lineRange)
        }

        let typography = typography
        var font = typography.bodyFont
        var color = typography.textColor
        var paragraphStyle = typography.paragraphStyle()
        var attributes: [NSAttributedString.Key: Any] = [
            .writingLineState: Self.encode(fenceAtStart),
        ]

        let quoteIndent = CGFloat(line.quoteDepth) * WritingTypography.quoteIndent
        if line.isCode || line.isFence {
            font = typography.codeFont
            color = line.isFence ? typography.markerColor : typography.textColor
            paragraphStyle = typography.paragraphStyle(indent: WritingTypography.codeInset, isCode: true)
            attributes[.writingCodeBlock] = true
        } else if let level = line.headingLevel {
            font = typography.headingFont(level: level)
            paragraphStyle = typography.paragraphStyle(indent: quoteIndent, spacingBefore: level <= 2 ? 8 : 4)
        } else if let list = line.list {
            // Wrapped lines align with the item's text: the nesting indentation, marker and
            // spaces after it, without the quote markers that are hidden.
            let quotePrefixEnd = line.quoteDepth > 0 ? NSMaxRange(line.markers[line.quoteDepth - 1]) : 0
            let markerText = (text as NSString).substring(with: NSRange(
                location: quotePrefixEnd,
                length: NSMaxRange(list.range) - quotePrefixEnd
            )) as NSString
            let markerWidth = markerText.size(withAttributes: [.font: font]).width
            paragraphStyle = typography.paragraphStyle(indent: quoteIndent, hangingIndent: markerWidth)
        } else {
            paragraphStyle = typography.paragraphStyle(indent: quoteIndent)
        }
        if line.quoteDepth > 0 {
            attributes[.writingQuoteDepth] = line.quoteDepth
            if line.isCode == false, line.isFence == false {
                color = typography.quoteTextColor
            }
        }
        if line.isRule {
            attributes[.writingRule] = true
            color = typography.markerColor
        }
        attributes[.font] = font
        attributes[.foregroundColor] = color
        attributes[.paragraphStyle] = paragraphStyle
        backing.addAttributes(attributes, range: lineRange)

        func absolute(_ range: NSRange) -> NSRange {
            NSRange(location: contentStart + range.location, length: range.length)
        }

        for span in line.spans {
            let range = absolute(span.range)
            guard range.length > 0 else { continue }
            switch span.kind {
            case .strong, .emphasis:
                let isStrong = span.kind == .strong
                backing.enumerateAttribute(.font, in: range) { value, subrange, _ in
                    let base = (value as? NSFont) ?? font
                    backing.addAttribute(
                        .font,
                        value: typography.font(base, bold: isStrong, italic: isStrong == false),
                        range: subrange
                    )
                }
            case .strikethrough:
                backing.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            case .code:
                backing.addAttributes([
                    .font: NSFont.monospacedSystemFont(ofSize: (font.pointSize * 0.9).rounded(), weight: .regular),
                    .writingInlineCode: true,
                ], range: range)
            case let .link(destination, title):
                var link: [NSAttributedString.Key: Any] = [
                    .foregroundColor: typography.linkColor,
                    .writingLink: destination,
                    .cursor: NSCursor.pointingHand,
                ]
                if let title {
                    link[.writingLinkTitle] = title
                    link[.toolTip] = title
                }
                backing.addAttributes(link, range: range)
            case let .citation(destination, title):
                var citation: [NSAttributedString.Key: Any] = [
                    .foregroundColor: typography.citationColor,
                    .writingLink: destination,
                    .writingCitation: true,
                    .cursor: NSCursor.pointingHand,
                ]
                if let title {
                    citation[.writingLinkTitle] = title
                    citation[.toolTip] = title
                }
                backing.addAttributes(citation, range: range)
            }
        }

        if let list = line.list {
            backing.addAttribute(.foregroundColor, value: typography.listMarkerColor, range: absolute(list.range))
            if let bullet = list.bulletLocation {
                backing.addAttribute(.writingBullet, value: true, range: absolute(NSRange(location: bullet, length: 1)))
            }
        }
        for marker in line.markers where marker.length > 0 {
            backing.addAttributes([
                .writingMarker: true,
                .foregroundColor: typography.markerColor,
            ], range: absolute(marker))
        }
        for destination in line.destinations where destination.length > 0 {
            backing.addAttribute(
                .font,
                value: NSFont.systemFont(ofSize: (font.pointSize * 0.8).rounded()),
                range: absolute(destination)
            )
        }
    }

    // MARK: - Line state

    private func fenceState(atLineStart location: Int, in text: NSString) -> MarkdownLiveSyntax.FenceState? {
        guard location > 0 else { return nil }
        let previousLine = text.lineRange(for: NSRange(location: location - 1, length: 0))
        guard let stored = storedState(at: previousLine.location) else {
            return recomputedFenceState(before: location, in: text)
        }
        let previousText = text.substring(with: NSRange(
            location: previousLine.location,
            length: contentLength(of: previousLine, in: text)
        ))
        return MarkdownLiveSyntax.parse(previousText, fence: Self.decode(stored)).fence
    }

    private func recomputedFenceState(before location: Int, in text: NSString) -> MarkdownLiveSyntax.FenceState? {
        var fence: MarkdownLiveSyntax.FenceState?
        var lineStart = 0
        while lineStart < location {
            let lineRange = text.lineRange(for: NSRange(location: lineStart, length: 0))
            let lineText = text.substring(with: NSRange(location: lineRange.location, length: contentLength(of: lineRange, in: text)))
            fence = MarkdownLiveSyntax.parse(lineText, fence: fence).fence
            lineStart = NSMaxRange(lineRange)
        }
        return fence
    }

    private func storedState(at location: Int) -> Int? {
        guard location < backing.length else { return nil }
        return backing.attribute(.writingLineState, at: location, effectiveRange: nil) as? Int
    }

    private func contentLength(of lineRange: NSRange, in text: NSString) -> Int {
        var end = NSMaxRange(lineRange)
        while end > lineRange.location {
            let character = text.character(at: end - 1)
            guard character == 0x0A || character == 0x0D || character == 0x2028 || character == 0x2029 else { break }
            end -= 1
        }
        return end - lineRange.location
    }

    private static func encode(_ fence: MarkdownLiveSyntax.FenceState?) -> Int {
        guard let fence else { return 0 }
        return Int(fence.character) << 16 | fence.length
    }

    private static func decode(_ state: Int) -> MarkdownLiveSyntax.FenceState? {
        guard state != 0 else { return nil }
        return MarkdownLiveSyntax.FenceState(character: UInt16(state >> 16), length: state & 0xFFFF)
    }

    /// Restyling happens while the text storage processes an edit, the documented place
    /// for a delegate to change attributes, so the layout managers see a single change.
    private final class ProcessingDelegate: NSObject, NSTextStorageDelegate {
        weak var storage: WritingTextStorage?

        func textStorage(
            _ textStorage: NSTextStorage,
            willProcessEditing editedMask: NSTextStorageEditActions,
            range editedRange: NSRange,
            changeInLength delta: Int
        ) {
            guard editedMask.contains(.editedCharacters), textStorage === storage else { return }
            storage?.restyleAfterEditing(editedRange)
        }

        func textStorage(
            _ textStorage: NSTextStorage,
            didProcessEditing editedMask: NSTextStorageEditActions,
            range editedRange: NSRange,
            changeInLength delta: Int
        ) {
            guard editedMask.contains(.editedCharacters), textStorage === storage else { return }
            storage?.charactersDidChange(editedRange, changeInLength: delta)
        }
    }
}

/// Draws block quote bars, code block backgrounds, rules and the capsules behind
/// inline code and citations.
final class WritingLayoutManager: NSLayoutManager {
    var typography: WritingTypography
    /// Lines being edited, whose Markdown syntax is shown instead of hidden.
    var revealedRange: NSRange?
    private let glyphHider = WritingGlyphHider()

    init(typography: WritingTypography) {
        self.typography = typography
        super.init()
        delegate = glyphHider
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func isRevealed(_ characterIndex: Int) -> Bool {
        guard let revealedRange else { return false }
        return NSLocationInRange(characterIndex, revealedRange)
            || (revealedRange.length == 0 && characterIndex == revealedRange.location)
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard glyphsToShow.length > 0,
              let storage = textStorage,
              storage.length > 0,
              let container = textContainers.first else {
            return
        }
        drawBlockDecorations(glyphsToShow, storage: storage, container: container, origin: origin)
        drawCapsules(glyphsToShow, storage: storage, container: container, origin: origin)
    }

    private func drawBlockDecorations(
        _ glyphsToShow: NSRange,
        storage: NSTextStorage,
        container: NSTextContainer,
        origin: NSPoint
    ) {
        let text = storage.string as NSString
        let left = origin.x + container.lineFragmentPadding
        let right = origin.x + container.size.width - container.lineFragmentPadding

        enumerateLineFragments(forGlyphRange: glyphsToShow) { rect, _, _, glyphRange, _ in
            let characterIndex = self.characterIndexForGlyph(at: glyphRange.location)
            guard characterIndex < storage.length else { return }
            let attributes = storage.attributes(at: characterIndex, effectiveRange: nil)
            let fragment = rect.offsetBy(dx: origin.x, dy: origin.y)

            if attributes[.writingCodeBlock] != nil {
                let lineRange = text.lineRange(for: NSRange(location: characterIndex, length: 0))
                let continuesAbove = lineRange.location > 0
                    && storage.attribute(.writingCodeBlock, at: lineRange.location - 1, effectiveRange: nil) != nil
                let continuesBelow = NSMaxRange(lineRange) < storage.length
                    && storage.attribute(.writingCodeBlock, at: NSMaxRange(lineRange), effectiveRange: nil) != nil
                let block = NSRect(x: left, y: fragment.minY, width: right - left, height: fragment.height)
                let radius: CGFloat = 5
                var shape = block
                if continuesAbove {
                    shape.origin.y -= radius
                    shape.size.height += radius
                }
                if continuesBelow {
                    shape.size.height += radius
                }
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: block).addClip()
                self.typography.codeBackgroundColor.setFill()
                NSBezierPath(roundedRect: shape, xRadius: radius, yRadius: radius).fill()
                NSGraphicsContext.restoreGraphicsState()
            }

            if let depth = attributes[.writingQuoteDepth] as? Int, depth > 0 {
                self.typography.decorationColor.setFill()
                for level in 0..<depth {
                    let x = left + CGFloat(level) * WritingTypography.quoteIndent + 1
                    NSRect(x: x, y: fragment.minY, width: 3, height: fragment.height).fill()
                }
            }

            if attributes[.writingRule] != nil, self.isRevealed(characterIndex) == false {
                self.typography.decorationColor.setFill()
                NSRect(x: left, y: (fragment.midY - 0.5).rounded(), width: right - left, height: 1).fill()
            }
        }
    }

    private func drawCapsules(
        _ glyphsToShow: NSRange,
        storage: NSTextStorage,
        container: NSTextContainer,
        origin: NSPoint
    ) {
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        storage.enumerateAttributes(in: characters) { attributes, range, _ in
            let color: NSColor
            if attributes[.writingCitation] != nil {
                color = typography.citationBackgroundColor
            } else if attributes[.writingInlineCode] != nil {
                color = typography.codeBackgroundColor.withAlphaComponent(typography.usesPaperAppearance ? 0.12 : 0.07)
            } else {
                return
            }
            let font = (attributes[.font] as? NSFont) ?? typography.bodyFont
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var glyphIndex = glyphs.location
            color.setFill()
            while glyphIndex < NSMaxRange(glyphs) {
                var fragmentGlyphs = NSRange(location: 0, length: 0)
                let fragment = lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &fragmentGlyphs)
                let part = NSIntersectionRange(glyphs, fragmentGlyphs)
                guard part.length > 0 else { break }
                let bounds = boundingRect(forGlyphRange: part, in: container)
                let baseline = fragment.minY + location(forGlyphAt: part.location).y
                let capsule = NSRect(
                    x: bounds.minX - 3,
                    y: baseline - font.ascender - 1.5,
                    width: bounds.width + 6,
                    height: font.ascender - font.descender + 3
                ).offsetBy(dx: origin.x, dy: origin.y)
                NSBezierPath(roundedRect: capsule, xRadius: 4, yRadius: 4).fill()
                glyphIndex = NSMaxRange(part)
            }
        }
    }
}

/// Hides Markdown syntax outside the lines being edited by turning its glyphs into
/// null glyphs, and draws "-", "*" and "+" list markers as bullets.
private final class WritingGlyphHider: NSObject, NSLayoutManagerDelegate {
    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
        properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
        characterIndexes charIndexes: UnsafePointer<Int>,
        font aFont: NSFont,
        forGlyphRange glyphRange: NSRange
    ) -> Int {
        guard glyphRange.length > 0,
              let layoutManager = layoutManager as? WritingLayoutManager,
              let storage = layoutManager.textStorage else {
            return 0
        }
        let count = glyphRange.length
        let first = charIndexes[0]
        let last = charIndexes[count - 1]
        guard first <= last, last < storage.length else { return 0 }

        var hidden: [NSRange] = []
        var bullets: [NSRange] = []
        storage.enumerateAttributes(in: NSRange(location: first, length: last - first + 1)) { attributes, range, _ in
            if attributes[.writingMarker] != nil {
                hidden.append(range)
            } else if attributes[.writingBullet] != nil {
                bullets.append(range)
            }
        }
        guard hidden.isEmpty == false || bullets.isEmpty == false else { return 0 }

        var properties = Array(UnsafeBufferPointer(start: props, count: count))
        var newGlyphs = Array(UnsafeBufferPointer(start: glyphs, count: count))
        let bulletGlyph = bullets.isEmpty ? nil : Self.bulletGlyph(in: aFont)
        var changed = false
        for index in 0..<count {
            let characterIndex = charIndexes[index]
            guard layoutManager.isRevealed(characterIndex) == false else { continue }
            if hidden.contains(where: { NSLocationInRange(characterIndex, $0) }) {
                properties[index] = .null
                changed = true
            } else if let bulletGlyph, bullets.contains(where: { NSLocationInRange(characterIndex, $0) }) {
                newGlyphs[index] = bulletGlyph
                changed = true
            }
        }
        guard changed else { return 0 }
        layoutManager.setGlyphs(newGlyphs, properties: properties, characterIndexes: charIndexes, font: aFont, forGlyphRange: glyphRange)
        return count
    }

    private static func bulletGlyph(in font: NSFont) -> CGGlyph? {
        var character: UniChar = 0x2022
        var glyph: CGGlyph = 0
        guard CTFontGetGlyphsForCharacters(font as CTFont, &character, &glyph, 1), glyph != 0 else { return nil }
        return glyph
    }
}
