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

/// An image to add to a writing.
enum WritingImageSource: Equatable, Sendable {
    case file(URL)
    /// Image data without a file, such as a pasted screenshot.
    case data(Data, fileExtension: String)
}

/// Paths of a writing's images. Added images are copied into the `assets` folder next to
/// `writing.md` and linked by relative paths, so the folder opens with its images in other
/// Markdown apps.
enum WritingImagePath {
    static let assetsDirectoryName = "assets"
    private static let maximumBaseNameLength = 60

    /// The local file an image destination points at: a path relative to the writing's
    /// folder, an absolute path or a `file:` URL. Nil for web images, which are not loaded.
    static func fileURL(forDestination destination: String, relativeTo baseURL: URL?) -> URL? {
        var text = destination.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("<"), text.hasSuffix(">") {
            text = String(text.dropFirst().dropLast())
        }
        text = unescaped(text)
        guard text.isEmpty == false else { return nil }

        // A URL scheme has at least two characters, unlike a Windows drive letter.
        if let colon = text.firstIndex(of: ":"),
           text.distance(from: text.startIndex, to: colon) >= 2,
           text[..<colon].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) }) {
            guard text[..<colon].lowercased() == "file",
                  let url = URL(string: text),
                  url.isFileURL else {
                return nil
            }
            return url.standardizedFileURL
        }
        let path = text.removingPercentEncoding ?? text
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        if path.hasPrefix("~/") {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        }
        guard let baseURL else { return nil }
        return baseURL.appendingPathComponent(path).standardizedFileURL
    }

    /// A file name for an added image: letters and digits of `name` (any script), with other
    /// characters turned into dashes, so the path needs no escaping in Markdown.
    static func assetBaseName(from name: String) -> String {
        var result = ""
        var pendingDash = false
        for character in name {
            if character.isLetter || character.isNumber || character == "_" || character == "." {
                if pendingDash, result.isEmpty == false {
                    result.append("-")
                }
                pendingDash = false
                result.append(character)
            } else {
                pendingDash = true
            }
            if result.count >= maximumBaseNameLength {
                break
            }
        }
        while result.hasPrefix(".") {
            result.removeFirst()
        }
        return result.isEmpty ? "image" : result
    }

    /// `![alt](path)` for an image in the writing's folder.
    static func markdown(alt: String, relativePath: String) -> String {
        "![\(MarkdownEscaping.escapedLinkLabel(alt))](\(relativePath))"
    }

    private static func unescaped(_ text: String) -> String {
        guard text.contains("\\") else { return text }
        var result = ""
        var isEscaping = false
        for character in text {
            if isEscaping {
                if character.isASCII, character.isPunctuation || character.isSymbol {
                    result.append(character)
                } else {
                    result.append("\\")
                    result.append(character)
                }
                isEscaping = false
            } else if character == "\\" {
                isEscaping = true
            } else {
                result.append(character)
            }
        }
        if isEscaping {
            result.append("\\")
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

/// A citation in a writing as `meta.json` keeps it, with the passage it cites, so the
/// reader can mark cited passages without reading every writing.
struct WritingCitationRecord: Codable, Equatable, Hashable, Sendable {
    var paperID: UUID
    var attachmentID: UUID?
    var pageIndex: Int?
    var htmlSelector: String?
    var quotePrefix: String?
    /// The block quote the citation closes; nil for an inline citation, which only has
    /// its quote prefix.
    var passage: String?

    init(citation: PaperCitation, passage: String?) {
        paperID = citation.paperID
        attachmentID = citation.attachmentID
        pageIndex = citation.pageIndex
        htmlSelector = citation.htmlSelector
        quotePrefix = citation.quotePrefix
        self.passage = passage == citation.quotePrefix ? nil : passage
    }

    var citation: PaperCitation {
        PaperCitation(
            paperID: paperID,
            attachmentID: attachmentID,
            pageIndex: pageIndex,
            htmlSelector: htmlSelector,
            quotePrefix: quotePrefix
        )
    }

    /// The text to mark in the paper.
    var markedText: String? {
        passage ?? quotePrefix
    }
}

/// A citation of a paper from one of the writings, as the reader marks it.
struct WritingCitationMark: Equatable, Hashable, Sendable, Identifiable {
    var writingID: UUID
    /// The citation's position among the writing's citations.
    var index: Int
    var record: WritingCitationRecord

    var id: String {
        "\(writingID.uuidString)#\(index)"
    }
}

/// Finds citation links the way the editor shows them: not in code, with their labels.
enum WritingCitationScanner {
    struct Occurrence: Equatable {
        var citation: PaperCitation
        /// The link label, in UTF-16 offsets of the writing.
        var labelRange: NSRange
        var passage: String?
    }

    static func occurrences(in markdown: String) -> [Occurrence] {
        guard markdown.range(of: "\(PaperCitation.scheme):", options: .caseInsensitive) != nil else { return [] }
        let text = markdown as NSString
        var occurrences: [Occurrence] = []
        var fence: MarkdownLiveSyntax.FenceState?
        var lineStart = 0
        while lineStart < text.length {
            let lineRange = text.lineRange(for: NSRange(location: lineStart, length: 0))
            lineStart = NSMaxRange(lineRange)
            var contentEnd = NSMaxRange(lineRange)
            while contentEnd > lineRange.location, text.character(at: contentEnd - 1) == 0x0A || text.character(at: contentEnd - 1) == 0x0D {
                contentEnd -= 1
            }
            let content = NSRange(location: lineRange.location, length: contentEnd - lineRange.location)
            let lineText = text.substring(with: content)
            // Only citation lines and possible fences need parsing.
            let trimmed = lineText.drop { $0 == " " }
            guard lineText.range(of: "\(PaperCitation.scheme):", options: .caseInsensitive) != nil
                    || trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") else {
                continue
            }
            let (line, nextFence) = MarkdownLiveSyntax.parse(lineText, fence: fence)
            fence = nextFence
            for span in line.spans {
                guard case let .citation(destination, title) = span.kind,
                      let citation = PaperCitation(linkDestination: destination, title: title) else {
                    continue
                }
                let labelRange = NSRange(location: content.location + span.range.location, length: span.range.length)
                occurrences.append(Occurrence(
                    citation: citation,
                    labelRange: labelRange,
                    passage: WritingCitationContext.quote(forCitationAt: labelRange.location, in: text, citation: citation)
                ))
            }
        }
        return occurrences
    }

    static func records(in markdown: String) -> [WritingCitationRecord] {
        occurrences(in: markdown).map { WritingCitationRecord(citation: $0.citation, passage: $0.passage) }
    }
}

enum WritingCitationContext {
    /// The block quote above a citation line such as "> — [label](…)", so the reader
    /// can highlight the whole passage. Nil when the link does not close a block quote,
    /// or when the quote was edited and no longer starts like the link's quote prefix.
    static func quote(forCitationAt location: Int, in text: String, citation: PaperCitation) -> String? {
        quote(forCitationAt: location, in: text as NSString, citation: citation)
    }

    static func quote(forCitationAt location: Int, in string: NSString, citation: PaperCitation) -> String? {
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
