import XCTest
@testable import ReadPaper

final class LLMProviderValidationUseCaseTests: XCTestCase {
    override func tearDown() {
        WebSearchValidationURLProtocol.reset()
        super.tearDown()
    }

    func testNormalizedBaseURLRemovesQueryFragmentAndTrailingSlash() throws {
        let validator = LLMProviderValidationUseCase()

        let normalized = try validator.normalizedBaseURL("https://api.example.com/proxy/v1/?foo=bar#frag")

        XCTAssertEqual(normalized, "https://api.example.com/proxy/v1")
    }

    func testNormalizedBaseURLRejectsUnsupportedScheme() {
        let validator = LLMProviderValidationUseCase()

        XCTAssertThrowsError(try validator.normalizedBaseURL("ftp://api.example.com/v1")) { error in
            XCTAssertEqual(error as? LLMProviderValidationError, .unsupportedBaseURLScheme)
        }
    }

    func testValidateModelNameRejectsEmptyValue() {
        let validator = LLMProviderValidationUseCase()

        XCTAssertThrowsError(try validator.validateModelName("   ")) { error in
            XCTAssertEqual(error as? LLMProviderValidationError, .emptyModel)
        }
    }

    func testTestConnectionRejectsEmptyAPIKeyBeforeRequest() async {
        let validator = LLMProviderValidationUseCase()

        do {
            _ = try await validator.testConnection(
                baseURL: "https://api.example.com/v1",
                apiKey: "   ",
                model: "test-model"
            )
            XCTFail("Expected empty API key validation to fail.")
        } catch {
            XCTAssertEqual(error as? LLMProviderValidationError, .emptyAPIKey)
        }
    }

    func testWebSearchRequiresResponsesAPI() async {
        let validator = LLMProviderValidationUseCase()

        do {
            _ = try await validator.testWebSearch(
                baseURL: "https://api.example.com/v1",
                apiStyle: .chatCompletions,
                apiKey: "sk-test",
                model: "test-model"
            )
            XCTFail("Expected Responses API validation to fail.")
        } catch {
            XCTAssertEqual(
                error as? LLMProviderValidationError,
                .webSearchRequiresResponsesAPI
            )
        }
    }

    func testWebSearchReturnsSourcesAndRedactedCompleteTrace() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WebSearchValidationURLProtocol.self]
        WebSearchValidationURLProtocol.responseBody = """
        event: response.output_item.done
        data: {"type":"response.output_item.done","item":{"type":"web_search_call","id":"ws_test","status":"completed","action":{"type":"search","query":"IANA Example Domains","sources":[{"type":"url","url":"https://www.iana.org/help/example-domains","title":"IANA-managed Reserved Domains"}]}}}

        event: response.output_text.delta
        data: {"type":"response.output_text.delta","delta":"https://www.iana.org/help/example-domains"}

        event: response.completed
        data: {"type":"response.completed","response":{"id":"resp_test","object":"response","status":"completed","output":[{"type":"web_search_call","id":"ws_test","status":"completed","action":{"type":"search","query":"IANA Example Domains","sources":[{"type":"url","url":"https://www.iana.org/help/example-domains","title":"IANA-managed Reserved Domains"}]}},{"type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"https://www.iana.org/help/example-domains"}]}]}}

        """
        let provider = OpenAICompatibleLLMProvider(sessionConfigurationOverride: configuration)
        let validator = LLMProviderValidationUseCase(provider: provider)
        let traceRecorder = WebSearchTraceSnapshotRecorder()

        let result = try await validator.testWebSearch(
            baseURL: "https://api.example.com",
            apiStyle: .responses,
            apiKey: "sk-secret-value",
            model: "test-model",
            onTraceUpdated: { appendedEntries in
                await traceRecorder.append(appendedEntries)
            }
        )

        XCTAssertEqual(result.sources.map(\.urlString), [
            "https://www.iana.org/help/example-domains"
        ])
        XCTAssertTrue(result.trace.contains("REQUEST POST https://api.example.com/responses"))
        XCTAssertTrue(result.trace.contains("response.output_item.done"))
        XCTAssertTrue(result.trace.contains("https://www.iana.org/help/example-domains"))
        XCTAssertTrue(result.trace.contains("Authorization: <redacted>"))
        XCTAssertFalse(result.trace.contains("sk-secret-value"))
        let latestTrace = await traceRecorder.value()
        XCTAssertEqual(latestTrace, result.trace)
        // Incremental batches are the whole point: the UI must never be handed
        // the growing trace as one string on every update.
        let batchCount = await traceRecorder.batchCount
        let entryCount = await traceRecorder.entryCount
        XCTAssertGreaterThan(batchCount, 1)
        XCTAssertGreaterThan(entryCount, 1)
    }
}

private actor WebSearchTraceSnapshotRecorder {
    private var appendedEntries: [String] = []
    private(set) var batchCount = 0

    var entryCount: Int {
        appendedEntries.count
    }

    func append(_ entries: [String]) {
        batchCount += 1
        appendedEntries.append(contentsOf: entries)
    }

    func value() -> String {
        appendedEntries.joined(separator: "\n\n")
    }
}

private final class WebSearchValidationURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responseBody = ""

    static func reset() {
        responseBody = ""
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.responseBody.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
