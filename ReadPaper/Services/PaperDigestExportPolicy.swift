import Foundation

struct PaperDigestContent: Equatable {
    var title: String
    var authors: String
    var sourceTitle: String?
    var sourceURL: URL?
    var identifier: String?
    var abstract: String?
    var notes: [PaperDigestNote]
    var exportDate: Date
}

struct PaperDigestNote: Equatable {
    var body: String
    var quote: String?
    var pageIndex: Int?
    var modifiedAt: Date
}

enum PaperDigestExportPolicy {
    static let defaultMarkdownTemplate = """
    +++
    date = '{{dateISO}}'
    draft = false
    title = '{{title}}'
    slug = '{{slug}}'
    +++

    # {{title}}

    {{metadataBlock}}

    {{abstractBlock}}

    {{notesBlock}}

    *{{generatedBy}}*
    """

    static let templatePlaceholderTokens = [
        "{{dateISO}}",
        "{{title}}",
        "{{slug}}",
        "{{authors}}",
        "{{identifier}}",
        "{{sourceTitle}}",
        "{{sourceURL}}",
        "{{metadataBlock}}",
        "{{abstractBlock}}",
        "{{notesBlock}}",
        "{{generatedBy}}"
    ]

    private static let fallbackSlug = "paper-digest"
    private static let maxSlugLength = 90

    static func makeContent(
        paper: Paper,
        notes: [Note],
        exportDate: Date = Date()
    ) -> PaperDigestContent? {
        let title = normalizeRequiredText(paper.title)
        guard title.isEmpty == false else { return nil }

        let normalizedNotes = notes
            .compactMap { note -> PaperDigestNote? in
                let body = normalizeRequiredText(note.body)
                guard body.isEmpty == false else { return nil }
                let quote = normalizeOptionalText(note.quote)
                return PaperDigestNote(
                    body: body,
                    quote: quote,
                    pageIndex: note.pageIndex,
                    modifiedAt: note.modifiedAt
                )
            }
            .sorted { lhs, rhs in
                if lhs.modifiedAt != rhs.modifiedAt {
                    return lhs.modifiedAt < rhs.modifiedAt
                }
                return lhs.body.localizedStandardCompare(rhs.body) == .orderedAscending
            }

        let source = sourceMetadata(for: paper)
        return PaperDigestContent(
            title: title,
            authors: normalizeRequiredText(paper.displayAuthors),
            sourceTitle: source.title,
            sourceURL: source.url,
            identifier: normalizeOptionalText(paper.metadataIdentifierText),
            abstract: normalizeOptionalText(paper.abstractText),
            notes: normalizedNotes,
            exportDate: exportDate
        )
    }

    static func makeMarkdown(
        content: PaperDigestContent,
        bundle: Bundle
    ) -> String {
        makeMarkdown(content: content, bundle: bundle, template: nil)
    }

    static func makeMarkdown(
        content: PaperDigestContent,
        bundle: Bundle,
        template: String?
    ) -> String {
        guard let template = normalizedTemplate(template) else {
            return makeDefaultMarkdown(content: content, bundle: bundle)
        }

        if template == defaultMarkdownTemplate {
            return makeDefaultMarkdown(content: content, bundle: bundle)
        }

        return normalizeMarkdownLayout(renderTemplate(template, content: content, bundle: bundle))
    }

    private static func makeDefaultMarkdown(
        content: PaperDigestContent,
        bundle: Bundle
    ) -> String {
        var lines: [String] = [
            "+++",
            "date = '\(iso8601String(from: content.exportDate))'",
            "draft = false",
            "title = '\(tomlEscaped(content.title))'",
            "slug = '\(makeFileSlug(title: content.title))'",
            "+++",
            "",
            "# \(content.title)",
            ""
        ]

        if let sourceTitle = content.sourceTitle, let sourceURL = content.sourceURL {
            lines.append("**\(String(localized: "Source", bundle: bundle))**: [\(sourceTitle)](\(sourceURL.absoluteString))")
        }

        if content.authors.isEmpty == false {
            lines.append("**\(String(localized: "Authors", bundle: bundle))**: \(content.authors)")
        }

        if let identifier = content.identifier {
            lines.append("**\(String(localized: "Identifier", bundle: bundle))**: \(identifier)")
        }

        if lines.last?.isEmpty == false {
            lines.append("")
        }

        if let abstract = content.abstract {
            lines.append("## \(String(localized: "Abstract", bundle: bundle))")
            lines.append("")
            lines.append(blockquoteBody(abstract))
            lines.append("")
        }

        if content.notes.isEmpty == false {
            lines.append("## \(String(localized: "Notes", bundle: bundle))")
            lines.append("")

            for note in content.notes {
                lines.append("### \(note.modifiedAt.formatted(date: .abbreviated, time: .shortened))")
                if let pageIndex = note.pageIndex {
                    lines.append("")
                    lines.append("**\(String(localized: "Page", bundle: bundle))**: \(pageIndex + 1)")
                }
                if let quote = note.quote {
                    lines.append("")
                    lines.append(blockquoteBody(quote))
                }
                lines.append("")
                lines.append(note.body)
                lines.append("")
            }
        }

        lines.append("*\(String(localized: "Generated by Freddie", bundle: bundle))*")
        return normalizeMarkdownLayout(lines.joined(separator: "\n"))
    }

    static func makeShareText(
        content: PaperDigestContent,
        bundle: Bundle
    ) -> String {
        var parts = [content.title]
        if content.authors.isEmpty == false {
            parts.append(String(format: String(localized: "by %@", bundle: bundle), content.authors))
        }
        if let sourceURL = content.sourceURL {
            parts.append(sourceURL.absoluteString)
        }
        if content.notes.isEmpty == false {
            let noteText = content.notes.map(\.body).joined(separator: "\n\n")
            parts.append(noteText)
        }
        return parts.joined(separator: "\n\n")
    }

    static func makeFileName(title: String, exportDate: Date = Date()) -> String {
        "\(fileDateString(from: exportDate))-\(makeFileSlug(title: title)).md"
    }

    static func uniqueExportFileURL(
        directoryURL: URL,
        preferredFileName: String,
        fileManager: FileManager = .default
    ) -> URL {
        let baseURL = directoryURL.appendingPathComponent(preferredFileName, isDirectory: false)
        guard fileManager.fileExists(atPath: baseURL.path) else { return baseURL }

        let fileExtension = baseURL.pathExtension
        let baseName = fileExtension.isEmpty
            ? baseURL.lastPathComponent
            : baseURL.deletingPathExtension().lastPathComponent

        var suffix = 2
        while true {
            let candidateName = fileExtension.isEmpty
                ? "\(baseName)-\(suffix)"
                : "\(baseName)-\(suffix).\(fileExtension)"
            let candidate = directoryURL.appendingPathComponent(candidateName, isDirectory: false)
            if fileManager.fileExists(atPath: candidate.path) == false {
                return candidate
            }
            suffix += 1
        }
    }

    static func makeFileSlug(title: String) -> String {
        let normalized = normalizeRequiredText(title)
        guard normalized.isEmpty == false else { return fallbackSlug }

        var scalars: [UnicodeScalar] = []
        var previousWasHyphen = false

        for scalar in normalized.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if scalar.isASCII {
                    scalars.append(UnicodeScalar(String(scalar).lowercased()) ?? scalar)
                } else {
                    scalars.append(scalar)
                }
                previousWasHyphen = false
                continue
            }

            if CharacterSet.whitespacesAndNewlines.contains(scalar) || "-_/+:.|".unicodeScalars.contains(scalar) {
                if previousWasHyphen == false, scalars.isEmpty == false {
                    scalars.append("-")
                    previousWasHyphen = true
                }
            }
        }

        var slug = String(String.UnicodeScalarView(scalars))
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if slug.count > maxSlugLength {
            slug = String(slug.prefix(maxSlugLength)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        }
        return slug.isEmpty ? fallbackSlug : slug
    }

    static func normalizeMarkdownLayout(_ markdown: String) -> String {
        let normalizedNewlines = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        guard let regex = try? NSRegularExpression(pattern: "\n[ \t]*\n(?:[ \t]*\n)+") else {
            return normalizedNewlines.trimmingCharacters(in: .newlines)
        }
        let range = NSRange(normalizedNewlines.startIndex..<normalizedNewlines.endIndex, in: normalizedNewlines)
        let collapsed = regex.stringByReplacingMatches(
            in: normalizedNewlines,
            options: [],
            range: range,
            withTemplate: "\n\n"
        )
        return collapsed.trimmingCharacters(in: .newlines)
    }

    private static func normalizedTemplate(_ template: String?) -> String? {
        guard let template else { return nil }
        return template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : template
    }

    private static func renderTemplate(
        _ template: String,
        content: PaperDigestContent,
        bundle: Bundle
    ) -> String {
        let values: [String: String] = [
            "{{dateISO}}": iso8601String(from: content.exportDate),
            "{{title}}": content.title,
            "{{slug}}": makeFileSlug(title: content.title),
            "{{authors}}": content.authors,
            "{{identifier}}": content.identifier ?? "",
            "{{sourceTitle}}": content.sourceTitle ?? "",
            "{{sourceURL}}": content.sourceURL?.absoluteString ?? "",
            "{{metadataBlock}}": metadataMarkdownBlock(content: content, bundle: bundle),
            "{{abstractBlock}}": abstractMarkdownBlock(content: content, bundle: bundle),
            "{{notesBlock}}": notesMarkdownBlock(content: content, bundle: bundle),
            "{{generatedBy}}": String(localized: "Generated by Freddie", bundle: bundle)
        ]

        return values.reduce(template) { partial, item in
            partial.replacingOccurrences(of: item.key, with: item.value)
        }
    }

    private static func metadataMarkdownBlock(
        content: PaperDigestContent,
        bundle: Bundle
    ) -> String {
        var lines: [String] = []

        if let sourceTitle = content.sourceTitle, let sourceURL = content.sourceURL {
            lines.append("**\(String(localized: "Source", bundle: bundle))**: [\(sourceTitle)](\(sourceURL.absoluteString))")
        }

        if content.authors.isEmpty == false {
            lines.append("**\(String(localized: "Authors", bundle: bundle))**: \(content.authors)")
        }

        if let identifier = content.identifier {
            lines.append("**\(String(localized: "Identifier", bundle: bundle))**: \(identifier)")
        }

        return lines.joined(separator: "\n")
    }

    private static func abstractMarkdownBlock(
        content: PaperDigestContent,
        bundle: Bundle
    ) -> String {
        guard let abstract = content.abstract else { return "" }
        return [
            "## \(String(localized: "Abstract", bundle: bundle))",
            "",
            blockquoteBody(abstract)
        ].joined(separator: "\n")
    }

    private static func notesMarkdownBlock(
        content: PaperDigestContent,
        bundle: Bundle
    ) -> String {
        guard content.notes.isEmpty == false else { return "" }

        var lines: [String] = [
            "## \(String(localized: "Notes", bundle: bundle))",
            ""
        ]

        for note in content.notes {
            lines.append("### \(note.modifiedAt.formatted(date: .abbreviated, time: .shortened))")
            if let pageIndex = note.pageIndex {
                lines.append("")
                lines.append("**\(String(localized: "Page", bundle: bundle))**: \(pageIndex + 1)")
            }
            if let quote = note.quote {
                lines.append("")
                lines.append(blockquoteBody(quote))
            }
            lines.append("")
            lines.append(note.body)
            lines.append("")
        }

        return normalizeMarkdownLayout(lines.joined(separator: "\n"))
    }

    private static func sourceMetadata(for paper: Paper) -> (title: String?, url: URL?) {
        if let arxivID = normalizeOptionalText(paper.arxivID),
           let url = URL(string: "https://arxiv.org/abs/\(arxivID)") {
            return ("arXiv \(arxivID)", url)
        }

        if let doi = normalizeOptionalText(paper.doi),
           let url = URL(string: "https://doi.org/\(doi)") {
            return ("DOI \(doi)", url)
        }

        if let htmlURLString = normalizeOptionalText(paper.htmlURLString),
           let url = URL(string: htmlURLString) {
            return (url.absoluteString, url)
        }

        if let pdfURLString = normalizeOptionalText(paper.pdfURLString),
           let url = URL(string: pdfURLString) {
            return (url.absoluteString, url)
        }

        return (nil, nil)
    }

    private static func fileDateString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func blockquoteBody(_ text: String) -> String {
        text
            .components(separatedBy: .newlines)
            .map { "> \($0.trimmingCharacters(in: .whitespaces))" }
            .joined(separator: "\n")
    }

    private static func tomlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
    }

    private static func normalizeRequiredText(_ text: String?) -> String {
        (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizeOptionalText(_ text: String?) -> String? {
        let normalized = normalizeRequiredText(text)
        return normalized.isEmpty ? nil : normalized
    }
}

struct PaperDigestExportConfiguration {
    static let templateKey = "ReadPaper.DigestExport.Template"
    static let directoryBookmarkKey = "ReadPaper.DigestExport.DirectoryBookmark"
    static let directoryDisplayPathKey = "ReadPaper.DigestExport.DirectoryDisplayPath"

    var userDefaults: UserDefaults = .standard
    var fileManager: FileManager = .default

    var template: String {
        let storedTemplate = userDefaults.string(forKey: Self.templateKey)
        return storedTemplate?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? storedTemplate ?? PaperDigestExportPolicy.defaultMarkdownTemplate
            : PaperDigestExportPolicy.defaultMarkdownTemplate
    }

    var directoryDisplayPath: String? {
        let path = userDefaults.string(forKey: Self.directoryDisplayPathKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return path.isEmpty ? nil : path
    }

    func saveExportDirectory(_ url: URL) throws {
        let bookmark = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        userDefaults.set(bookmark, forKey: Self.directoryBookmarkKey)
        userDefaults.set(url.path, forKey: Self.directoryDisplayPathKey)
    }

    func clearExportDirectory() {
        userDefaults.removeObject(forKey: Self.directoryBookmarkKey)
        userDefaults.removeObject(forKey: Self.directoryDisplayPathKey)
    }

    func resolveExportDirectory() throws -> URL {
        guard let bookmarkData = userDefaults.data(forKey: Self.directoryBookmarkKey) else {
            throw PaperDigestExportError.missingExportDirectory
        }

        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )

            if isStale {
                try saveExportDirectory(url)
            }

            try validateDirectory(url)
            return url
        } catch let error as PaperDigestExportError {
            throw error
        } catch {
            throw PaperDigestExportError.exportDirectoryUnavailable(directoryDisplayPath ?? "")
        }
    }

    private func validateDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw PaperDigestExportError.exportDirectoryUnavailable(url.path)
        }
    }
}

struct PaperDigestExporter {
    var configuration: PaperDigestExportConfiguration = PaperDigestExportConfiguration()
    var fileManager: FileManager = .default

    func export(
        content: PaperDigestContent,
        bundle: Bundle
    ) throws -> URL {
        let directory = try configuration.resolveExportDirectory()
        let didAccess = directory.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                directory.stopAccessingSecurityScopedResource()
            }
        }

        let fileName = PaperDigestExportPolicy.makeFileName(
            title: content.title,
            exportDate: content.exportDate
        )
        let targetURL = PaperDigestExportPolicy.uniqueExportFileURL(
            directoryURL: directory,
            preferredFileName: fileName,
            fileManager: fileManager
        )
        let markdown = PaperDigestExportPolicy.makeMarkdown(
            content: content,
            bundle: bundle,
            template: configuration.template
        )
        try markdown.write(to: targetURL, atomically: true, encoding: .utf8)
        return targetURL
    }
}

enum PaperDigestExportError: LocalizedError, Equatable {
    case missingExportDirectory
    case exportDirectoryUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .missingExportDirectory:
            return AppLocalization.localized("Set an export directory in Settings > Digest before exporting Markdown.")
        case .exportDirectoryUnavailable(let path):
            guard path.isEmpty == false else {
                return AppLocalization.localized("The configured export directory is unavailable.")
            }
            return AppLocalization.format("The configured export directory is unavailable: %@", path)
        }
    }
}
