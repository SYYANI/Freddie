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

    func testTestConnectionToLocalServerWorksWithoutAPIKey() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LocalServerURLProtocol.self]
        LocalServerURLProtocol.lastAuthorization = nil
        let validator = LLMProviderValidationUseCase(
            provider: OpenAICompatibleLLMProvider(sessionConfigurationOverride: configuration)
        )

        let result = try await validator.testConnection(
            baseURL: "http://127.0.0.1:18000/v1",
            apiKey: "",
            model: "Inkling-2-Mini-oQ2.5e-mtp"
        )

        XCTAssertEqual(result.outputPreview, "ok")
        XCTAssertEqual(
            LocalServerURLProtocol.lastAuthorization,
            "Bearer \(LLMLocalEndpoint.placeholderAPIKey)"
        )
    }

    func testListModelsReadsOpenAICompatibleModelList() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LocalServerURLProtocol.self]
        LocalServerURLProtocol.lastAuthorization = nil
        LocalServerURLProtocol.lastURL = nil
        let validator = LLMProviderValidationUseCase(session: URLSession(configuration: configuration))

        let models = try await validator.listModels(baseURL: "http://127.0.0.1:18000/v1/")

        XCTAssertEqual(models, ["Inkling-2-Mini-oQ2.5e-mtp", "other-model"])
        XCTAssertEqual(LocalServerURLProtocol.lastURL?.absoluteString, "http://127.0.0.1:18000/v1/models")
        XCTAssertEqual(
            LocalServerURLProtocol.lastAuthorization,
            "Bearer \(LLMLocalEndpoint.placeholderAPIKey)"
        )
    }

    func testLocalEndpointDetection() {
        let local = [
            "http://127.0.0.1:18000/v1",
            "http://localhost:11434/v1",
            "http://[::1]:8080/v1",
            "http://192.168.1.20:8000/v1",
            "http://10.0.0.5/v1",
            "http://172.20.1.1:1234",
            "http://studio.local:8000/v1",
            "https://llm.localhost",
            "http://100.64.0.1:8000/v1",
            "http://100.101.102.103/v1",
            "http://100.127.255.254/v1",
        ]
        let remote = [
            "https://api.openai.com/v1",
            "https://api.deepseek.com",
            "http://172.32.0.1/v1",
            "http://100.63.255.255/v1",
            "http://100.128.0.1/v1",
            "http://8.8.8.8/v1",
            "http://127.0.0.1.example.com/v1",
            "ftp://127.0.0.1/v1",
            "not a url",
        ]
        for url in local {
            XCTAssertTrue(LLMLocalEndpoint.isLocal(url), url)
        }
        for url in remote {
            XCTAssertFalse(LLMLocalEndpoint.isLocal(url), url)
        }
        XCTAssertEqual(
            LLMLocalEndpoint.effectiveAPIKey(" sk-own ", baseURL: "http://127.0.0.1:18000/v1"),
            "sk-own"
        )
        XCTAssertNil(LLMLocalEndpoint.effectiveAPIKey("", baseURL: "https://api.openai.com/v1"))
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

private final class LocalServerURLProtocol: URLProtocol {
    nonisolated(unsafe) static var lastAuthorization: String?
    nonisolated(unsafe) static var lastURL: URL?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastAuthorization = request.value(forHTTPHeaderField: "Authorization")
        Self.lastURL = request.url
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        let body = request.url?.lastPathComponent == "models"
            ? #"{"object":"list","data":[{"id":"Inkling-2-Mini-oQ2.5e-mtp"},{"id":"other-model"},{"id":"other-model"}]}"#
            : #"{"id":"c1","object":"chat.completion","model":"local","choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}"#
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
