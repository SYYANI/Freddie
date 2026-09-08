import Foundation
import XCTest
@testable import ReadPaper

final class OpenAICompatibleLLMProviderTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        MockURLProtocol.reset()
    }

    func testProviderRetriesWithoutV1AndPreservesProxyPath() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]

        MockURLProtocol.requestHandler = { request in
            let path = request.url?.path ?? ""
            if path == "/proxy/v1/chat/completions" {
                return (
                    HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 404, httpVersion: nil, headerFields: nil)!,
                    Data("{}".utf8)
                )
            }

            XCTAssertEqual(path, "/proxy/chat/completions")
            let body = """
            {
              "id": "chatcmpl-test",
              "object": "chat.completion",
              "created": 1710000000,
              "model": "test-model",
              "choices": [
                {
                  "index": 0,
                  "message": {
                    "role": "assistant",
                    "content": "ok"
                  },
                  "finish_reason": "stop"
                }
              ],
              "usage": {
                "prompt_tokens": 1,
                "completion_tokens": 1,
                "total_tokens": 2
              }
            }
            """
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
                Data(body.utf8)
            )
        }

        let provider = OpenAICompatibleLLMProvider(sessionConfigurationOverride: configuration)
        let response = try await provider.complete(
            request: LLMCompletionRequest(
                baseURL: URL(string: "https://api.example.com/proxy/v1")!,
                apiKey: "sk-test",
                model: "test-model",
                messages: [
                    LLMCompletionMessage(role: "system", content: "You are concise."),
                    LLMCompletionMessage(role: "user", content: "Reply with exactly: ok")
                ],
                temperature: nil,
                topP: nil,
                maxTokens: nil,
                timeoutProfile: .validation(timeoutSeconds: 10)
            )
        )

        XCTAssertEqual(response.text, "ok")
        XCTAssertEqual(MockURLProtocol.requestPaths, [
            "/proxy/v1/chat/completions",
            "/proxy/chat/completions"
        ])
    }

    func testRequestIncludesThinkingEnabledAndReasoningEffortMax() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]

        MockURLProtocol.requestHandler = { request in
            let body = Self.chatCompletionSuccessBody
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
                Data(body.utf8)
            )
        }

        let provider = OpenAICompatibleLLMProvider(sessionConfigurationOverride: configuration)
        _ = try await provider.complete(
            request: LLMCompletionRequest(
                baseURL: URL(string: "https://api.example.com/v1")!,
                apiKey: "sk-test",
                model: "deepseek-v4-pro",
                messages: [
                    LLMCompletionMessage(role: "user", content: "Hello")
                ],
                temperature: nil,
                topP: nil,
                maxTokens: nil,
                thinkingMode: .enabled,
                reasoningEffort: .max,
                timeoutProfile: .validation(timeoutSeconds: 10)
            )
        )

        let body = try XCTUnwrap(MockURLProtocol.requestBodies.last)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(json["model"] as? String, "deepseek-v4-pro")
        XCTAssertEqual(json["reasoning_effort"] as? String, "max")
        XCTAssertEqual((json["thinking"] as? [String: String])?["type"], "enabled")
    }

    func testRequestOmitsReasoningEffortWhenThinkingDisabled() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]

        MockURLProtocol.requestHandler = { request in
            (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
                Data(Self.chatCompletionSuccessBody.utf8)
            )
        }

        let provider = OpenAICompatibleLLMProvider(sessionConfigurationOverride: configuration)
        _ = try await provider.complete(
            request: LLMCompletionRequest(
                baseURL: URL(string: "https://api.example.com/v1")!,
                apiKey: "sk-test",
                model: "deepseek-v4-pro",
                messages: [
                    LLMCompletionMessage(role: "user", content: "Hello")
                ],
                thinkingMode: .disabled,
                reasoningEffort: .max,
                timeoutProfile: .validation(timeoutSeconds: 10)
            )
        )

        let body = try XCTUnwrap(MockURLProtocol.requestBodies.last)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual((json["thinking"] as? [String: String])?["type"], "disabled")
        XCTAssertNil(json["reasoning_effort"])
    }

    func testRequestOmitsThinkingAndReasoningEffortByDefault() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]

        MockURLProtocol.requestHandler = { request in
            (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
                Data(Self.chatCompletionSuccessBody.utf8)
            )
        }

        let provider = OpenAICompatibleLLMProvider(sessionConfigurationOverride: configuration)
        _ = try await provider.complete(
            request: LLMCompletionRequest(
                baseURL: URL(string: "https://api.example.com/v1")!,
                apiKey: "sk-test",
                model: "test-model",
                messages: [
                    LLMCompletionMessage(role: "user", content: "Hello")
                ],
                timeoutProfile: .validation(timeoutSeconds: 10)
            )
        )

        let body = try XCTUnwrap(MockURLProtocol.requestBodies.last)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertNil(json["thinking"])
        XCTAssertNil(json["reasoning_effort"])
    }

    func testResponsesRequestUsesResponsesEndpointAndDecodesOutputText() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/v1/responses")
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
                Data(Self.responsesSuccessBody.utf8)
            )
        }

        let provider = OpenAICompatibleLLMProvider(sessionConfigurationOverride: configuration)
        let response = try await provider.complete(
            request: LLMCompletionRequest(
                baseURL: URL(string: "https://api.openai.com/v1")!,
                apiStyle: .responses,
                apiKey: "sk-test",
                model: "gpt-5.6-terra",
                messages: [
                    LLMCompletionMessage(role: "system", content: "You are concise."),
                    LLMCompletionMessage(role: "user", content: "Reply with exactly: ok")
                ],
                temperature: 0.2,
                maxTokens: 128,
                thinkingMode: .disabled,
                timeoutProfile: .validation(timeoutSeconds: 10)
            )
        )

        XCTAssertEqual(response.text, "ok")
        XCTAssertEqual(response.resolvedEndpoint?.path, "/v1/responses")

        let body = try XCTUnwrap(MockURLProtocol.requestBodies.last)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "gpt-5.6-terra")
        XCTAssertEqual(json["max_output_tokens"] as? Int, 128)
        XCTAssertEqual((json["reasoning"] as? [String: String])?["effort"], "none")
        let input = try XCTUnwrap(json["input"] as? [[String: Any]])
        XCTAssertEqual(input.map { $0["role"] as? String }, ["system", "user"])
        XCTAssertEqual(input.map { $0["content"] as? String }, ["You are concise.", "Reply with exactly: ok"])
        XCTAssertNil(json["messages"])
    }

    func testResponsesRootBaseURLDoesNotInsertV1() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/responses")
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
                Data(Self.responsesSuccessBody.utf8)
            )
        }

        let provider = OpenAICompatibleLLMProvider(sessionConfigurationOverride: configuration)
        _ = try await provider.complete(request: LLMCompletionRequest(
            baseURL: URL(string: "https://api.deepseek.com")!,
            apiStyle: .responses,
            apiKey: "sk-test",
            model: "deepseek-v4-flash",
            messages: [LLMCompletionMessage(role: "user", content: "Hello")],
            timeoutProfile: .validation(timeoutSeconds: 10)
        ))

        XCTAssertEqual(MockURLProtocol.requestPaths, ["/responses"])
    }

    func testResponsesRootBaseURLRetriesWithV1On404() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]

        MockURLProtocol.requestHandler = { request in
            if request.url?.path == "/responses" {
                return (
                    HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 404, httpVersion: nil, headerFields: nil)!,
                    Data("{}".utf8)
                )
            }
            XCTAssertEqual(request.url?.path, "/v1/responses")
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
                Data(Self.responsesSuccessBody.utf8)
            )
        }

        let provider = OpenAICompatibleLLMProvider(sessionConfigurationOverride: configuration)
        let response = try await provider.complete(request: LLMCompletionRequest(
            baseURL: URL(string: "https://api.example.com")!,
            apiStyle: .responses,
            apiKey: "sk-test",
            model: "test-model",
            messages: [LLMCompletionMessage(role: "user", content: "Hello")],
            timeoutProfile: .validation(timeoutSeconds: 10)
        ))

        XCTAssertEqual(response.text, "ok")
        XCTAssertEqual(MockURLProtocol.requestPaths, ["/responses", "/v1/responses"])
    }

    func testChatCompletionsStreamingEmitsAccumulatedText() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.requestHandler = { request in
            let body = """
            data: {"choices":[{"delta":{"content":"Evidence "}}]}

            data: {"choices":[{"delta":{"content":"found."}}]}

            data: [DONE]

            """
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "text/event-stream"]
                )!,
                Data(body.utf8)
            )
        }
        let recorder = StreamingTextRecorder()
        let provider = OpenAICompatibleLLMProvider(sessionConfigurationOverride: configuration)

        let response = try await provider.completeStreaming(
            request: LLMCompletionRequest(
                baseURL: URL(string: "https://api.example.com/v1")!,
                apiKey: "sk-test",
                model: "test-model",
                messages: [LLMCompletionMessage(role: "user", content: "Find evidence")]
            ),
            onPartialText: { await recorder.append($0) }
        )

        XCTAssertEqual(response.text, "Evidence found.")
        let partialValues = await recorder.values()
        XCTAssertEqual(partialValues, ["Evidence ", "Evidence found."])
        let requestBody = try XCTUnwrap(MockURLProtocol.requestBodies.last)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
        XCTAssertEqual(json["stream"] as? Bool, true)
    }

    func testResponsesStreamingDecodesOutputTextDeltaEvents() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.requestHandler = { request in
            let body = """
            event: response.output_text.delta
            data: {"type":"response.output_text.delta","delta":"One"}

            event: response.output_text.delta
            data: {"type":"response.output_text.delta","delta":" two"}

            event: response.completed
            data: {"type":"response.completed"}

            """
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "text/event-stream"]
                )!,
                Data(body.utf8)
            )
        }
        let recorder = StreamingTextRecorder()
        let provider = OpenAICompatibleLLMProvider(sessionConfigurationOverride: configuration)

        let response = try await provider.completeStreaming(
            request: LLMCompletionRequest(
                baseURL: URL(string: "https://api.example.com/v1")!,
                apiStyle: .responses,
                apiKey: "sk-test",
                model: "test-model",
                messages: [LLMCompletionMessage(role: "user", content: "Explain")]
            ),
            onPartialText: { await recorder.append($0) }
        )

        XCTAssertEqual(response.text, "One two")
        let partialValues = await recorder.values()
        XCTAssertEqual(partialValues, ["One", "One two"])
    }

    func testStreamingFallsBackWhenCompatibleProviderReturnsRegularJSON() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.requestHandler = { request in
            (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(Self.chatCompletionSuccessBody.utf8)
            )
        }
        let recorder = StreamingTextRecorder()
        let provider = OpenAICompatibleLLMProvider(sessionConfigurationOverride: configuration)

        let response = try await provider.completeStreaming(
            request: LLMCompletionRequest(
                baseURL: URL(string: "https://compatible.example/v1")!,
                apiKey: "sk-test",
                model: "test-model",
                messages: [LLMCompletionMessage(role: "user", content: "Hello")]
            ),
            onPartialText: { await recorder.append($0) }
        )

        XCTAssertEqual(response.text, "ok")
        let partialValues = await recorder.values()
        XCTAssertEqual(partialValues, ["ok"])
    }

    private static let chatCompletionSuccessBody = """
    {
      "id": "chatcmpl-test",
      "object": "chat.completion",
      "created": 1710000000,
      "model": "deepseek-v4-pro",
      "choices": [
        {
          "index": 0,
          "message": {
            "role": "assistant",
            "content": "ok"
          },
          "finish_reason": "stop"
        }
      ],
      "usage": {
        "prompt_tokens": 1,
        "completion_tokens": 1,
        "total_tokens": 2
      }
    }
    """

    private static let responsesSuccessBody = """
    {
      "id": "resp-test",
      "object": "response",
      "status": "completed",
      "model": "test-model",
      "output": [
        {
          "type": "reasoning",
          "id": "rs-test",
          "content": [{"type": "reasoning_text", "text": "internal"}]
        },
        {
          "type": "message",
          "id": "msg-test",
          "role": "assistant",
          "status": "completed",
          "content": [{"type": "output_text", "text": "ok"}]
        }
      ]
    }
    """
}

private actor StreamingTextRecorder {
    private var recordedValues: [String] = []

    func append(_ value: String) {
        recordedValues.append(value)
    }

    func values() -> [String] {
        recordedValues
    }
}

private final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static private(set) var requestPaths: [String] = []
    nonisolated(unsafe) static private(set) var requestBodies: [Data] = []

    static func reset() {
        requestHandler = nil
        requestPaths = []
        requestBodies = []
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            if let path = request.url?.path {
                Self.requestPaths.append(path)
            }
            if let body = request.httpBody {
                Self.requestBodies.append(body)
            } else if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 16_384)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    data.append(buffer, count: count)
                }
                Self.requestBodies.append(data)
            }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
