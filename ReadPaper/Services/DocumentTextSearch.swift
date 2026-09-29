import Foundation
import PDFKit

struct DocumentSearchOptions: Equatable, Sendable {
    var matchCase = false
    var wholeWords = false
}

enum DocumentFindDirection: Equatable, Sendable {
    case forward
    case backward
}

/// In-document find request owned by the reader pane. `navigationToken` changes
/// whenever the user asks for the next or previous match.
struct DocumentFindRequest: Equatable, Sendable {
    var query: String
    var options: DocumentSearchOptions
    var navigationToken: Int = 0
    var navigationDirection: DocumentFindDirection = .forward
}

struct DocumentFindStatus: Equatable, Sendable {
    var query: String
    var options: DocumentSearchOptions
    var matchCount: Int
    var currentIndex: Int?
    var isSearching: Bool

    static func searching(_ request: DocumentFindRequest) -> Self {
        Self(query: request.query, options: request.options, matchCount: 0, currentIndex: nil, isSearching: true)
    }
}

struct DocumentSearchMatch: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// Whitespace layout agrees with the query.
        case exact
        /// Only matches after ignoring whitespace/hyphen differences, e.g. PDF
        /// text such as "T ransformer", "atten-\ntion" or "theattention".
        case spacingTolerant
    }

    var sourceRange: NSRange
    var kind: Kind
}

/// Search-oriented view of a source string.
///
/// PDF text extraction regularly inserts spaces inside words, drops spaces
/// between words, splits words with line-end hyphens and emits ligatures or
/// detached accents. The folded text therefore drops every whitespace/dash
/// "separator" and remembers where one was, so a match can be found regardless
/// of spacing and then classified as exact or spacing-tolerant. Every folded
/// UTF-16 unit maps back to a grapheme range in the source for highlighting.
struct DocumentSearchText: Equatable, Sendable {
    /// Placed between text blocks that must never be matched across.
    static let hardBreak: Character = "\u{1E}"
    /// Spacing-tolerant matches shorter than this must sit on word boundaries.
    static let tolerantMatchMinimumLength = 6

    let sourceUnits: [UInt16]
    fileprivate let foldedUnits: [UInt16]
    fileprivate let sourceStarts: [Int]
    fileprivate let sourceEnds: [Int]
    fileprivate let separatorBefore: [Bool]

    init(_ source: String) {
        self.init(sourceUnits: Array(source.utf16), keepsHardBreaks: true)
    }

    fileprivate init(sourceUnits: [UInt16], keepsHardBreaks: Bool) {
        var builder = FoldedTextBuilder(keepsHardBreaks: keepsHardBreaks)
        builder.append(sourceUnits)
        self.sourceUnits = sourceUnits
        foldedUnits = builder.foldedUnits
        sourceStarts = builder.sourceStarts
        sourceEnds = builder.sourceEnds
        separatorBefore = builder.separatorBefore
    }

    var isEmpty: Bool { foldedUnits.isEmpty }

    func matches(
        of query: String,
        options: DocumentSearchOptions = DocumentSearchOptions()
    ) -> [DocumentSearchMatch] {
        matches(of: DocumentSearchQuery(query), options: options)
    }

    func matches(
        of query: DocumentSearchQuery,
        options: DocumentSearchOptions = DocumentSearchOptions()
    ) -> [DocumentSearchMatch] {
        guard query.isEmpty == false, foldedUnits.isEmpty == false else { return [] }

        let haystack = NSString(characters: foldedUnits, length: foldedUnits.count)
        let needle = NSString(characters: query.text.foldedUnits, length: query.text.foldedUnits.count) as String
        var compareOptions: NSString.CompareOptions = [.diacriticInsensitive, .widthInsensitive]
        if options.matchCase == false {
            compareOptions.insert(.caseInsensitive)
        }

        var results: [DocumentSearchMatch] = []
        var location = 0
        while location < haystack.length {
            let found = haystack.range(
                of: needle,
                options: compareOptions,
                range: NSRange(location: location, length: haystack.length - location)
            )
            guard found.location != NSNotFound, found.length > 0 else { break }

            if let match = acceptedMatch(for: found, query: query, options: options) {
                results.append(match)
                location = NSMaxRange(found)
            } else {
                // A rejected loose match may overlap a valid one that starts later.
                location = found.location + 1
            }
        }
        return results
    }

    private func acceptedMatch(
        for foldedRange: NSRange,
        query: DocumentSearchQuery,
        options: DocumentSearchOptions
    ) -> DocumentSearchMatch? {
        let sourceRange = sourceRange(forFolded: foldedRange)
        let isWordBounded = isWordBounded(sourceRange)
        if options.wholeWords, isWordBounded == false {
            return nil
        }

        if hasSameSeparatorLayout(foldedRange, as: query) {
            return DocumentSearchMatch(sourceRange: sourceRange, kind: .exact)
        }

        // Ignoring whitespace makes short queries match across unrelated
        // words ("is a" in "this approach", "form" in "for model"). Keep such
        // loose matches only when they are long enough to be unambiguous or
        // look like a complete word in the source.
        guard query.text.foldedUnits.count >= Self.tolerantMatchMinimumLength || isWordBounded else {
            return nil
        }
        return DocumentSearchMatch(sourceRange: sourceRange, kind: .spacingTolerant)
    }

    private func hasSameSeparatorLayout(_ foldedRange: NSRange, as query: DocumentSearchQuery) -> Bool {
        let queryLayout = query.text.separatorBefore
        guard foldedRange.length > 1 else { return true }

        if foldedRange.length == queryLayout.count {
            for offset in 1..<foldedRange.length
            where separatorBefore[foldedRange.location + offset] != queryLayout[offset] {
                return false
            }
            return true
        }

        // Case folding can change the matched length (e.g. "ß" / "ss"); fall
        // back to comparing how many word gaps each side contains.
        let textSeparators = (foldedRange.location + 1..<NSMaxRange(foldedRange))
            .filter { separatorBefore[$0] }
            .count
        let querySeparators = queryLayout.dropFirst().filter { $0 }.count
        return textSeparators == querySeparators
    }

    private func sourceRange(forFolded foldedRange: NSRange) -> NSRange {
        let start = sourceStarts[foldedRange.location]
        let end = sourceEnds[NSMaxRange(foldedRange) - 1]
        return NSRange(location: start, length: end - start)
    }

    private func isWordBounded(_ sourceRange: NSRange) -> Bool {
        let first = scalar(startingAt: sourceRange.location)
        let last = scalar(endingAt: NSMaxRange(sourceRange))
        let before = scalar(endingAt: sourceRange.location)
        let after = scalar(startingAt: NSMaxRange(sourceRange))

        return Self.isBoundary(between: before, and: first) && Self.isBoundary(between: last, and: after)
    }

    /// CJK text has no word spacing, so either side being CJK counts as a boundary.
    private static func isBoundary(between left: Unicode.Scalar?, and right: Unicode.Scalar?) -> Bool {
        guard let left, let right else { return true }
        if isCJK(left) || isCJK(right) { return true }
        return isWordScalar(left) == false || isWordScalar(right) == false
    }

    private func scalar(startingAt index: Int) -> Unicode.Scalar? {
        guard index >= 0, index < sourceUnits.count else { return nil }
        let unit = sourceUnits[index]
        if UTF16.isLeadSurrogate(unit), index + 1 < sourceUnits.count {
            return Unicode.Scalar(UTF16.decode(lead: unit, trail: sourceUnits[index + 1]))
        }
        return Unicode.Scalar(unit)
    }

    private func scalar(endingAt index: Int) -> Unicode.Scalar? {
        guard index > 0, index <= sourceUnits.count else { return nil }
        let unit = sourceUnits[index - 1]
        if UTF16.isTrailSurrogate(unit), index >= 2 {
            return Unicode.Scalar(UTF16.decode(lead: sourceUnits[index - 2], trail: unit))
        }
        return Unicode.Scalar(unit)
    }

    fileprivate static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isAlphabetic || scalar.properties.numericType != nil
    }

    fileprivate static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3000...0x303F, // CJK punctuation
             0x3040...0x30FF, // Hiragana, Katakana
             0x3400...0x4DBF,
             0x4E00...0x9FFF,
             0xF900...0xFAFF,
             0xFF00...0xFFEF, // Full-width forms
             0x20000...0x2FA1F:
            return true
        default:
            return false
        }
    }
}

private extension UTF16 {
    static func decode(lead: UInt16, trail: UInt16) -> UInt32 {
        0x10000 + ((UInt32(lead) - 0xD800) << 10) + (UInt32(trail) - 0xDC00)
    }
}

/// A query folded with the same rules as the searched text.
struct DocumentSearchQuery: Equatable, Sendable {
    let rawValue: String
    fileprivate let text: DocumentSearchText

    init(_ rawValue: String) {
        self.rawValue = rawValue
        // Queries never contain the hard-break marker, so matches cannot cross it.
        text = DocumentSearchText(sourceUnits: Array(rawValue.utf16), keepsHardBreaks: false)
    }

    var isEmpty: Bool { text.isEmpty }
}

private struct FoldedTextBuilder {
    private enum GraphemeClass {
        case separator
        case ignorable
        case content([UInt16])
    }

    let keepsHardBreaks: Bool
    private(set) var foldedUnits: [UInt16] = []
    private(set) var sourceStarts: [Int] = []
    private(set) var sourceEnds: [Int] = []
    private(set) var separatorBefore: [Bool] = []
    private var hasPendingSeparator = false
    private var previousContentWasCJK = false

    init(keepsHardBreaks: Bool) {
        self.keepsHardBreaks = keepsHardBreaks
    }

    mutating func append(_ units: [UInt16]) {
        foldedUnits.reserveCapacity(units.count)
        sourceStarts.reserveCapacity(units.count)
        sourceEnds.reserveCapacity(units.count)
        separatorBefore.reserveCapacity(units.count)

        var source: NSString?
        var index = 0
        while index < units.count {
            let unit = units[index]
            // Fast path: a plain ASCII character not followed by a combining mark.
            if unit < 0x80, index + 1 == units.count || units[index + 1] < 0x300 {
                append(classifyASCII(unit), sourceRange: NSRange(location: index, length: 1), isCJK: false)
                index += 1
                continue
            }

            if source == nil {
                source = NSString(characters: units, length: units.count)
            }
            let range = source!.rangeOfComposedCharacterSequence(at: index)
            let grapheme = source!.substring(with: range)
            let isCJK = grapheme.unicodeScalars.first.map(DocumentSearchText.isCJK) ?? false
            append(classify(grapheme), sourceRange: range, isCJK: isCJK)
            index = max(NSMaxRange(range), index + 1)
        }
    }

    private mutating func append(_ graphemeClass: GraphemeClass, sourceRange: NSRange, isCJK: Bool) {
        switch graphemeClass {
        case .separator:
            hasPendingSeparator = true
        case .ignorable:
            break
        case let .content(units):
            // Spaces around CJK text are layout artifacts rather than word gaps.
            let isWordGap = hasPendingSeparator && foldedUnits.isEmpty == false &&
                previousContentWasCJK == false && isCJK == false
            for (offset, unit) in units.enumerated() {
                foldedUnits.append(unit)
                sourceStarts.append(sourceRange.location)
                sourceEnds.append(NSMaxRange(sourceRange))
                separatorBefore.append(offset == 0 && isWordGap)
            }
            hasPendingSeparator = false
            previousContentWasCJK = isCJK
        }
    }

    private func classifyASCII(_ unit: UInt16) -> GraphemeClass {
        switch unit {
        case 0x09...0x0D, 0x20, 0x2D: // whitespace, hyphen-minus
            return .separator
        case 0x1E where keepsHardBreaks:
            return .content([unit])
        case 0x00...0x1F, 0x7F:
            return .ignorable
        default:
            return .content([unit])
        }
    }

    private func classify(_ grapheme: String) -> GraphemeClass {
        let scalars = grapheme.unicodeScalars
        if scalars.allSatisfy(Self.isSeparator) {
            return .separator
        }
        if scalars.allSatisfy({ Self.isIgnorable($0) || Self.isSeparator($0) }) {
            return scalars.contains(where: Self.isSeparator) ? .separator : .ignorable
        }
        if scalars.count == 1, let first = scalars.first, let replacement = Self.replacements[first.value] {
            return .content(Array(replacement.utf16))
        }

        // NFKC expands ligatures ("ﬁ" → "fi") and compatibility forms.
        let folded = grapheme.precomposedStringWithCompatibilityMapping
            .unicodeScalars
            .filter { Self.isSeparator($0) == false && Self.isIgnorable($0) == false }
        guard folded.isEmpty == false else { return .ignorable }
        var result = String.UnicodeScalarView()
        result.append(contentsOf: folded)
        return .content(Array(String(result).utf16))
    }

    private static let replacements: [UInt32: String] = [
        0x2018: "'", 0x2019: "'", 0x201A: "'", 0x201B: "'", 0x2032: "'", 0x02BC: "'",
        0x201C: "\"", 0x201D: "\"", 0x201E: "\"", 0x201F: "\"", 0x2033: "\"",
        0x0131: "i", // dotless i emitted for accented "ï" / "í" in LaTeX PDFs
        0x0237: "j",
    ]

    private static func isSeparator(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x2D, 0x2010...0x2015, 0x2212, 0xFE58, 0xFE63, 0xFF0D:
            return true
        default:
            return scalar.properties.isWhitespace
        }
    }

    private static func isIgnorable(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00AD, 0x200B...0x200D, 0x2060, 0xFEFF:
            return true
        default:
            break
        }
        switch scalar.properties.generalCategory {
        case .control, .format, .nonspacingMark, .enclosingMark:
            return true
        case .modifierSymbol:
            // Detached accents such as "¨" in "na¨ıve" come out of PDFs as
            // standalone modifier symbols; ASCII "^" and "`" stay searchable.
            return scalar.isASCII == false
        default:
            return false
        }
    }
}

/// Text split into ordered segments (e.g. DOM text nodes). Matches may span
/// adjacent segments of the same block but never cross a block break.
struct DocumentSearchSegmentedText: Sendable {
    struct SegmentPosition: Equatable, Sendable {
        var segment: Int
        var offset: Int
    }

    struct SegmentMatch: Equatable, Sendable {
        var start: SegmentPosition
        var end: SegmentPosition
        var kind: DocumentSearchMatch.Kind
    }

    let text: DocumentSearchText
    private let segmentStarts: [Int]

    init(segments: [String], breaksBefore: [Bool]) {
        var units: [UInt16] = []
        var starts: [Int] = []
        starts.reserveCapacity(segments.count)
        let hardBreak = Array(String(DocumentSearchText.hardBreak).utf16)
        for (index, segment) in segments.enumerated() {
            if index > 0, index < breaksBefore.count, breaksBefore[index] {
                units.append(contentsOf: hardBreak)
            }
            starts.append(units.count)
            units.append(contentsOf: segment.utf16)
        }
        text = DocumentSearchText(sourceUnits: units, keepsHardBreaks: true)
        segmentStarts = starts
    }

    func matches(
        of query: String,
        options: DocumentSearchOptions = DocumentSearchOptions()
    ) -> [SegmentMatch] {
        text.matches(of: query, options: options).compactMap { match in
            guard match.sourceRange.length > 0,
                  let start = position(containing: match.sourceRange.location),
                  let last = position(containing: NSMaxRange(match.sourceRange) - 1)
            else {
                return nil
            }
            return SegmentMatch(
                start: start,
                end: SegmentPosition(segment: last.segment, offset: last.offset + 1),
                kind: match.kind
            )
        }
    }

    private func position(containing location: Int) -> SegmentPosition? {
        var low = 0
        var high = segmentStarts.count - 1
        var found: Int?
        while low <= high {
            let middle = (low + high) / 2
            if segmentStarts[middle] <= location {
                found = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        guard let found else { return nil }
        return SegmentPosition(segment: found, offset: location - segmentStarts[found])
    }
}

enum PDFDocumentSearchTextLoader {
    /// Extracts and folds every page off the main actor. The returned ranges are
    /// valid for `PDFPage.selection(for:)` on any document loaded from the same file.
    static func loadPages(from url: URL) async -> [DocumentSearchText]? {
        let task = Task.detached(priority: .userInitiated) { () -> [DocumentSearchText]? in
            guard let document = PDFDocument(url: url) else { return nil }
            var pages: [DocumentSearchText] = []
            pages.reserveCapacity(document.pageCount)
            for pageIndex in 0..<document.pageCount {
                if Task.isCancelled { return nil }
                pages.append(DocumentSearchText(document.page(at: pageIndex)?.string ?? ""))
            }
            return pages
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
