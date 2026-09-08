import Foundation
import XCTest
@testable import ReadPaper

final class SelectionAssistantOrchestratorTests: XCTestCase {
    override func tearDown() {
        AssistantExternalURLProtocol.reset()
        super.tearDown()
    }

    func testAutomaticScopeUsesPrivacyAwareLocalFirstPolicy() {
        XCTAssertEqual(
            SelectionAssistantScopeResolver.resolve(
                SelectionAssistantRequest(action: .translate, selection: "A term", scope: .automatic)
            ),
            .nearby
        )
        XCTAssertEqual(
            SelectionAssistantScopeResolver.resolve(
                SelectionAssistantRequest(action: .explain, selection: "A term", scope: .automatic)
            ),
            .nearby
        )
        XCTAssertEqual(
            SelectionAssistantScopeResolver.resolve(
                SelectionAssistantRequest(
                    action: .ask,
                    selection: "A claim",
                    question: "How do the authors validate it?",
                    scope: .automatic
                )
            ),
            .fullPaper
        )
        XCTAssertEqual(
            SelectionAssistantScopeResolver.resolve(
                SelectionAssistantRequest(
                    action: .ask,
                    selection: "A method",
                    question: "请联网查找相关论文和最新进展",
                    scope: .automatic
                )
            ),
            .external
        )
        XCTAssertEqual(
            SelectionAssistantScopeResolver.resolve(
                SelectionAssistantRequest(action: .ask, selection: "A claim", scope: .nearby)
            ),
            .nearby
        )
    }

    @MainActor
    func testFullPaperQuestionRetrievesHTMLNeighborsMetadataAndNotes() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let provider = OrchestratorProviderSpy(response: "The held-out benchmark supports the claim [S1].")
        let external = OrchestratorExternalSearchSpy()
        var progress: [SelectionAssistantProgress] = []
        let orchestrator = SelectionAssistantOrchestrator(
            assistantService: SelectionAssistantService(provider: provider),
            fullTextSearchService: PaperFullTextSearchService(fileStore: fixture.fileStore),
            externalSearchService: external,
            userDefaults: fixture.userDefaults
        )

        let result = try await orchestrator.perform(
            SelectionAssistantRequest(
                action: .ask,
                selection: "this conclusion",
                question: "How do the authors validate this conclusion on the benchmark?",
                scope: .automatic
            ),
            selection: NoteSelectionContext(
                attachmentID: fixture.attachment.id,
                quote: "this conclusion",
                htmlSelector: "rp-anchor:1"
            ),
            paper: fixture.paper,
            attachments: [fixture.attachment],
            notes: [fixture.note],
            targetLanguage: "EN",
            route: makeRoute(),
            onProgress: { progress.append($0) }
        )

        XCTAssertEqual(result.scope, .fullPaper)
        XCTAssertTrue(result.sources.contains(where: {
            $0.kind == .paperHTML && $0.htmlSelector?.contains("data-rp-assistant-block-id") == true
        }))
        XCTAssertTrue(result.sources.contains(where: { $0.kind == .userNote }))
        XCTAssertTrue(progress.contains(.searchingFullText))
        XCTAssertTrue(progress.contains(.generatingAnswer))
        let externalCallCount = await external.callCount()
        XCTAssertEqual(externalCallCount, 0)

        let capturedProviderRequest = await provider.lastRequest()
        let providerRequest = try XCTUnwrap(capturedProviderRequest)
        let prompt = providerRequest.messages.map(\.content).joined(separator: "\n")
        XCTAssertTrue(prompt.contains("Authors: Ada Author"))
        XCTAssertTrue(prompt.contains("Abstract: A test abstract."))
        XCTAssertTrue(prompt.contains("The benchmark note identifies a caveat."))
        XCTAssertTrue(prompt.contains("We validate the conclusion on a held-out benchmark."))
    }

    @MainActor
    func testExternalScopeDoesNotNetworkWhenPrivacyToggleIsOff() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        fixture.userDefaults.set(false, forKey: SelectionAssistantPreferences.externalSearchEnabledKey)
        let provider = OrchestratorProviderSpy(response: "Only paper evidence is available.")
        let external = OrchestratorExternalSearchSpy()
        let orchestrator = SelectionAssistantOrchestrator(
            assistantService: SelectionAssistantService(provider: provider),
            fullTextSearchService: PaperFullTextSearchService(fileStore: fixture.fileStore),
            externalSearchService: external,
            userDefaults: fixture.userDefaults
        )

        let result = try await orchestrator.perform(
            SelectionAssistantRequest(
                action: .ask,
                selection: "this conclusion",
                question: "Find related work.",
                scope: .external
            ),
            selection: NoteSelectionContext(
                attachmentID: fixture.attachment.id,
                quote: "this conclusion",
                htmlSelector: "rp-anchor:1"
            ),
            paper: fixture.paper,
            attachments: [fixture.attachment],
            notes: [],
            targetLanguage: "EN",
            route: makeRoute()
        )

        let externalCallCount = await external.callCount()
        XCTAssertEqual(externalCallCount, 0)
        XCTAssertTrue(result.warnings.contains(AppLocalization.localized("External search is disabled in Settings.")))
    }

    func testExternalSearchAggregatesAcademicSourcesAndCachesResults() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AssistantExternalURLProtocol.self]
        let session = URLSession(configuration: configuration)
        AssistantExternalURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)
            let body: String
            switch url.host {
            case "api.crossref.org":
                body = """
                {"message":{"title":["Evidence Paper"],"container-title":["Journal"],"published":{"date-parts":[[2026]]},"is-referenced-by-count":12,"reference-count":34,"URL":"https://doi.org/10.1234/example"}}
                """
            case "api.openalex.org":
                body = """
                {"id":"https://openalex.org/W123","display_name":"Evidence Paper","publication_year":2026,"cited_by_count":15,"primary_location":{"source":{"display_name":"Journal"}},"doi":"https://doi.org/10.1234/example"}
                """
            case "api.semanticscholar.org":
                body = """
                {"data":[{"paperId":"s2-related","title":"Related Evidence","abstract":"A related study.","url":"https://www.semanticscholar.org/paper/s2-related","year":2025,"authors":[{"name":"Grace Author"}],"citationCount":7}]}
                """
            case "export.arxiv.org":
                body = """
                <?xml version="1.0" encoding="UTF-8"?>
                <feed xmlns="http://www.w3.org/2005/Atom"></feed>
                """
            default:
                XCTFail("Unexpected external URL: \(url.absoluteString)")
                throw URLError(.badURL)
            }
            return (
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(body.utf8)
            )
        }
        let service = SelectionAssistantExternalSearchService(
            session: session,
            arxivClient: ArxivClient(session: session, minimumRequestInterval: 0)
        )
        let paper = SelectionAssistantPaperContext(
            id: UUID(),
            title: "Evidence Paper",
            abstractText: "Abstract",
            authors: ["Ada Author"],
            arxivID: nil,
            arxivVersion: nil,
            doi: "10.1234/example"
        )

        let first = await service.search(query: "related validation evidence", paper: paper, limit: 6)
        let requestCount = AssistantExternalURLProtocol.requestCount
        let second = await service.search(query: "related validation evidence", paper: paper, limit: 6)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.sources.count, 3)
        XCTAssertTrue(first.sources.contains(where: { $0.title.hasPrefix("Crossref") }))
        XCTAssertTrue(first.sources.contains(where: { $0.title.hasPrefix("OpenAlex") }))
        XCTAssertTrue(first.sources.contains(where: { $0.title.hasPrefix("Semantic Scholar") }))
        XCTAssertEqual(AssistantExternalURLProtocol.requestCount, requestCount)
    }

    @MainActor
    private func makeFixture() throws -> OrchestratorFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SelectionAssistantOrchestratorTests-\(UUID().uuidString)", isDirectory: true)
        let fileStore = PaperFileStore(applicationSupportDirectory: root)
        let paper = Paper(
            doi: "10.1234/example",
            title: "Evidence Paper",
            abstractText: "A test abstract.",
            authors: ["Ada Author"]
        )
        paper.localDirectoryPath = try fileStore.directory(for: paper.id).path
        let html = """
        <!doctype html><html><head><meta charset="UTF-8"></head><body>
        <h1>Evaluation</h1>
        <p>The setup uses a standard training split.</p>
        <p>We validate the conclusion on a held-out benchmark.</p>
        <p>The ablation confirms the same trend.</p>
        </body></html>
        """
        let htmlURL = try fileStore.write(Data(html.utf8), named: "paper.html", for: paper.id)
        let attachment = PaperAttachment(
            paperID: paper.id,
            kind: .html,
            source: .webPage,
            filename: "paper.html",
            filePath: htmlURL.path
        )
        let note = Note(
            paperID: paper.id,
            attachmentID: attachment.id,
            quote: "held-out benchmark",
            body: "The benchmark note identifies a caveat.",
            htmlSelector: "rp-anchor:2"
        )
        let suiteName = "SelectionAssistantOrchestratorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return OrchestratorFixture(
            root: root,
            userDefaultsSuiteName: suiteName,
            userDefaults: defaults,
            fileStore: fileStore,
            paper: paper,
            attachment: attachment,
            note: note
        )
    }

    private func makeRoute() -> ResolvedLLMModelRoute {
        ResolvedLLMModelRoute(
            snapshot: LLMModelRouteSnapshot(
                providerProfileID: UUID(),
                providerName: "Test Provider",
                modelProfileID: UUID(),
                modelProfileName: "Assistant Model",
                baseURL: "https://example.test/v1",
                apiKeyRef: "key-ref",
                modelName: "assistant-model"
            ),
            apiKey: "secret"
        )
    }
}

@MainActor
private struct OrchestratorFixture {
    var root: URL
    var userDefaultsSuiteName: String
    var userDefaults: UserDefaults
    var fileStore: PaperFileStore
    var paper: Paper
    var attachment: PaperAttachment
    var note: Note

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
        userDefaults.removePersistentDomain(forName: userDefaultsSuiteName)
    }
}

private actor OrchestratorProviderSpy: SelectionAssistantLLMCompleting {
    private let response: String
    private var requests: [LLMCompletionRequest] = []

    init(response: String) {
        self.response = response
    }

    func complete(request: LLMCompletionRequest) async throws -> LLMCompletionResponse {
        requests.append(request)
        return LLMCompletionResponse(text: response, resolvedEndpoint: nil)
    }

    func lastRequest() -> LLMCompletionRequest? {
        requests.last
    }
}

private actor OrchestratorExternalSearchSpy: SelectionAssistantExternalSearching {
    private var calls = 0

    func search(
        query: String,
        paper: SelectionAssistantPaperContext,
        limit: Int
    ) async -> SelectionAssistantExternalSearchResult {
        calls += 1
        return SelectionAssistantExternalSearchResult(sources: [], warnings: [])
    }

    func callCount() -> Int {
        calls
    }
}

private final class AssistantExternalURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static private(set) var requestCount = 0

    static func reset() {
        requestHandler = nil
        requestCount = 0
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let requestHandler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            Self.requestCount += 1
            let (response, data) = try requestHandler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
