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

    func testWebSearchRequiresServerSearchAPI() async {
        let validator = LLMProviderValidationUseCase()

        do {
            _ = try await validator.testWebSearch(
                baseURL: "https://api.example.com/v1",
                apiStyle: .chatCompletions,
                apiKey: "sk-test",
                model: "test-model"
            )
            XCTFail("Expected Chat Completions web search validation to fail.")
        } catch {
            XCTAssertEqual(
                error as? LLMProviderValidationError,
                .webSearchRequiresServerSearchAPI
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

    func testWebSearchSupportsAnthropicMessagesServerTool() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WebSearchValidationURLProtocol.self]
        WebSearchValidationURLProtocol.responseBody = """
        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"server_tool_use","id":"call_0","name":"web_search","input":{}}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":0}

        event: content_block_start
        data: {"type":"content_block_start","index":1,"content_block":{"type":"web_search_tool_result","tool_use_id":"call_0","content":[{"type":"web_search_result","title":"IANA-managed Reserved Domains","url":"https://www.iana.org/help/example-domains#1"}]}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":1}

        event: content_block_start
        data: {"type":"content_block_start","index":2,"content_block":{"type":"text","text":""}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":2,"delta":{"type":"text_delta","text":"https://www.iana.org/help/example-domains"}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":2}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}

        """
        let provider = OpenAICompatibleLLMProvider(sessionConfigurationOverride: configuration)
        let validator = LLMProviderValidationUseCase(provider: provider)

        let result = try await validator.testWebSearch(
            baseURL: "https://api.example.com/anthropic/v1",
            apiStyle: .anthropicMessages,
            apiKey: "sk-secret-value",
            model: "test-model"
        )

        XCTAssertEqual(result.sources.map(\.urlString), [
            "https://www.iana.org/help/example-domains"
        ])
        XCTAssertEqual(result.sources.first?.title, "IANA-managed Reserved Domains")
        XCTAssertTrue(result.trace.contains("Protocol: Anthropic Messages API"))
        XCTAssertTrue(result.trace.contains("REQUEST POST https://api.example.com/anthropic/v1/messages"))
        XCTAssertTrue(result.trace.contains("web_search_20250305"))
        XCTAssertTrue(result.trace.contains("x-api-key: <redacted>"))
        XCTAssertFalse(result.trace.contains("sk-secret-value"))
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
