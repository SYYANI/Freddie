import Foundation
import SwiftSoup

struct SelectionAssistantPaperContext: Equatable, Sendable {
    var id: UUID
    var title: String
    var abstractText: String
    var authors: [String]
    var arxivID: String?
    var arxivVersion: String?
    var doi: String?
}

struct SelectionAssistantExternalSearchResult: Equatable, Sendable {
    var sources: [AssistantSource]
    var warnings: [String]
}

protocol SelectionAssistantExternalSearching: Sendable {
    func search(
        query: String,
        paper: SelectionAssistantPaperContext,
        limit: Int
    ) async -> SelectionAssistantExternalSearchResult
}

actor SelectionAssistantExternalSearchService: SelectionAssistantExternalSearching {
    static let shared = SelectionAssistantExternalSearchService()

    private struct CacheEntry {
        var result: SelectionAssistantExternalSearchResult
        var expiresAt: Date
    }

    private let session: URLSession
    private let arxivClient: ArxivClient
    private var cache: [String: CacheEntry] = [:]

    init(
        session: URLSession = .shared,
        arxivClient: ArxivClient = .shared
    ) {
        self.session = session
        self.arxivClient = arxivClient
    }

    func search(
        query: String,
        paper: SelectionAssistantPaperContext,
        limit: Int = 6
    ) async -> SelectionAssistantExternalSearchResult {
        let normalizedLimit = max(1, min(limit, 10))
        let cacheKey = "\(paper.id.uuidString)|\(paper.doi ?? "")|\(paper.arxivID ?? "")|\(query.lowercased())|\(normalizedLimit)"
        if let cached = cache[cacheKey], cached.expiresAt > Date() {
            return cached.result
        }

        var sources: [AssistantSource] = []
        var warnings: [String] = []

        if let doi = paper.doi, doi.isEmpty == false {
            do {
                if let source = try await fetchCrossref(doi: doi) {
                    sources.append(source)
                }
            } catch {
                warnings.append(AppLocalization.format("Crossref lookup failed: %@", error.localizedDescription))
            }

            do {
                if let source = try await fetchOpenAlex(doi: doi) {
                    sources.append(source)
                }
            } catch {
                warnings.append(AppLocalization.format("OpenAlex lookup failed: %@", error.localizedDescription))
            }
        }

        let normalizedQuery = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240))
        if normalizedQuery.isEmpty == false {
            do {
                let remaining = max(1, normalizedLimit - sources.count)
                sources.append(contentsOf: try await searchSemanticScholar(
                    query: normalizedQuery,
                    currentTitle: paper.title,
                    limit: min(3, remaining)
                ))
            } catch {
                warnings.append(AppLocalization.format("Semantic Scholar search failed: %@", error.localizedDescription))
            }

            do {
                let remaining = max(1, normalizedLimit - sources.count)
                let matches = try await arxivClient.search(query: normalizedQuery, maxResults: min(2, remaining))
                sources.append(contentsOf: matches.compactMap { metadata in
                    guard metadata.arxivID != paper.arxivID else { return nil }
                    let version = metadata.arxivVersion.map { "\($0)" } ?? ""
                    let identifier = version.isEmpty ? metadata.arxivID : metadata.arxivID + version
                    return AssistantSource(
                        id: "external-arxiv-\(identifier)",
                        kind: .external,
                        title: metadata.title,
                        excerpt: metadata.abstractText,
                        urlString: metadata.absURL?.absoluteString ?? "https://arxiv.org/abs/\(identifier)"
                    )
                })
            } catch {
                warnings.append(AppLocalization.format("arXiv search failed: %@", error.localizedDescription))
            }
        }

        var seen: Set<String> = []
        let uniqueSources = sources.filter { source in
            let identity = (source.urlString ?? source.title).lowercased()
            return seen.insert(identity).inserted
        }
        let result = SelectionAssistantExternalSearchResult(
            sources: Array(uniqueSources.prefix(normalizedLimit)),
            warnings: warnings
        )
        cache[cacheKey] = CacheEntry(result: result, expiresAt: Date().addingTimeInterval(15 * 60))
        return result
    }

    private func fetchCrossref(doi: String) async throws -> AssistantSource? {
        guard var components = URLComponents(string: "https://api.crossref.org/works/\(doi)") else {
            return nil
        }
        components.queryItems = [URLQueryItem(name: "select", value: "DOI,title,author,published,container-title,is-referenced-by-count,reference-count,abstract,URL")]
        guard let url = components.url else { return nil }
        let response: CrossrefResponse = try await fetchJSON(url)
        let item = response.message
        let title = item.title?.first ?? "Crossref"
        var facts: [String] = []
        if let venue = item.containerTitle?.first { facts.append(venue) }
        if let published = item.published?.dateParts.first?.first { facts.append("Published \(published)") }
        if let citationCount = item.citationCount { facts.append("Citations recorded by Crossref: \(citationCount)") }
        if let referenceCount = item.referenceCount { facts.append("References recorded by Crossref: \(referenceCount)") }
        if let abstract = item.abstractText,
           let text = try? SwiftSoup.parse(abstract).text(), text.isEmpty == false {
            facts.append(text)
        }
        guard facts.isEmpty == false else { return nil }
        return AssistantSource(
            id: "external-crossref-\(Hashing.sha256Hex(doi).prefix(16))",
            kind: .external,
            title: "Crossref · \(title)",
            excerpt: facts.joined(separator: "\n"),
            urlString: item.url ?? "https://doi.org/\(doi)"
        )
    }

    private func fetchOpenAlex(doi: String) async throws -> AssistantSource? {
        guard var components = URLComponents(string: "https://api.openalex.org/works/doi:\(doi)") else {
            return nil
        }
        components.queryItems = [URLQueryItem(
            name: "select",
            value: "id,display_name,publication_year,cited_by_count,primary_location,doi"
        )]
        guard let url = components.url else { return nil }
        let work: OpenAlexWork = try await fetchJSON(url)
        var facts: [String] = []
        if let year = work.publicationYear { facts.append("Published \(year)") }
        if let source = work.primaryLocation?.source?.displayName { facts.append(source) }
        if let citations = work.citedByCount { facts.append("Citations recorded by OpenAlex: \(citations)") }
        guard facts.isEmpty == false else { return nil }
        return AssistantSource(
            id: "external-openalex-\(work.id ?? Hashing.sha256Hex(doi))",
            kind: .external,
            title: "OpenAlex · \(work.displayName ?? doi)",
            excerpt: facts.joined(separator: "\n"),
            urlString: work.id?.replacingOccurrences(of: "https://api.openalex.org/", with: "https://openalex.org/")
                ?? work.doi
                ?? "https://doi.org/\(doi)"
        )
    }

    private func searchSemanticScholar(
        query: String,
        currentTitle: String,
        limit: Int
    ) async throws -> [AssistantSource] {
        guard var components = URLComponents(string: "https://api.semanticscholar.org/graph/v1/paper/search") else {
            return []
        }
        components.queryItems = [
            URLQueryItem(name: "query", value: query.replacingOccurrences(of: "-", with: " ")),
            URLQueryItem(name: "limit", value: String(max(1, limit + 1))),
            URLQueryItem(name: "fields", value: "title,abstract,url,year,authors,citationCount")
        ]
        guard let url = components.url else { return [] }
        let response: SemanticScholarSearchResponse = try await fetchJSON(url)
        return response.data.compactMap { paper in
            guard paper.title.caseInsensitiveCompare(currentTitle) != .orderedSame else { return nil }
            var facts: [String] = []
            if let year = paper.year { facts.append(String(year)) }
            let authorNames = paper.authors?.map(\.name).filter { $0.isEmpty == false } ?? []
            if authorNames.isEmpty == false { facts.append(authorNames.prefix(4).joined(separator: ", ")) }
            if let citationCount = paper.citationCount { facts.append("Citations: \(citationCount)") }
            if let abstract = paper.abstractText, abstract.isEmpty == false { facts.append(abstract) }
            return AssistantSource(
                id: "external-s2-\(paper.paperID)",
                kind: .external,
                title: "Semantic Scholar · \(paper.title)",
                excerpt: facts.joined(separator: "\n"),
                urlString: paper.url
            )
        }
        .prefix(limit)
        .map { $0 }
    }

    private func fetchJSON<Value: Decodable>(_ url: URL) async throws -> Value {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(BrowserRequestHeaders.chromeUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "HTTP \(statusCode)"])
        }
        return try JSONDecoder().decode(Value.self, from: data)
    }
}

private struct CrossrefResponse: Decodable {
    var message: CrossrefWork
}

private struct CrossrefWork: Decodable {
    var title: [String]?
    var containerTitle: [String]?
    var published: CrossrefDate?
    var citationCount: Int?
    var referenceCount: Int?
    var abstractText: String?
    var url: String?

    enum CodingKeys: String, CodingKey {
        case title
        case containerTitle = "container-title"
        case published
        case citationCount = "is-referenced-by-count"
        case referenceCount = "reference-count"
        case abstractText = "abstract"
        case url = "URL"
    }
}

private struct CrossrefDate: Decodable {
    var dateParts: [[Int]]

    enum CodingKeys: String, CodingKey {
        case dateParts = "date-parts"
    }
}

private struct OpenAlexWork: Decodable {
    var id: String?
    var displayName: String?
    var publicationYear: Int?
    var citedByCount: Int?
    var primaryLocation: OpenAlexLocation?
    var doi: String?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case publicationYear = "publication_year"
        case citedByCount = "cited_by_count"
        case primaryLocation = "primary_location"
        case doi
    }
}

private struct OpenAlexLocation: Decodable {
    var source: OpenAlexSource?
}

private struct OpenAlexSource: Decodable {
    var displayName: String?

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
    }
}

private struct SemanticScholarSearchResponse: Decodable {
    var data: [SemanticScholarPaper]
}

private struct SemanticScholarPaper: Decodable {
    var paperID: String
    var title: String
    var abstractText: String?
    var url: String?
    var year: Int?
    var authors: [SemanticScholarAuthor]?
    var citationCount: Int?

    enum CodingKeys: String, CodingKey {
        case paperID = "paperId"
        case title
        case abstractText = "abstract"
        case url
        case year
        case authors
        case citationCount
    }
}

private struct SemanticScholarAuthor: Decodable {
    var name: String
}
