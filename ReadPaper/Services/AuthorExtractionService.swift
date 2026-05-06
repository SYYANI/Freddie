import Foundation
import OSLog
import SwiftData
import SwiftSoup

@MainActor
struct AuthorExtractionService {
    struct LocalHTMLContext: Equatable {
        var metaAuthors: [String]
        var bylines: [String]
        var textSnippet: String?

        var isEmpty: Bool {
            metaAuthors.isEmpty && bylines.isEmpty && textSnippet == nil
        }
    }

    let provider: OpenAICompatibleLLMProvider

    init(provider: OpenAICompatibleLLMProvider = OpenAICompatibleLLMProvider()) {
        self.provider = provider
    }

    nonisolated private static let logger = Logger(
        subsystem: "com.yiyan.ReadPaper",
        category: "AuthorExtraction"
    )

    static func extractAuthorsIfNeeded(
        for paper: Paper,
        modelContext: ModelContext
    ) {
        guard paper.authors.isEmpty else { return }
        guard !paper.title.isEmpty else { return }

        let paperID = paper.id
        let title = paper.title
        let abstract = paper.abstractText
        let htmlURLString = paper.htmlURLString

        logger.info("Starting author extraction for \"\(title, privacy: .public)\"")

        Task {
            let service = AuthorExtractionService()
            do {
                try await service.extractAndAssign(
                    paperID: paperID,
                    title: title,
                    abstract: abstract,
                    htmlURLString: htmlURLString,
                    modelContext: modelContext
                )
            } catch let error as LLMRouteError {
                logger.error("Author extraction LLM route error: \(error.localizedDescription, privacy: .public)")
            } catch {
                logger.error("Author extraction failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    @discardableResult
    func extractAndAssign(
        paperID: UUID,
        title: String,
        abstract: String,
        htmlURLString: String?,
        modelContext: ModelContext
    ) async throws -> Bool {
        guard let paper = try Self.fetchPaper(id: paperID, modelContext: modelContext) else {
            Self.logger.error("Paper \(paperID.uuidString, privacy: .public) not found in context")
            return false
        }
        guard paper.authors.isEmpty else { return false }

        let currentTitle = paper.title.isEmpty ? title : paper.title
        let currentAbstract = paper.abstractText.isEmpty ? abstract : paper.abstractText
        let currentHTMLURLString = paper.htmlURLString ?? htmlURLString
        let localHTMLContext = Self.loadLocalHTMLContext(
            for: paperID,
            modelContext: modelContext
        )

        let highConfidenceAuthors = Self.highConfidenceAuthors(from: localHTMLContext)
        if !highConfidenceAuthors.isEmpty {
            try Self.assign(highConfidenceAuthors, to: paper, modelContext: modelContext)
            Self.logger.info("Author extraction used local HTML metadata for \"\(paper.title, privacy: .public)\": \(highConfidenceAuthors.joined(separator: ", "), privacy: .public)")
            return true
        }

        let settings = try modelContext.fetch(FetchDescriptor<AppSettings>()).first ?? AppSettings()

        let route = try LLMRouteResolver().resolveHTMLRoute(
            settings: settings,
            modelContext: modelContext
        )

        let userContent = Self.buildUserContent(
            title: currentTitle,
            abstract: currentAbstract,
            htmlURLString: currentHTMLURLString,
            localHTMLContext: localHTMLContext
        )

        guard let baseURL = URL(string: route.snapshot.baseURL) else { return false }

        let response = try await provider.complete(request: LLMCompletionRequest(
            baseURL: baseURL,
            apiKey: route.apiKey,
            model: route.snapshot.modelName,
            messages: [
                LLMCompletionMessage(role: "system", content: Self.authorExtractionPrompt),
                LLMCompletionMessage(role: "user", content: userContent)
            ],
            temperature: 0.1,
            topP: nil,
            maxTokens: 200,
            timeoutProfile: .translationDefault
        ))

        let authors = Self.parseAuthors(from: response.text)
        guard !authors.isEmpty else {
            Self.logger.warning("LLM response produced no authors for \"\(currentTitle, privacy: .public)\". Response: \"\(response.text, privacy: .public)\"")
            return false
        }
        try Self.assign(authors, to: paper, modelContext: modelContext)
        Self.logger.info("Author extraction succeeded for \"\(paper.title, privacy: .public)\": \(authors.joined(separator: ", "), privacy: .public)")
        return true
    }

    static func buildUserContent(
        title: String,
        abstract: String,
        htmlURLString: String?,
        localHTMLContext: LocalHTMLContext? = nil
    ) -> String {
        var parts: [String] = ["Title: \(title)"]

        if !abstract.isEmpty {
            let truncated = String(abstract.prefix(200))
            parts.append("Abstract (first 200 chars): \(truncated)")
        }

        if let localHTMLContext, !localHTMLContext.metaAuthors.isEmpty {
            parts.append("Local HTML author metadata:\n\(localHTMLContext.metaAuthors.joined(separator: "\n"))")
        }

        if let localHTMLContext, !localHTMLContext.bylines.isEmpty {
            parts.append("Local HTML byline candidates:\n\(localHTMLContext.bylines.joined(separator: "\n"))")
        }

        if let textSnippet = localHTMLContext?.textSnippet, !textSnippet.isEmpty {
            parts.append("Local HTML visible text excerpt:\n\(textSnippet)")
        }

        if let urlString = htmlURLString, !urlString.isEmpty {
            parts.append("Source URL: \(urlString)")
        }

        return parts.joined(separator: "\n")
    }

    static let authorExtractionPrompt = """
    You are an academic metadata extraction assistant. \
    Given a paper's metadata and local HTML evidence, identify the author names. \
    Treat source URLs as metadata only; do not assume you can browse them. \
    Prefer explicit author metadata or bylines over title guesses. \
    Return only the author names, one per line. \
    Do not include affiliations, numbering, prefixes, or any other text. \
    If no authors can be identified, return an empty response.
    """

    static func extractLocalHTMLContext(from html: String, maxTextSnippetLength: Int = 1200) throws -> LocalHTMLContext {
        let document = try SwiftSoup.parse(html)
        var metaAuthors: [String] = []
        var bylines: [String] = []

        for selector in [
            "meta[name=author]",
            "meta[property=author]",
            "meta[property=article:author]",
            "meta[name=citation_author]",
            "meta[name=dc.creator]",
            "meta[name=twitter:creator]"
        ] {
            for element in try document.select(selector).array() {
                appendUnique(try element.attr("content"), to: &metaAuthors)
            }
        }

        for selector in [
            ".rp-readability-byline",
            "[rel=author]",
            ".byline",
            "[class*=byline]",
            "[itemprop=author]",
            "[class*=author]"
        ] {
            for element in try document.select(selector).array() {
                appendUnique(try element.text(), to: &bylines)
            }
        }

        let visibleText: String
        if let body = document.body() {
            visibleText = try body.text()
        } else {
            visibleText = try document.text()
        }
        let normalizedVisibleText = normalizeWhitespace(visibleText)
        let textSnippet = normalizedVisibleText.isEmpty
            ? nil
            : String(normalizedVisibleText.prefix(max(0, maxTextSnippetLength)))

        return LocalHTMLContext(
            metaAuthors: metaAuthors,
            bylines: bylines,
            textSnippet: textSnippet
        )
    }

    static func parseAuthors(from text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let lines = trimmed
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { line in
                let lower = line.lowercased()
                return !lower.hasPrefix("author")
                    && !lower.hasPrefix("title")
                    && !lower.hasPrefix("abstract")
                    && lower != "n/a"
                    && lower != "none"
                    && lower != "unknown"
            }

        var authors: [String] = []
        for line in lines {
            let cleaned = Self.cleanAuthorLine(line)
            authors.append(contentsOf: cleaned)
        }
        return authors
    }

    private static func cleanAuthorLine(_ line: String) -> [String] {
        var text = line

        let byPrefixes = [#"^[Bb]y\s+"#]
        for pattern in byPrefixes {
            if let range = text.range(of: pattern, options: .regularExpression) {
                text = String(text[range.upperBound...])
                break
            }
        }

        let candidates = text
            .replacingOccurrences(of: #",\s*and\s+"#, with: "|||", options: .regularExpression)
            .replacingOccurrences(of: #"\s+and\s+"#, with: "|||", options: .regularExpression)
            .replacingOccurrences(of: #"\s*&\s*"#, with: "|||", options: .regularExpression)
            .components(separatedBy: "|||")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return candidates.map { candidate in
            if candidate.contains(",") {
                return String(candidate.split(separator: ",")[0])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return candidate
        }
        .filter { !$0.isEmpty }
        .filter { candidate in
            let lower = candidate.lowercased()
            let noisePatterns = [#"^[Bb]y\s"#, #"^[Aa]uthor"#, #"^[Tt]itle"#, #"^[Aa]bstract"#]
            for pattern in noisePatterns {
                if lower.range(of: pattern, options: .regularExpression) != nil {
                    return false
                }
            }
            return lower != "n/a" && lower != "none" && lower != "unknown"
        }
    }

    private static func fetchPaper(id paperID: UUID, modelContext: ModelContext) throws -> Paper? {
        let descriptor = FetchDescriptor<Paper>(
            predicate: #Predicate<Paper> { $0.id == paperID }
        )
        return try modelContext.fetch(descriptor).first
    }

    private static func loadLocalHTMLContext(
        for paperID: UUID,
        modelContext: ModelContext
    ) -> LocalHTMLContext? {
        let descriptor = FetchDescriptor<PaperAttachment>(
            predicate: #Predicate<PaperAttachment> { $0.paperID == paperID }
        )
        do {
            let htmlAttachment = try modelContext.fetch(descriptor)
                .first { $0.kind == .html }
            guard let htmlAttachment else { return nil }
            let html = try String(contentsOf: htmlAttachment.fileURL, encoding: .utf8)
            let context = try extractLocalHTMLContext(from: html)
            return context.isEmpty ? nil : context
        } catch {
            logger.debug("Unable to load local HTML for author extraction: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func highConfidenceAuthors(from context: LocalHTMLContext?) -> [String] {
        guard let context else { return [] }
        return uniqueAuthors(
            (context.metaAuthors + context.bylines)
                .flatMap { parseAuthors(from: $0) }
        )
    }

    private static func assign(
        _ authors: [String],
        to paper: Paper,
        modelContext: ModelContext
    ) throws {
        paper.authors = uniqueAuthors(authors)
        paper.modifiedAt = Date()
        try modelContext.save()
    }

    private static func uniqueAuthors(_ authors: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for author in authors {
            let normalized = normalizeWhitespace(author)
            guard !normalized.isEmpty else { continue }
            let key = normalized.lowercased()
            guard seen.insert(key).inserted else { continue }
            result.append(normalized)
        }
        return result
    }

    private static func appendUnique(_ value: String, to values: inout [String]) {
        let normalized = normalizeWhitespace(value)
        guard !normalized.isEmpty else { return }
        guard !values.contains(where: { $0.localizedCaseInsensitiveCompare(normalized) == .orderedSame }) else {
            return
        }
        values.append(normalized)
    }

    private static func normalizeWhitespace(_ value: String) -> String {
        value
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
