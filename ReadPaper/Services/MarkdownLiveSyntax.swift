import Foundation

/// Recognizes Markdown one line at a time for the writing editor's live preview.
/// Offsets are UTF-16 code units within the line, like `NSString`. The supported
/// syntax follows CommonMark, plus `$…$` math as Pandoc reads it, so a writing looks
/// the same after export to other Markdown apps.
enum MarkdownLiveSyntax {
    struct FenceState: Equatable, Sendable {
        /// "`" or "~".
        var character: UInt16
        var length: Int
    }

    struct ListMarker: Equatable, Sendable {
        var isOrdered: Bool
        /// The marker and the spaces after it, e.g. "- " or "12. ".
        var range: NSRange
        /// The "-", "*" or "+" of an unordered item, drawn as a bullet.
        var bulletLocation: Int?
    }

    enum InlineKind: Equatable, Sendable {
        case strong
        case emphasis
        case strikethrough
        case code
        case link(destination: String, title: String?)
        case citation(destination: String, title: String?)
        /// `![alt](destination)`. The span covers the whole syntax, which the live preview
        /// replaces with the image.
        case image(destination: String, title: String?)
        /// TeX between `$` (or `$$` for display style); the span covers the TeX alone.
        case math(tex: String, isDisplay: Bool)
    }

    struct InlineSpan: Equatable, Sendable {
        var kind: InlineKind
        var range: NSRange
    }

    struct Line: Equatable, Sendable {
        var isBlank = false
        /// Inside a fenced code block.
        var isCode = false
        /// An opening or closing code fence.
        var isFence = false
        var isRule = false
        var quoteDepth = 0
        var headingLevel: Int?
        var list: ListMarker?
        var spans: [InlineSpan] = []
        /// Syntax characters shown only while the line is being edited.
        var markers: [NSRange] = []
        /// What is inside a link's parentheses: its destination and title. Part of
        /// `markers`, drawn smaller while shown.
        var destinations: [NSRange] = []
    }

    /// Recognizes `text` (one line, without its line break) given the code fence open
    /// before it, and returns the fence open after it.
    static func parse(_ text: String, fence: FenceState?) -> (line: Line, fence: FenceState?) {
        let units = Array(text.utf16)
        var line = Line()

        if let fence {
            if isClosingFence(units, for: fence) {
                line.isFence = true
                return (line, nil)
            }
            line.isCode = true
            return (line, fence)
        }
        if let opening = openingFence(units) {
            line.isFence = true
            return (line, opening)
        }
        if units.allSatisfy(isSpaceOrTab) {
            line.isBlank = true
            return (line, nil)
        }

        var index = 0
        while true {
            let markerStart = skipSpaces(units, from: index, limit: 3)
            guard markerStart < units.count, units[markerStart] == Unit.greaterThan else { break }
            var markerEnd = markerStart + 1
            if markerEnd < units.count, isSpaceOrTab(units[markerEnd]) {
                markerEnd += 1
            }
            line.markers.append(NSRange(location: index, length: markerEnd - index))
            line.quoteDepth += 1
            index = markerEnd
        }

        if isThematicBreak(units, from: index) {
            line.isRule = true
            line.markers.append(NSRange(location: index, length: units.count - index))
            return (line, nil)
        }

        if parseHeading(units, from: index, into: &line) {
            return (line, nil)
        }

        if parseListItem(units, from: index, into: &line) {
            return (line, nil)
        }

        parseInline(units, in: index..<units.count, into: &line)
        return (line, nil)
    }

    // MARK: - Blocks

    private static func parseHeading(_ units: [UInt16], from index: Int, into line: inout Line) -> Bool {
        let start = skipSpaces(units, from: index, limit: 3)
        var hashes = 0
        while start + hashes < units.count, units[start + hashes] == Unit.hash {
            hashes += 1
        }
        let afterHashes = start + hashes
        guard (1...6).contains(hashes),
              afterHashes == units.count || isSpaceOrTab(units[afterHashes]) else {
            return false
        }

        var contentStart = afterHashes
        while contentStart < units.count, isSpaceOrTab(units[contentStart]) {
            contentStart += 1
        }
        line.headingLevel = hashes
        line.markers.append(NSRange(location: index, length: contentStart - index))

        // An optional closing sequence: "## Title ##".
        var contentEnd = units.count
        while contentEnd > contentStart, isSpaceOrTab(units[contentEnd - 1]) {
            contentEnd -= 1
        }
        var closingStart = contentEnd
        while closingStart > contentStart, units[closingStart - 1] == Unit.hash {
            closingStart -= 1
        }
        if closingStart < contentEnd,
           closingStart == contentStart || isSpaceOrTab(units[closingStart - 1]) {
            var markerStart = closingStart
            while markerStart > contentStart, isSpaceOrTab(units[markerStart - 1]) {
                markerStart -= 1
            }
            line.markers.append(NSRange(location: markerStart, length: units.count - markerStart))
            contentEnd = markerStart
        }

        parseInline(units, in: contentStart..<contentEnd, into: &line)
        return true
    }

    private static func parseListItem(_ units: [UInt16], from index: Int, into line: inout Line) -> Bool {
        // Any indentation: nested items are indented, and indented code blocks are not supported.
        var markerStart = index
        while markerStart < units.count, isSpaceOrTab(units[markerStart]) {
            markerStart += 1
        }
        guard markerStart < units.count else { return false }

        let first = units[markerStart]
        var markerEnd: Int
        let isOrdered: Bool
        if first == Unit.dash || first == Unit.star || first == Unit.plus {
            markerEnd = markerStart + 1
            isOrdered = false
        } else if isDigit(first) {
            markerEnd = markerStart
            while markerEnd < units.count, isDigit(units[markerEnd]), markerEnd - markerStart < 9 {
                markerEnd += 1
            }
            guard markerEnd < units.count,
                  units[markerEnd] == Unit.period || units[markerEnd] == Unit.closingParenthesis else {
                return false
            }
            markerEnd += 1
            isOrdered = true
        } else {
            return false
        }
        guard markerEnd == units.count || isSpaceOrTab(units[markerEnd]) else { return false }

        var contentStart = markerEnd
        while contentStart < units.count, isSpaceOrTab(units[contentStart]) {
            contentStart += 1
        }
        line.list = ListMarker(
            isOrdered: isOrdered,
            range: NSRange(location: markerStart, length: contentStart - markerStart),
            bulletLocation: isOrdered ? nil : markerStart
        )
        parseInline(units, in: contentStart..<units.count, into: &line)
        return true
    }

    private static func isThematicBreak(_ units: [UInt16], from index: Int) -> Bool {
        var position = skipSpaces(units, from: index, limit: 3)
        guard position < units.count else { return false }
        let character = units[position]
        guard character == Unit.dash || character == Unit.star || character == Unit.underscore else {
            return false
        }
        var count = 0
        while position < units.count {
            let unit = units[position]
            if unit == character {
                count += 1
            } else if isSpaceOrTab(unit) == false {
                return false
            }
            position += 1
        }
        return count >= 3
    }

    private static func openingFence(_ units: [UInt16]) -> FenceState? {
        let start = skipSpaces(units, from: 0, limit: 3)
        guard start < units.count,
              units[start] == Unit.backtick || units[start] == Unit.tilde else {
            return nil
        }
        let character = units[start]
        var end = start
        while end < units.count, units[end] == character {
            end += 1
        }
        guard end - start >= 3 else { return nil }
        // A backtick fence's info string cannot contain backticks.
        if character == Unit.backtick, units[end...].contains(Unit.backtick) {
            return nil
        }
        return FenceState(character: character, length: end - start)
    }

    private static func isClosingFence(_ units: [UInt16], for fence: FenceState) -> Bool {
        let start = skipSpaces(units, from: 0, limit: 3)
        var end = start
        while end < units.count, units[end] == fence.character {
            end += 1
        }
        guard end - start >= fence.length else { return false }
        return units[end...].allSatisfy(isSpaceOrTab)
    }

    // MARK: - Inlines

    private struct InlineLink {
        var closingBracket: Int
        var destination: String
        var destinationRange: NSRange
        var title: String?
        /// The index after the closing parenthesis.
        var end: Int
    }

    private struct Delimiter {
        var character: UInt16
        var start: Int
        var length: Int
        var remaining: Int
        var canOpen: Bool
        var canClose: Bool
        var isActive = true
    }

    private static func parseInline(_ units: [UInt16], in range: Range<Int>, into line: inout Line) {
        guard range.isEmpty == false else { return }
        // Characters that cannot be syntax: escaped characters, code spans, math, link parts.
        var consumed = [Bool](repeating: false, count: units.count)

        var index = range.lowerBound
        while index < range.upperBound {
            let unit = units[index]
            if unit == Unit.backslash, index + 1 < range.upperBound, isASCIIPunctuation(units[index + 1]) {
                line.markers.append(NSRange(location: index, length: 1))
                consumed[index] = true
                consumed[index + 1] = true
                index += 2
                continue
            }
            if unit == Unit.dollar {
                var runEnd = index
                while runEnd < range.upperBound, units[runEnd] == Unit.dollar {
                    runEnd += 1
                }
                guard let math = mathSpan(units, opening: index, runLength: runEnd - index, end: range.upperBound) else {
                    // A run of dollars that opens nothing is text, e.g. a price.
                    index = runEnd
                    continue
                }
                let delimiterLength = math.isDisplay ? 2 : 1
                let contentRange = NSRange(location: index + delimiterLength, length: math.closingStart - index - delimiterLength)
                line.markers.append(NSRange(location: index, length: delimiterLength))
                line.markers.append(NSRange(location: math.closingStart, length: delimiterLength))
                line.spans.append(InlineSpan(
                    kind: .math(
                        tex: String(decoding: units[contentRange.location..<NSMaxRange(contentRange)], as: UTF16.self),
                        isDisplay: math.isDisplay
                    ),
                    range: contentRange
                ))
                for position in index..<(math.closingStart + delimiterLength) {
                    consumed[position] = true
                }
                index = math.closingStart + delimiterLength
                continue
            }
            if unit == Unit.backtick {
                var runEnd = index
                while runEnd < range.upperBound, units[runEnd] == Unit.backtick {
                    runEnd += 1
                }
                let runLength = runEnd - index
                if let closingStart = backtickRun(units, length: runLength, from: runEnd, end: range.upperBound) {
                    line.markers.append(NSRange(location: index, length: runLength))
                    line.markers.append(NSRange(location: closingStart, length: runLength))
                    line.spans.append(InlineSpan(
                        kind: .code,
                        range: NSRange(location: runEnd, length: closingStart - runEnd)
                    ))
                    for position in index..<(closingStart + runLength) {
                        consumed[position] = true
                    }
                    index = closingStart + runLength
                } else {
                    for position in index..<runEnd {
                        consumed[position] = true
                    }
                    index = runEnd
                }
                continue
            }
            index += 1
        }

        // Links split the line into separate runs for emphasis: emphasis cannot cross a link edge.
        var emphasisRuns: [Range<Int>] = []
        var runStart = range.lowerBound
        index = range.lowerBound
        while index < range.upperBound {
            guard consumed[index] == false else {
                index += 1
                continue
            }
            let unit = units[index]
            if unit == Unit.lessThan, let closing = autolinkEnd(units, from: index, end: range.upperBound) {
                let destination = String(decoding: units[(index + 1)..<closing], as: UTF16.self)
                line.markers.append(NSRange(location: index, length: 1))
                line.markers.append(NSRange(location: closing, length: 1))
                line.spans.append(InlineSpan(
                    kind: linkKind(destination, title: nil),
                    range: NSRange(location: index + 1, length: closing - index - 1)
                ))
                for position in index...closing {
                    consumed[position] = true
                }
                emphasisRuns.append(runStart..<index)
                index = closing + 1
                runStart = index
                continue
            }
            if unit == Unit.openingBracket,
               let link = inlineLink(units, openingBracket: index, end: range.upperBound, consumed: consumed) {
                let isImage = index > range.lowerBound && units[index - 1] == Unit.exclamation && consumed[index - 1] == false
                let openingStart = isImage ? index - 1 : index
                line.markers.append(NSRange(location: openingStart, length: index + 1 - openingStart))
                line.markers.append(NSRange(location: link.closingBracket, length: link.end - link.closingBracket))
                line.destinations.append(link.destinationRange)
                if isImage {
                    line.spans.append(InlineSpan(
                        kind: .image(destination: link.destination, title: link.title),
                        range: NSRange(location: openingStart, length: link.end - openingStart)
                    ))
                } else {
                    line.spans.append(InlineSpan(
                        kind: linkKind(link.destination, title: link.title),
                        range: NSRange(location: index + 1, length: link.closingBracket - index - 1)
                    ))
                }
                for position in openingStart...index {
                    consumed[position] = true
                }
                for position in link.closingBracket..<link.end {
                    consumed[position] = true
                }
                emphasisRuns.append(runStart..<openingStart)
                emphasisRuns.append((index + 1)..<link.closingBracket)
                index = link.end
                runStart = index
                continue
            }
            index += 1
        }
        emphasisRuns.append(runStart..<range.upperBound)

        for run in emphasisRuns where run.isEmpty == false {
            parseEmphasis(units, in: run, consumed: consumed, into: &line)
        }
        line.spans.sort { $0.range.location < $1.range.location }
    }

    private static func backtickRun(_ units: [UInt16], length: Int, from start: Int, end: Int) -> Int? {
        var index = start
        while index < end {
            guard units[index] == Unit.backtick else {
                index += 1
                continue
            }
            var runEnd = index
            while runEnd < end, units[runEnd] == Unit.backtick {
                runEnd += 1
            }
            if runEnd - index == length {
                return index
            }
            index = runEnd
        }
        return nil
    }

    /// Math as Pandoc and most Markdown apps read it: `$…$` opens with a non-space after the
    /// `$` and closes with a non-space before a `$` that no digit follows, so "$5 and $10"
    /// stays text; `$$…$$` is display style. Backslashes inside are TeX, so `\$` does not
    /// close. `runLength` is the number of dollars at `opening`.
    private static func mathSpan(
        _ units: [UInt16],
        opening: Int,
        runLength: Int,
        end: Int
    ) -> (closingStart: Int, isDisplay: Bool)? {
        let isDisplay: Bool
        switch runLength {
        case 1: isDisplay = false
        case 2: isDisplay = true
        default: return nil
        }
        let contentStart = opening + runLength
        guard contentStart < end else { return nil }
        if isDisplay == false, isSpaceOrTab(units[contentStart]) {
            return nil
        }

        var index = contentStart
        var hasContent = false
        while index < end {
            let unit = units[index]
            if unit == Unit.backslash {
                hasContent = true
                index += 2
                continue
            }
            if unit == Unit.dollar {
                if isDisplay {
                    if index + 1 < end, units[index + 1] == Unit.dollar, hasContent {
                        return (index, true)
                    }
                } else if index > contentStart,
                          isSpaceOrTab(units[index - 1]) == false,
                          index + 1 >= end || isDigit(units[index + 1]) == false {
                    return (index, false)
                }
                // A "$$" never closes inline math.
                if isDisplay == false, index + 1 < end, units[index + 1] == Unit.dollar {
                    return nil
                }
            } else if isSpaceOrTab(unit) == false {
                hasContent = true
            }
            index += 1
        }
        return nil
    }

    private static func autolinkEnd(_ units: [UInt16], from start: Int, end: Int) -> Int? {
        var index = start + 1
        guard index < end, isASCIILetter(units[index]) else { return nil }
        var schemeLength = 0
        while index < end {
            let unit = units[index]
            guard isASCIILetter(unit) || isDigit(unit) || unit == Unit.plus || unit == Unit.period || unit == Unit.dash else {
                break
            }
            schemeLength += 1
            index += 1
        }
        guard (2...32).contains(schemeLength), index < end, units[index] == Unit.colon else { return nil }
        index += 1
        while index < end {
            let unit = units[index]
            if unit == Unit.greaterThan {
                return index
            }
            if unit == Unit.lessThan || unit <= Unit.space {
                return nil
            }
            index += 1
        }
        return nil
    }

    private static func inlineLink(
        _ units: [UInt16],
        openingBracket: Int,
        end: Int,
        consumed: [Bool]
    ) -> InlineLink? {
        var depth = 0
        var closingBracket: Int?
        var index = openingBracket
        while index < end {
            if consumed[index] == false {
                if units[index] == Unit.openingBracket {
                    depth += 1
                } else if units[index] == Unit.closingBracket {
                    depth -= 1
                    if depth == 0 {
                        closingBracket = index
                        break
                    }
                }
            }
            index += 1
        }
        guard let closingBracket,
              closingBracket + 1 < end,
              units[closingBracket + 1] == Unit.openingParenthesis else {
            return nil
        }

        var position = closingBracket + 2
        while position < end, isSpaceOrTab(units[position]) {
            position += 1
        }
        let destinationStart: Int
        let destinationEnd: Int
        if position < end, units[position] == Unit.lessThan {
            var closing = position + 1
            while closing < end, units[closing] != Unit.greaterThan, units[closing] != Unit.lessThan {
                closing += 1
            }
            guard closing < end, units[closing] == Unit.greaterThan else { return nil }
            destinationStart = position + 1
            destinationEnd = closing
            position = closing + 1
        } else {
            var parentheses = 0
            var cursor = position
            while cursor < end {
                let unit = units[cursor]
                if isSpaceOrTab(unit) {
                    break
                }
                if unit == Unit.backslash, cursor + 1 < end {
                    cursor += 2
                    continue
                }
                if unit == Unit.openingParenthesis {
                    parentheses += 1
                } else if unit == Unit.closingParenthesis {
                    if parentheses == 0 {
                        break
                    }
                    parentheses -= 1
                }
                cursor += 1
            }
            destinationStart = position
            destinationEnd = cursor
            position = cursor
        }

        while position < end, isSpaceOrTab(units[position]) {
            position += 1
        }
        var title: String?
        if position < end,
           units[position] == Unit.quotationMark || units[position] == Unit.apostrophe || units[position] == Unit.openingParenthesis {
            let closer = units[position] == Unit.openingParenthesis ? Unit.closingParenthesis : units[position]
            var titleUnits: [UInt16] = []
            var cursor = position + 1
            while cursor < end, units[cursor] != closer {
                if units[cursor] == Unit.backslash, cursor + 1 < end, isASCIIPunctuation(units[cursor + 1]) {
                    cursor += 1
                }
                titleUnits.append(units[cursor])
                cursor += 1
            }
            guard cursor < end else { return nil }
            title = String(decoding: titleUnits, as: UTF16.self)
            position = cursor + 1
            while position < end, isSpaceOrTab(units[position]) {
                position += 1
            }
        }
        guard position < end, units[position] == Unit.closingParenthesis else { return nil }

        return InlineLink(
            closingBracket: closingBracket,
            destination: String(decoding: units[destinationStart..<destinationEnd], as: UTF16.self),
            destinationRange: NSRange(location: closingBracket + 2, length: position - closingBracket - 2),
            title: title,
            end: position + 1
        )
    }

    private static func linkKind(_ destination: String, title: String?) -> InlineKind {
        destination.lowercased().hasPrefix("\(PaperCitation.scheme)://")
            ? .citation(destination: destination, title: title)
            : .link(destination: destination, title: title)
    }

    private static func parseEmphasis(
        _ units: [UInt16],
        in run: Range<Int>,
        consumed: [Bool],
        into line: inout Line
    ) {
        var delimiters: [Delimiter] = []
        var index = run.lowerBound
        while index < run.upperBound {
            let unit = units[index]
            guard consumed[index] == false,
                  unit == Unit.star || unit == Unit.underscore || unit == Unit.tilde else {
                index += 1
                continue
            }
            var runEnd = index
            while runEnd < run.upperBound, units[runEnd] == unit, consumed[runEnd] == false {
                runEnd += 1
            }
            let length = runEnd - index
            // Strikethrough is "~~text~~"; a single "~" is ordinary text.
            if unit == Unit.tilde, length != 2 {
                index = runEnd
                continue
            }

            let before: UInt16? = index > 0 ? units[index - 1] : nil
            let after: UInt16? = runEnd < units.count ? units[runEnd] : nil
            let beforeIsSpace = isUnicodeWhitespace(before)
            let afterIsSpace = isUnicodeWhitespace(after)
            let beforeIsPunctuation = isUnicodePunctuation(before)
            let afterIsPunctuation = isUnicodePunctuation(after)
            let leftFlanking = afterIsSpace == false
                && (afterIsPunctuation == false || beforeIsSpace || beforeIsPunctuation)
            let rightFlanking = beforeIsSpace == false
                && (beforeIsPunctuation == false || afterIsSpace || afterIsPunctuation)

            let canOpen: Bool
            let canClose: Bool
            if unit == Unit.underscore {
                canOpen = leftFlanking && (rightFlanking == false || beforeIsPunctuation)
                canClose = rightFlanking && (leftFlanking == false || afterIsPunctuation)
            } else {
                canOpen = leftFlanking
                canClose = rightFlanking
            }
            delimiters.append(Delimiter(
                character: unit,
                start: index,
                length: length,
                remaining: length,
                canOpen: canOpen,
                canClose: canClose
            ))
            index = runEnd
        }

        for closerIndex in delimiters.indices {
            while delimiters[closerIndex].canClose, delimiters[closerIndex].remaining > 0 {
                let closer = delimiters[closerIndex]
                guard let openerIndex = (0..<closerIndex).reversed().first(where: { candidateIndex in
                    let candidate = delimiters[candidateIndex]
                    return candidate.isActive
                        && candidate.canOpen
                        && candidate.remaining > 0
                        && candidate.character == closer.character
                        && violatesRuleOfThree(opener: candidate, closer: closer) == false
                }) else {
                    break
                }

                var opener = delimiters[openerIndex]
                var matchedCloser = closer
                let used: Int
                if closer.character == Unit.tilde {
                    used = 2
                } else {
                    used = opener.remaining >= 2 && closer.remaining >= 2 ? 2 : 1
                }
                // An opener gives up its innermost characters, a closer its outermost ones.
                let contentStart = opener.start + opener.remaining
                let closerUsedStart = closer.start + closer.length - closer.remaining
                line.markers.append(NSRange(location: contentStart - used, length: used))
                line.markers.append(NSRange(location: closerUsedStart, length: used))
                let kind: InlineKind
                if closer.character == Unit.tilde {
                    kind = .strikethrough
                } else {
                    kind = used == 2 ? .strong : .emphasis
                }
                line.spans.append(InlineSpan(
                    kind: kind,
                    range: NSRange(location: contentStart, length: closerUsedStart - contentStart)
                ))

                opener.remaining -= used
                matchedCloser.remaining -= used
                delimiters[openerIndex] = opener
                delimiters[closerIndex] = matchedCloser
                for between in (openerIndex + 1)..<closerIndex {
                    delimiters[between].isActive = false
                }
            }
        }
    }

    private static func violatesRuleOfThree(opener: Delimiter, closer: Delimiter) -> Bool {
        guard opener.character != Unit.tilde, opener.canClose || closer.canOpen else { return false }
        return (opener.length + closer.length) % 3 == 0
            && (opener.length % 3 == 0 && closer.length % 3 == 0) == false
    }

    // MARK: - Characters

    private enum Unit {
        static let tab: UInt16 = 0x09
        static let space: UInt16 = 0x20
        static let exclamation: UInt16 = 0x21
        static let quotationMark: UInt16 = 0x22
        static let hash: UInt16 = 0x23
        static let dollar: UInt16 = 0x24
        static let apostrophe: UInt16 = 0x27
        static let openingParenthesis: UInt16 = 0x28
        static let closingParenthesis: UInt16 = 0x29
        static let star: UInt16 = 0x2A
        static let plus: UInt16 = 0x2B
        static let dash: UInt16 = 0x2D
        static let period: UInt16 = 0x2E
        static let colon: UInt16 = 0x3A
        static let lessThan: UInt16 = 0x3C
        static let greaterThan: UInt16 = 0x3E
        static let openingBracket: UInt16 = 0x5B
        static let backslash: UInt16 = 0x5C
        static let closingBracket: UInt16 = 0x5D
        static let underscore: UInt16 = 0x5F
        static let backtick: UInt16 = 0x60
        static let tilde: UInt16 = 0x7E
    }

    private static func skipSpaces(_ units: [UInt16], from start: Int, limit: Int) -> Int {
        var index = start
        while index < units.count, index - start < limit, units[index] == Unit.space {
            index += 1
        }
        return index
    }

    private static func isSpaceOrTab(_ unit: UInt16) -> Bool {
        unit == Unit.space || unit == Unit.tab
    }

    private static func isDigit(_ unit: UInt16) -> Bool {
        (0x30...0x39).contains(unit)
    }

    private static func isASCIILetter(_ unit: UInt16) -> Bool {
        (0x41...0x5A).contains(unit) || (0x61...0x7A).contains(unit)
    }

    private static func isASCIIPunctuation(_ unit: UInt16) -> Bool {
        (0x21...0x2F).contains(unit) || (0x3A...0x40).contains(unit)
            || (0x5B...0x60).contains(unit) || (0x7B...0x7E).contains(unit)
    }

    /// Line edges count as whitespace, as in CommonMark.
    private static func isUnicodeWhitespace(_ unit: UInt16?) -> Bool {
        guard let unit else { return true }
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    private static func isUnicodePunctuation(_ unit: UInt16?) -> Bool {
        guard let unit else { return false }
        if unit < 0x80 {
            return isASCIIPunctuation(unit)
        }
        // Surrogate halves (most emoji) count as neither space nor punctuation.
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return CharacterSet.punctuationCharacters.contains(scalar) || CharacterSet.symbols.contains(scalar)
    }
}
