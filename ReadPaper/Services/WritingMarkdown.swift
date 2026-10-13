import Foundation

/// Escapes text inserted into a writing so it reads back as the same plain text.
enum MarkdownEscaping {
    /// `$` is escaped too: Markdown apps with math support read `$…$` as TeX.
    private static let inlineSpecials: Set<Character> = ["\\", "`", "*", "_", "[", "]", "<", "$"]
    private static let linkLabelSpecials: Set<Character> = ["\\", "`", "*", "_", "[", "]"]
    private static let blockStarters: Set<Character> = ["#", ">", "-", "+", "=", "|"]

    static func escapedInlineText(_ text: String) -> String {
        escaped(text, specials: inlineSpecials, escapesStrikethrough: true)
    }

    static func escapedLinkLabel(_ text: String) -> String {
        escaped(text, specials: linkLabelSpecials, escapesStrikethrough: true)
    }

    /// For a link title in double quotes.
    static func escapedLinkTitle(_ text: String) -> String {
        escaped(text, specials: ["\\", "\""], escapesStrikethrough: false)
    }

    /// Also escapes a leading character that would turn the text into a heading,
    /// list item or nested quote.
    static func escapedBlockText(_ text: String) -> String {
        let escaped = escapedInlineText(text)
        guard let first = escaped.first else { return escaped }
        if blockStarters.contains(first) {
            return "\\" + escaped
        }
        let digits = escaped.prefix { $0.isASCII && $0.isNumber }
        if digits.isEmpty == false, digits.count <= 9 {
            let markerIndex = escaped.index(escaped.startIndex, offsetBy: digits.count)
            if markerIndex < escaped.endIndex, escaped[markerIndex] == "." || escaped[markerIndex] == ")" {
                return String(escaped[..<markerIndex]) + "\\" + String(escaped[markerIndex...])
            }
        }
        return escaped
    }

    private static func escaped(_ text: String, specials: Set<Character>, escapesStrikethrough: Bool) -> String {
        let characters = Array(text)
        var result = ""
        result.reserveCapacity(text.count)
        for (index, character) in characters.enumerated() {
            let isStrikethrough = escapesStrikethrough && character == "~" && (
                (index > 0 && characters[index - 1] == "~")
                    || (index + 1 < characters.count && characters[index + 1] == "~")
            )
            if specials.contains(character) || isStrikethrough {
                result.append("\\")
            }
            result.append(character)
        }
        return result
    }
}

enum WritingTitle {
    static let maximumLength = 80

    /// The text of the first line that has any, without its Markdown syntax.
    static func derive(from markdown: String) -> String {
        var fence: MarkdownLiveSyntax.FenceState?
        for text in markdown.components(separatedBy: .newlines) {
            let (line, nextFence) = MarkdownLiveSyntax.parse(text, fence: fence)
            fence = nextFence
            guard line.isBlank == false, line.isFence == false, line.isRule == false else { continue }
            let title = visibleText(of: text, line: line)
            if title.isEmpty == false {
                return title.count > maximumLength ? String(title.prefix(maximumLength)) + "…" : title
            }
        }
        return ""
    }

    /// The line as the live preview shows it, with syntax characters and list markers removed.
    static func visibleText(of text: String, line: MarkdownLiveSyntax.Line) -> String {
        let units = Array(text.utf16)
        var hidden = IndexSet()
        for marker in line.markers {
            hidden.insert(integersIn: marker.location..<NSMaxRange(marker))
        }
        if let list = line.list {
            hidden.insert(integersIn: list.range.location..<NSMaxRange(list.range))
        }
        let visible = units.indices.filter { hidden.contains($0) == false }.map { units[$0] }
        return String(decoding: visible, as: UTF16.self)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.isEmpty == false }
            .joined(separator: " ")
    }
}

enum WritingStatistics {
    private static let linkDestinationExpression = try! NSRegularExpression(
        pattern: #"\]\([^)\s]*(?:\s+"(?:[^"\\]|\\.)*")?\)"#
    )

    /// Counts words the way word processors do for mixed text: every CJK character,
    /// plus every run of other letters and digits. Link destinations are left out.
    static func wordCount(in markdown: String) -> Int {
        let fullRange = NSRange(markdown.startIndex..<markdown.endIndex, in: markdown)
        let text = linkDestinationExpression.stringByReplacingMatches(
            in: markdown,
            range: fullRange,
            withTemplate: "]"
        )
        var count = 0
        var isInWord = false
        for scalar in text.unicodeScalars {
            if isCJK(scalar) {
                count += 1
                isInWord = false
            } else if CharacterSet.alphanumerics.contains(scalar) {
                if isInWord == false {
                    count += 1
                    isInWord = true
                }
            } else if isInWord, scalar == "'" || scalar == "\u{2019}" {
                continue
            } else {
                isInWord = false
            }
        }
        return count
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0x20000...0x2FA1F:
            return true
        default:
            return false
        }
    }
}

/// A text change to apply to a writing, with the selection to show afterwards.
struct WritingEdit: Equatable {
    var range: NSRange
    var replacement: String
    var selectionAfter: NSRange
}

enum WritingInsertion {
    /// Inserts `block` as its own paragraph after the paragraph containing `location`
    /// (or at an empty line), separated from the text around it by blank lines. The
    /// caret ends up after the block, so repeated insertions keep their order.
    static func block(_ block: String, in text: String, at location: Int) -> WritingEdit {
        let string = text as NSString
        let length = string.length
        var insertion = min(max(0, location), length)

        let currentLine = string.lineRange(for: NSRange(location: insertion, length: 0))
        if isBlank(string, lineRange: currentLine) {
            insertion = currentLine.location
        } else {
            var line = currentLine
            while true {
                let next = NSMaxRange(line)
                let nextLine = string.lineRange(for: NSRange(location: next, length: 0))
                if next >= length || isBlank(string, lineRange: nextLine) {
                    insertion = contentEnd(of: line, in: string)
                    break
                }
                line = nextLine
            }
        }

        let newlinesBefore = newlineCount(in: string, before: insertion)
        let newlinesAfter = newlineCount(in: string, from: insertion)
        let prefix = insertion == 0 ? "" : String(repeating: "\n", count: max(0, 2 - newlinesBefore))
        // At the end too, so text typed below the block starts a new paragraph instead
        // of continuing the quote.
        let suffix = String(repeating: "\n", count: max(0, 2 - newlinesAfter))
        let replacement = prefix + block + suffix
        let caret = insertion + (prefix as NSString).length + (block as NSString).length
        return WritingEdit(
            range: NSRange(location: insertion, length: 0),
            replacement: replacement,
            selectionAfter: NSRange(location: caret, length: 0)
        )
    }

    /// Inserts `snippet` after the selection, keeping the selected text. A space is
    /// added after Latin text, but not after CJK text or whitespace.
    static func inline(_ snippet: String, in text: String, selection: NSRange) -> WritingEdit {
        let string = text as NSString
        let location = min(max(0, NSMaxRange(selection)), string.length)
        var replacement = snippet
        if location > 0 {
            let previous = string.character(at: location - 1)
            let isLatin = previous < 0x80
                && previous != 0x20 && previous != 0x09 && previous != 0x0A
                && previous != 0x28 && previous != 0x5B
            if isLatin {
                replacement = " " + replacement
            }
        }
        return WritingEdit(
            range: NSRange(location: location, length: 0),
            replacement: replacement,
            selectionAfter: NSRange(location: location + (replacement as NSString).length, length: 0)
        )
    }

    private static func isBlank(_ string: NSString, lineRange: NSRange) -> Bool {
        string.substring(with: lineRange).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func contentEnd(of lineRange: NSRange, in string: NSString) -> Int {
        var end = NSMaxRange(lineRange)
        while end > lineRange.location {
            let character = string.character(at: end - 1)
            guard character == 0x0A || character == 0x0D else { break }
            end -= 1
        }
        return end
    }

    private static func newlineCount(in string: NSString, before location: Int) -> Int {
        var count = 0
        var index = location - 1
        while index >= 0, count < 2, string.character(at: index) == 0x0A {
            count += 1
            index -= 1
        }
        return count
    }

    private static func newlineCount(in string: NSString, from location: Int) -> Int {
        var count = 0
        var index = location
        while index < string.length, count < 2, string.character(at: index) == 0x0A {
            count += 1
            index += 1
        }
        return count
    }
}

enum WritingContinuation {
    /// What Return does on a list item or block quote line: continue it on a new line,
    /// or end it when the item is empty. Ending leaves a blank line, so text typed next
    /// starts a new paragraph instead of continuing the list or quote. Nil for other lines.
    static func newline(in text: String, selection: NSRange, isInCodeBlock: Bool) -> WritingEdit? {
        guard selection.length == 0, isInCodeBlock == false else { return nil }
        let string = text as NSString
        let caret = min(max(0, selection.location), string.length)
        let lineRange = string.lineRange(for: NSRange(location: caret, length: 0))
        var contentEnd = NSMaxRange(lineRange)
        while contentEnd > lineRange.location {
            let character = string.character(at: contentEnd - 1)
            guard character == 0x0A || character == 0x0D else { break }
            contentEnd -= 1
        }
        let contentRange = NSRange(location: lineRange.location, length: contentEnd - lineRange.location)
        let lineText = string.substring(with: contentRange) as NSString
        let line = MarkdownLiveSyntax.parse(lineText as String, fence: nil).line
        let offset = caret - lineRange.location

        let continuationStart: Int
        let marker: String
        if let list = line.list {
            continuationStart = NSMaxRange(list.range)
            marker = lineText.substring(with: NSRange(location: 0, length: list.range.location))
                + nextListMarker(lineText.substring(with: list.range))
        } else if line.quoteDepth > 0, line.isRule == false {
            continuationStart = NSMaxRange(line.markers[line.quoteDepth - 1])
            let prefix = lineText.substring(to: continuationStart)
            marker = prefix.hasSuffix(" ") ? prefix : prefix + " "
        } else {
            return nil
        }
        guard offset >= continuationStart else { return nil }

        let rest = lineText.substring(from: continuationStart)
        if rest.trimmingCharacters(in: .whitespaces).isEmpty {
            return WritingEdit(
                range: contentRange,
                replacement: "\n",
                selectionAfter: NSRange(location: lineRange.location + 1, length: 0)
            )
        }
        let insertion = "\n" + marker
        return WritingEdit(
            range: NSRange(location: caret, length: 0),
            replacement: insertion,
            selectionAfter: NSRange(location: caret + (insertion as NSString).length, length: 0)
        )
    }

    /// "- " stays "- "; "3. " becomes "4. ".
    private static func nextListMarker(_ marker: String) -> String {
        let trimmed = marker.trimmingCharacters(in: .whitespaces)
        guard let delimiter = trimmed.last, delimiter == "." || delimiter == ")",
              let number = Int(trimmed.dropLast()) else {
            return trimmed + " "
        }
        return "\(number + 1)\(delimiter) "
    }
}

enum WritingCitationContext {
    /// The block quote above a citation line such as "> — [label](…)", so the reader
    /// can highlight the whole passage. Nil when the link does not close a block quote,
    /// or when the quote was edited and no longer starts like the link's quote prefix.
    static func quote(forCitationAt location: Int, in text: String, citation: PaperCitation) -> String? {
        let string = text as NSString
        guard location >= 0, location < string.length else { return nil }
        let citationLine = string.lineRange(for: NSRange(location: location, length: 0))
        guard MarkdownLiveSyntax.parse(lineText(string, citationLine), fence: nil).line.quoteDepth > 0 else {
            return nil
        }

        var passage: [String] = []
        var cursor = citationLine.location
        while cursor > 0 {
            let lineRange = string.lineRange(for: NSRange(location: cursor - 1, length: 0))
            let text = lineText(string, lineRange)
            let line = MarkdownLiveSyntax.parse(text, fence: nil).line
            guard line.quoteDepth > 0 else { break }
            let visible = WritingTitle.visibleText(of: text, line: line)
            if visible.isEmpty {
                // An empty quote line ends the passage once some text has been found.
                if passage.isEmpty == false {
                    break
                }
            } else {
                passage.insert(visible, at: 0)
            }
            cursor = lineRange.location
        }

        let quote = passage.joined(separator: " ")
        guard quote.isEmpty == false else { return nil }
        if let prefix = citation.quotePrefix, normalized(quote).hasPrefix(normalized(prefix)) == false {
            return nil
        }
        return quote
    }

    private static func lineText(_ string: NSString, _ lineRange: NSRange) -> String {
        string.substring(with: lineRange).trimmingCharacters(in: .newlines)
    }

    private static func normalized(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.isEmpty == false }
            .joined(separator: " ")
    }
}
