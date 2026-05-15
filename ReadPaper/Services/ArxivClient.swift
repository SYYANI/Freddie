import Foundation
import SwiftSoup

struct ArxivIdentifier: Equatable {
    let baseID: String
    let version: String?

    var queryID: String {
        if let version {
            return baseID + version
        }
        return baseID
    }
}

struct ArxivPaperMetadata: Equatable {
    var arxivID: String
    var arxivVersion: String?
    var title: String
    var abstractText: String
    var authors: [String]
    var categories: [String]
    var publishedAt: Date?
    var updatedAt: Date?
    var pdfURL: URL?
    var absURL: URL?
}

actor ArxivClient {
    static let shared = ArxivClient()

    private let session: URLSession
    private var lastRequestAt: Date?
    private let minimumRequestInterval: TimeInterval

    init(session: URLSession = .shared, minimumRequestInterval: TimeInterval = 3) {
        self.session = session
        self.minimumRequestInterval = minimumRequestInterval
    }

    static func normalizeIdentifier(_ rawValue: String) throws -> ArxivIdentifier {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("arxiv:") {
            value.removeFirst("arxiv:".count)
        }

        if let url = URL(string: value), let host = url.host?.lowercased(), host.contains("arxiv.org") || host.contains("ar5iv.labs.arxiv.org") {
            let components = url.pathComponents.filter { $0 != "/" }
            if let markerIndex = components.firstIndex(where: { ["abs", "pdf", "html"].contains($0) }),
               components.indices.contains(markerIndex + 1) {
                value = components[(markerIndex + 1)...].joined(separator: "/")
            } else if let last = components.last {
                value = last
            }
        }

        value = value
            .replacingOccurrences(of: ".pdf", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/ "))

        if let range = value.range(of: #"v\d+$"#, options: .regularExpression) {
            let base = String(value[..<range.lowerBound])
            let version = String(value[range])
            guard isValidBaseID(base) else {
                throw PaperImportError.invalidArxivIdentifier(rawValue)
            }
            return ArxivIdentifier(baseID: base, version: version)
        }

        guard isValidBaseID(value) else {
            throw PaperImportError.invalidArxivIdentifier(rawValue)
        }
        return ArxivIdentifier(baseID: value, version: nil)
    }

    private static func isValidBaseID(_ value: String) -> Bool {
        let modern = #"^\d{4}\.\d{4,5}$"#
        let legacy = #"^[a-zA-Z\-]+(?:\.[A-Z]{2})?/\d{7}$"#
        return value.range(of: modern, options: .regularExpression) != nil ||
            value.range(of: legacy, options: .regularExpression) != nil
    }

    func fetchMetadata(for rawValue: String) async throws -> ArxivPaperMetadata {
        let identifier = try Self.normalizeIdentifier(rawValue)
        try await waitForThrottle()

        do {
            return try await fetchMetadataFromAPI(for: rawValue, identifier: identifier)
        } catch PaperImportError.invalidArxivIdentifier(_) {
            throw PaperImportError.invalidArxivIdentifier(rawValue)
        } catch {
            do {
                return try await fetchMetadataFromAbsPage(for: rawValue, identifier: identifier)
            } catch PaperImportError.invalidArxivIdentifier(_) {
                throw PaperImportError.invalidArxivIdentifier(rawValue)
            } catch {
                if let statusError = error as? ArxivHTTPStatusError {
                    if statusError.statusCode == 404 {
                        throw PaperImportError.invalidArxivIdentifier(rawValue)
                    }
                    throw PaperImportError.arxivHTTPError(statusCode: statusError.statusCode)
                }
                throw error
            }
        }
    }

    private func fetchMetadataFromAPI(for rawValue: String, identifier: ArxivIdentifier) async throws -> ArxivPaperMetadata {
        var components = URLComponents(string: "https://export.arxiv.org/api/query")!
        components.queryItems = [
            URLQueryItem(name: "id_list", value: identifier.queryID),
            URLQueryItem(name: "start", value: "0"),
            URLQueryItem(name: "max_results", value: "1")
        ]
        let url = components.url!
        let request = Self.metadataAPIRequest(for: url)
        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response)
        let entries = try ArxivAtomParser.parse(data: data)
        guard var metadata = entries.first else {
            throw PaperImportError.invalidArxivIdentifier(rawValue)
        }
        if metadata.arxivVersion == nil {
            metadata.arxivVersion = identifier.version
        }
        if metadata.arxivID.isEmpty {
            metadata.arxivID = identifier.baseID
        }
        return metadata
    }

    private func fetchMetadataFromAbsPage(for rawValue: String, identifier: ArxivIdentifier) async throws -> ArxivPaperMetadata {
        guard let url = URL(string: "https://arxiv.org/abs/\(identifier.queryID)") else {
            throw PaperImportError.invalidArxivIdentifier(rawValue)
        }
        let request = BrowserRequestHeaders.request(for: url, accept: .document)
        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response)
        let html = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        let document = try SwiftSoup.parse(html, url.absoluteString)
        let metadata = Self.parseAbsPageMetadata(document, fallbackIdentifier: identifier, fallbackAbsURL: url)
        guard !metadata.title.isEmpty else {
            throw PaperImportError.invalidArxivIdentifier(rawValue)
        }
        return metadata
    }

    func search(query: String, maxResults: Int = 20) async throws -> [ArxivPaperMetadata] {
        try await waitForThrottle()
        var components = URLComponents(string: "https://export.arxiv.org/api/query")!
        components.queryItems = [
            URLQueryItem(name: "search_query", value: "all:\(query)"),
            URLQueryItem(name: "start", value: "0"),
            URLQueryItem(name: "max_results", value: "\(maxResults)"),
            URLQueryItem(name: "sortBy", value: "submittedDate"),
            URLQueryItem(name: "sortOrder", value: "descending")
        ]
        let request = Self.metadataAPIRequest(for: components.url!)
        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response)
        return try ArxivAtomParser.parse(data: data)
    }

    private static func metadataAPIRequest(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(BrowserRequestHeaders.chromeUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(BrowserRequestHeaders.englishAcceptLanguage, forHTTPHeaderField: "Accept-Language")
        request.setValue("application/atom+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        return request
    }

    private func waitForThrottle() async throws {
        if let lastRequestAt {
            let elapsed = Date().timeIntervalSince(lastRequestAt)
            if elapsed < minimumRequestInterval {
                try await Task.sleep(nanoseconds: UInt64((minimumRequestInterval - elapsed) * 1_000_000_000))
            }
        }
        lastRequestAt = Date()
    }

    private func validateHTTPResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw ArxivHTTPStatusError(statusCode: http.statusCode)
        }
    }

    private static func parseAbsPageMetadata(
        _ document: Document,
        fallbackIdentifier: ArxivIdentifier,
        fallbackAbsURL: URL
    ) -> ArxivPaperMetadata {
        let resolvedIdentifier = [
            metaContent(in: document, property: "og:url").flatMap { URL(string: $0)?.lastPathComponent },
            metaContent(in: document, name: "citation_arxiv_id"),
            fallbackIdentifier.queryID
        ]
            .compactMap { $0 }
            .compactMap { try? normalizeIdentifier($0) }
            .first ?? fallbackIdentifier

        let title = nonEmpty(metaContent(in: document, name: "citation_title"))
            ?? nonEmpty(metaContent(in: document, property: "og:title"))
            ?? cleanDocumentTitle((try? document.title()) ?? "", identifier: resolvedIdentifier)
        let abstractText = extractAbstract(from: document)
            ?? nonEmpty(metaContent(in: document, name: "citation_abstract"))
            ?? nonEmpty(metaContent(in: document, property: "og:description"))
            ?? ""
        let authors = metaContents(in: document, name: "citation_author")
        let categoryText = firstText(in: document, selector: "td.subjects") ?? ""
        let categories = unique(extractCategoryCodes(from: categoryText))
        let publishedAt = parseArxivDate(metaContent(in: document, name: "citation_date"))
        let canonicalURL = firstAttribute(in: document, selector: "link[rel=canonical]", attribute: "href")
            .flatMap(URL.init(string:))
        let pdfURL = metaContent(in: document, name: "citation_pdf_url")
            .flatMap(URL.init(string:))
            ?? URL(string: "https://arxiv.org/pdf/\(resolvedIdentifier.queryID)")

        return ArxivPaperMetadata(
            arxivID: resolvedIdentifier.baseID,
            arxivVersion: resolvedIdentifier.version ?? fallbackIdentifier.version,
            title: title,
            abstractText: abstractText,
            authors: authors,
            categories: categories,
            publishedAt: publishedAt,
            updatedAt: nil,
            pdfURL: pdfURL,
            absURL: canonicalURL ?? fallbackAbsURL
        )
    }

    private static func metaContent(in document: Document, name: String) -> String? {
        firstAttribute(in: document, selector: "meta[name=\(name)]", attribute: "content")
    }

    private static func metaContents(in document: Document, name: String) -> [String] {
        elements(in: document, selector: "meta[name=\(name)]")
            .compactMap { try? $0.attr("content") }
            .compactMap(nonEmpty)
    }

    private static func metaContent(in document: Document, property: String) -> String? {
        firstAttribute(in: document, selector: "meta[property='\(property)']", attribute: "content")
    }

    private static func firstAttribute(in document: Document, selector: String, attribute: String) -> String? {
        guard let element = firstElement(in: document, selector: selector),
              let value = try? element.attr(attribute) else {
            return nil
        }
        return nonEmpty(value)
    }

    private static func firstText(in document: Document, selector: String) -> String? {
        guard let element = firstElement(in: document, selector: selector),
              let text = try? element.text() else {
            return nil
        }
        return nonEmpty(text)
    }

    private static func firstElement(in document: Document, selector: String) -> Element? {
        guard let elements = try? document.select(selector) else { return nil }
        return elements.first()
    }

    private static func elements(in document: Document, selector: String) -> [Element] {
        guard let elements = try? document.select(selector) else { return [] }
        return elements.array()
    }

    private static func extractAbstract(from document: Document) -> String? {
        guard let text = firstText(in: document, selector: "blockquote.abstract, .abstract") else {
            return nil
        }
        return nonEmpty(
            text.replacingOccurrences(
                of: #"(?i)^abstract:\s*"#,
                with: "",
                options: .regularExpression
            )
        )
    }

    private static func extractCategoryCodes(from text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"\(([a-z-]+(?:\.[A-Za-z-]+)?)\)"#) else {
            return []
        }
        return regex
            .matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { match in
                guard let range = Range(match.range(at: 1), in: text) else { return nil }
                return String(text[range])
            }
    }

    private static func cleanDocumentTitle(_ title: String, identifier: ArxivIdentifier) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return nonEmpty(
            trimmed.replacingOccurrences(
                of: #"^\[[^\]]+\]\s*"#,
                with: "",
                options: .regularExpression
            )
        ) ?? identifier.baseID
    }

    private static func parseArxivDate(_ value: String?) -> Date? {
        guard let value = nonEmpty(value) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy/MM/dd"
        return formatter.date(from: value)
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

private struct ArxivHTTPStatusError: Error {
    let statusCode: Int
}

final class ArxivAtomParser: NSObject, XMLParserDelegate {
    private var entries: [ArxivPaperMetadata] = []
    private var currentEntry: ArxivPaperMetadata?
    private var currentElementStack: [String] = []
    private var currentText = ""
    private var currentAuthorName = ""
    private let iso8601 = ISO8601DateFormatter()

    static func parse(data: Data) throws -> [ArxivPaperMetadata] {
        let delegate = ArxivAtomParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw parser.parserError ?? URLError(.cannotParseResponse)
        }
        return delegate.entries
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElementStack.append(elementName)
        currentText = ""

        if elementName == "entry" {
            currentEntry = ArxivPaperMetadata(
                arxivID: "",
                arxivVersion: nil,
                title: "",
                abstractText: "",
                authors: [],
                categories: [],
                publishedAt: nil,
                updatedAt: nil,
                pdfURL: nil,
                absURL: nil
            )
        }

        guard currentEntry != nil else { return }

        if elementName == "link", let href = attributeDict["href"], let url = URL(string: href) {
            if attributeDict["title"] == "pdf" || attributeDict["type"] == "application/pdf" {
                currentEntry?.pdfURL = url
            } else if attributeDict["rel"] == "alternate" {
                currentEntry?.absURL = url
            }
        }

        if elementName == "category", let term = attributeDict["term"], !(currentEntry?.categories.contains(term) ?? false) {
            currentEntry?.categories.append(term)
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        defer {
            _ = currentElementStack.popLast()
            currentText = ""
        }

        guard currentEntry != nil else { return }
        let text = currentText.normalizedArxivWhitespace

        switch elementName {
        case "entry":
            if let entry = currentEntry {
                entries.append(entry)
            }
            currentEntry = nil
        case "id":
            guard isInsideEntry else { return }
            currentEntry?.arxivID = Self.extractID(from: text).baseID
            currentEntry?.arxivVersion = Self.extractID(from: text).version
        case "title":
            guard isInsideEntry else { return }
            currentEntry?.title = text
        case "summary":
            currentEntry?.abstractText = text
        case "published":
            currentEntry?.publishedAt = iso8601.date(from: text)
        case "updated":
            guard isInsideEntry else { return }
            currentEntry?.updatedAt = iso8601.date(from: text)
        case "name":
            if currentElementStack.contains("author"), !text.isEmpty {
                currentAuthorName = text
                currentEntry?.authors.append(text)
            }
        default:
            break
        }
    }

    private var isInsideEntry: Bool {
        currentElementStack.contains("entry")
    }

    private static func extractID(from text: String) -> ArxivIdentifier {
        let last = URL(string: text)?.lastPathComponent ?? text
        return (try? ArxivClient.normalizeIdentifier(last)) ?? ArxivIdentifier(baseID: last, version: nil)
    }
}

private extension String {
    var normalizedArxivWhitespace: String {
        components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
