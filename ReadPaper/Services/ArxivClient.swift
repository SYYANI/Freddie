import Foundation

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

        var components = URLComponents(string: "https://export.arxiv.org/api/query")!
        components.queryItems = [
            URLQueryItem(name: "id_list", value: identifier.queryID),
            URLQueryItem(name: "start", value: "0"),
            URLQueryItem(name: "max_results", value: "1")
        ]
        let url = components.url!
        let (data, response) = try await session.data(from: url)
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
        let (data, response) = try await session.data(from: components.url!)
        try validateHTTPResponse(response)
        return try ArxivAtomParser.parse(data: data)
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
            throw URLError(.badServerResponse)
        }
    }
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
