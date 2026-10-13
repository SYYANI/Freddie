import Foundation

/// A passage of a library paper cited from a writing, stored in the writing's Markdown as
/// `[label](readpaper://paper/<paper ID>?att=…&p=…&anchor=… "start of the quote")`.
/// Everything needed to jump back is in the link itself, so a citation keeps working after
/// it is copied into another writing or edited outside the app. The destination is ASCII
/// only: apps disagree on how to encode a URL that mixes raw Unicode with percent escapes,
/// so the quote goes in the link title, which Markdown apps show as a tooltip.
struct PaperCitation: Hashable, Sendable {
    static let scheme = "readpaper"
    static let host = "paper"
    /// Characters of the quote kept in the link title, enough to find the passage on its page.
    static let quotePrefixLength = 40

    var paperID: UUID
    var attachmentID: UUID?
    /// Zero-based like `Note.pageIndex`; the link holds the one-based page number.
    var pageIndex: Int?
    var htmlSelector: String?
    var quotePrefix: String?

    init(
        paperID: UUID,
        attachmentID: UUID? = nil,
        pageIndex: Int? = nil,
        htmlSelector: String? = nil,
        quotePrefix: String? = nil
    ) {
        self.paperID = paperID
        self.attachmentID = attachmentID
        self.pageIndex = pageIndex.map { max(0, $0) }
        self.htmlSelector = Self.nonEmpty(htmlSelector)
        self.quotePrefix = Self.nonEmpty(quotePrefix).map(Self.prefix)
    }

    init(paperID: UUID, selection: NoteSelectionContext) {
        self.init(
            paperID: paperID,
            attachmentID: selection.attachmentID,
            pageIndex: selection.pageIndex,
            htmlSelector: selection.htmlSelector,
            quotePrefix: selection.trimmedQuote
        )
    }

    /// Parses a link written from `linkDestination` and `linkTitle`. A `q` query item
    /// stands in for a missing title.
    init?(linkDestination: String, title: String? = nil) {
        var text = linkDestination.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("<"), text.hasSuffix(">") {
            text = String(text.dropFirst().dropLast())
        }
        let prefix = "\(Self.scheme)://\(Self.host)/"
        guard text.lowercased().hasPrefix(prefix) else { return nil }

        let rest = text.dropFirst(prefix.count)
        let pathEnd = rest.firstIndex { $0 == "?" || $0 == "#" } ?? rest.endIndex
        guard let paperID = UUID(uuidString: String(rest[..<pathEnd])) else { return nil }

        var attachmentID: UUID?
        var pageIndex: Int?
        var htmlSelector: String?
        var quotePrefix: String?
        if pathEnd < rest.endIndex, rest[pathEnd] == "?" {
            let queryStart = rest.index(after: pathEnd)
            let queryEnd = rest[queryStart...].firstIndex(of: "#") ?? rest.endIndex
            for pair in rest[queryStart..<queryEnd].split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { continue }
                let rawValue = String(parts[1])
                let value = rawValue.removingPercentEncoding ?? rawValue
                switch parts[0] {
                case "att":
                    attachmentID = UUID(uuidString: value)
                case "p":
                    if let page = Int(value), page >= 1 {
                        pageIndex = page - 1
                    }
                case "anchor":
                    htmlSelector = value
                case "q":
                    quotePrefix = value
                default:
                    continue
                }
            }
        }

        self.init(
            paperID: paperID,
            attachmentID: attachmentID,
            pageIndex: pageIndex,
            htmlSelector: htmlSelector,
            quotePrefix: Self.nonEmpty(title) ?? quotePrefix
        )
    }

    /// The link destination, percent-encoded down to ASCII.
    var linkDestination: String {
        var destination = "\(Self.scheme)://\(Self.host)/\(paperID.uuidString)"
        var query: [String] = []
        if let attachmentID {
            query.append("att=\(attachmentID.uuidString)")
        }
        if let pageIndex {
            query.append("p=\(pageIndex + 1)")
        }
        if let htmlSelector {
            query.append("anchor=\(Self.encoded(htmlSelector))")
        }
        if query.isEmpty == false {
            destination += "?" + query.joined(separator: "&")
        }
        return destination
    }

    /// The link title: the start of the quote.
    var linkTitle: String? {
        quotePrefix
    }

    /// Where the reader should go. `quote` is the full cited text when the link sits
    /// under its block quote; otherwise the prefix kept in the link is used.
    func navigationRequest(quote: String? = nil) -> NoteNavigationRequest {
        NoteNavigationRequest(
            paperID: paperID,
            attachmentID: attachmentID,
            pageIndex: pageIndex,
            htmlSelector: htmlSelector,
            quote: quote ?? quotePrefix
        )
    }

    /// Citations linked from `markdown`, in the order they appear.
    static func citations(in markdown: String) -> [PaperCitation] {
        let range = NSRange(markdown.startIndex..<markdown.endIndex, in: markdown)
        return citationExpression.matches(in: markdown, range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: markdown) else { return nil }
            return PaperCitation(linkDestination: String(markdown[matchRange]))
        }
    }

    /// Papers cited from `markdown`, each once, in the order of their first citation.
    static func citedPaperIDs(in markdown: String) -> [UUID] {
        var seen = Set<UUID>()
        return citations(in: markdown).compactMap { citation in
            seen.insert(citation.paperID).inserted ? citation.paperID : nil
        }
    }

    /// A block quote of `quote` followed by its citation line, inserted as its own paragraph.
    /// The empty quote line keeps the citation on its own line wherever the Markdown is rendered.
    static func quoteMarkdown(quote: String, label: String, citation: PaperCitation) -> String {
        "> \(MarkdownEscaping.escapedBlockText(quote))\n>\n> — \(inlineMarkdown(label: label, citation: citation))"
    }

    static func inlineMarkdown(label: String, citation: PaperCitation) -> String {
        var target = citation.linkDestination
        if let title = citation.linkTitle {
            target += " \"\(MarkdownEscaping.escapedLinkTitle(title))\""
        }
        return "[\(MarkdownEscaping.escapedLinkLabel(label))](\(target))"
    }

    /// A short author–year label such as "Vaswani et al., 2017, p. 2", falling back to
    /// the start of the title when the paper has no authors.
    static func label(authors: [String], title: String, year: Int?, pageIndex: Int?) -> String {
        let names = authors
            .map(familyName(of:))
            .filter { $0.isEmpty == false }
        var parts: [String] = []
        if let first = names.first {
            switch names.count {
            case 1:
                parts.append(first)
            case 2:
                parts.append("\(first) & \(names[1])")
            default:
                parts.append(first.containsCJK ? "\(first)等" : "\(first) et al.")
            }
        } else {
            let normalizedTitle = title
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { $0.isEmpty == false }
                .joined(separator: " ")
            if normalizedTitle.isEmpty == false {
                parts.append(normalizedTitle.count > 32 ? "\(normalizedTitle.prefix(32))…" : normalizedTitle)
            }
        }
        if let year {
            parts.append(String(year))
        }
        if let pageIndex {
            parts.append("p. \(pageIndex + 1)")
        }
        return parts.joined(separator: ", ")
    }

    private static func familyName(of author: String) -> String {
        let name = author.trimmingCharacters(in: .whitespacesAndNewlines)
        if let comma = name.firstIndex(of: ",") {
            return name[..<comma].trimmingCharacters(in: .whitespaces)
        }
        if name.containsCJK {
            return name.filter { $0.isWhitespace == false }
        }
        return name.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? name
    }

    private static let citationExpression = try! NSRegularExpression(
        pattern: #"readpaper://paper/[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}[^\s()<>\[\]]*"#,
        options: [.caseInsensitive]
    )

    /// Characters left as they are in link query values.
    private static let unencodedASCII = Set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:/".unicodeScalars
    )

    private static func encoded(_ value: String) -> String {
        var result = ""
        for scalar in value.unicodeScalars {
            guard unencodedASCII.contains(scalar) == false else {
                result.unicodeScalars.append(scalar)
                continue
            }
            for byte in String(scalar).utf8 {
                result += String(format: "%%%02X", byte)
            }
        }
        return result
    }

    private static func prefix(_ quote: String) -> String {
        let normalized = quote
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.isEmpty == false }
            .joined(separator: " ")
        return String(normalized.prefix(quotePrefixLength))
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.isEmpty == false else {
            return nil
        }
        return trimmed
    }
}

private extension String {
    var containsCJK: Bool {
        unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0x20000...0x2FA1F:
                return true
            default:
                return false
            }
        }
    }
}
