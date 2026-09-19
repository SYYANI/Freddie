import Foundation
import XCTest
@testable import ReadPaper

final class OpenAICompatibleLLMProviderTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        MockURLProtocol.reset()
    }

    func testWebSearchSourcesCanBeRecoveredFromAnswerURLs() {
        let sources = LLMWebSearchSource.detected(
            in: "See https://docs.example.test/current and https://docs.example.test/current."
        )

        XCTAssertEqual(sources.map(\.urlString), ["https://docs.example.test/current"])
    }

    func testWebSearchSourceRemovesInternalCallIDButPreservesRealFragment() throws {
        let internalOnly = try XCTUnwrap(LLMWebSearchSource(
            urlString: "https://www.iana.org/help/example-domains#ws_call_id=call_01"
        ))
        let anchored = try XCTUnwrap(LLMWebSearchSource(
            urlString: "https://www.iana.org/help/example-domains#requirements&ws_call_id=call_02"
        ))
        let regularFragment = try XCTUnwrap(LLMWebSearchSource(
            urlString: "https://www.iana.org/help/example-domains#requirements&view=compact"
        ))

        XCTAssertEqual(internalOnly.urlString, "https://www.iana.org/help/example-domains")
        XCTAssertEqual(anchored.urlString, "https://www.iana.org/help/example-domains#requirements")
        XCTAssertEqual(
            regularFragment.urlString,
            "https://www.iana.org/help/example-domains#requirements&view=compact"
        )
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

    func testResponsesWebSearchDeclaresAndForcesToolOnInitialRequest() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/responses")
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(Self.responsesSuccessBody.utf8)
            )
        }

        let provider = OpenAICompatibleLLMProvider(sessionConfigurationOverride: configuration)
        _ = try await provider.complete(request: LLMCompletionRequest(
            baseURL: URL(string: "https://api.deepseek.com")!,
            apiStyle: .responses,
            apiKey: "sk-test",
            model: "deepseek-v4-flash",
            messages: [LLMCompletionMessage(role: "user", content: "Search current work")],
            timeoutProfile: .validation(timeoutSeconds: 10),
            webSearchEnabled: true
        ))

        let body = try XCTUnwrap(MockURLProtocol.requestBodies.last)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let tools = try XCTUnwrap(json["tools"] as? [[String: String]])
        XCTAssertEqual(tools, [["type": "web_search"]])
        XCTAssertEqual(json["tool_choice"] as? [String: String], ["type": "web_search"])
    }

    func testResponsesWebSearchDoesNotReplayWhenAnswerIsAlreadyPresent() async throws {
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
                Data(Self.responsesWebSearchCallAndAnswerBody.utf8)
            )
        }

        let provider = OpenAICompatibleLLMProvider(sessionConfigurationOverride: configuration)
        let response = try await provider.complete(request: LLMCompletionRequest(
            baseURL: URL(string: "https://api.deepseek.com")!,
            apiStyle: .responses,
            apiKey: "sk-test",
            model: "deepseek-v4-flash",
            messages: [LLMCompletionMessage(role: "user", content: "What is the latest release?")],
            timeoutProfile: .validation(timeoutSeconds: 10),
            webSearchEnabled: true
        ))

        XCTAssertEqual(response.text, "DeepSeek answered directly after search.")
        XCTAssertEqual(response.webSearchSources, [
            LLMWebSearchSource(
                urlString: "https://docs.example.test/answer",
                title: "Answer documentation"
            )!,
            LLMWebSearchSource(
                urlString: "https://search.example.test/result",
                title: "Search result"
            )!
        ])
        XCTAssertEqual(MockURLProtocol.requestPaths, ["/responses"])
        XCTAssertEqual(MockURLProtocol.requestBodies.count, 1)
    }

    func testResponsesWebSearchReplaysAnswerlessSearchCallAndReturnsContinuation() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/responses")
            if MockURLProtocol.requestBodies.count == 1 {
                return (
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    Data(Self.responsesWebSearchCallOnlyBody.utf8)
                )
            }
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(Self.responsesWebSearchAnswerBody.utf8)
            )
        }

        let provider = OpenAICompatibleLLMProvider(sessionConfigurationOverride: configuration)
        let response = try await provider.complete(request: LLMCompletionRequest(
            baseURL: URL(string: "https://api.deepseek.com")!,
            apiStyle: .responses,
            apiKey: "sk-test",
            model: "deepseek-v4-flash",
            messages: [LLMCompletionMessage(role: "user", content: "What is the latest release?")],
            timeoutProfile: .validation(timeoutSeconds: 10),
            webSearchEnabled: true
        ))

        XCTAssertEqual(response.text, "DeepSeek answered from the restored search results.")
        XCTAssertEqual(
            response.webSearchSources.map(\.urlString),
            ["https://example.test/source"]
        )
        XCTAssertEqual(MockURLProtocol.requestPaths, ["/responses", "/responses"])

        let bodies = MockURLProtocol.requestBodies
        XCTAssertEqual(bodies.count, 2)
        guard bodies.count >= 2 else {
            return XCTFail("Expected two request bodies for search replay, got \(bodies.count).")
        }

        let firstJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: bodies[0]) as? [String: Any]
        )
        let firstInput = try XCTUnwrap(firstJSON["input"] as? [[String: Any]])
        XCTAssertEqual(firstInput.count, 1)
        XCTAssertEqual(firstInput[0]["role"] as? String, "user")
        XCTAssertEqual(
            firstJSON["tool_choice"] as? [String: String],
            ["type": "web_search"]
        )
        XCTAssertEqual(firstJSON["tools"] as? [[String: String]], [["type": "web_search"]])

        let secondJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: bodies[1]) as? [String: Any]
        )
        XCTAssertEqual(secondJSON["tool_choice"] as? String, "none")
        XCTAssertEqual(secondJSON["tools"] as? [[String: String]], [["type": "web_search"]])
        let secondInput = try XCTUnwrap(secondJSON["input"] as? [[String: Any]])
        XCTAssertEqual(secondInput.count, 3)
        guard secondInput.count >= 3 else {
            return XCTFail("Expected replayed input items, got \(secondInput.count): \(secondJSON)")
        }
        XCTAssertEqual(secondInput[0]["role"] as? String, "user")
        XCTAssertEqual(secondInput[0]["content"] as? String, "What is the latest release?")

        let replayedCall = try XCTUnwrap(secondInput[1])
        XCTAssertEqual(replayedCall["type"] as? String, "web_search_call")
        XCTAssertEqual(replayedCall["id"] as? String, "ws_1")
        XCTAssertEqual(replayedCall["status"] as? String, "completed")
        let action = try XCTUnwrap(replayedCall["action"] as? [String: Any])
        XCTAssertEqual(action["type"] as? String, "search")
        XCTAssertEqual(action["query"] as? String, "latest release")

        XCTAssertEqual(secondInput[2]["role"] as? String, "user")
        let continuation = try XCTUnwrap(secondInput[2]["content"] as? String)
        XCTAssertTrue(continuation.contains("search results"))
    }

    func testResponsesStreamingReplaysAnswerlessWebSearchCall() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.requestHandler = { request in
            let body: String
            if MockURLProtocol.requestBodies.count == 1 {
                body = Self.responsesWebSearchCallOnlyStreamBody
            } else {
                body = Self.responsesWebSearchAnswerStreamBody
            }
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
                baseURL: URL(string: "https://api.deepseek.com")!,
                apiStyle: .responses,
                apiKey: "sk-test",
                model: "deepseek-v4-flash",
                messages: [LLMCompletionMessage(role: "user", content: "Search the current status")],
                timeoutProfile: .validation(timeoutSeconds: 10),
                webSearchEnabled: true
            ),
            onPartialText: { await recorder.append($0) }
        )

        XCTAssertEqual(response.text, "Live answer")
        XCTAssertEqual(
            response.webSearchSources.map(\.urlString),
            ["https://status.example.test/current"]
        )
        XCTAssertEqual(MockURLProtocol.requestPaths, ["/responses", "/responses"])
        let partialValues = await recorder.values()
        XCTAssertEqual(partialValues, ["Live ", "Live answer"])

        let secondBody = try XCTUnwrap(MockURLProtocol.requestBodies.last)
        let secondJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: secondBody) as? [String: Any]
        )
        XCTAssertEqual(secondJSON["tool_choice"] as? String, "none")
        let secondInput = try XCTUnwrap(secondJSON["input"] as? [[String: Any]])
        XCTAssertEqual(secondInput.count, 3)
        guard secondInput.count >= 2 else {
            return XCTFail("Expected replayed web search call in input, got \(secondInput.count): \(secondJSON)")
        }
        XCTAssertEqual(secondInput[1]["type"] as? String, "web_search_call")
        XCTAssertEqual(secondInput[1]["id"] as? String, "ws_1")
    }

    func testResponsesStreamingReplaysCompletedCallsWhenAnotherSearchCallFailed() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.requestHandler = { request in
            let body: String
            if MockURLProtocol.requestBodies.count == 1 {
                body = Self.responsesWebSearchCallWithFailedItemStreamBody
            } else {
                body = Self.responsesWebSearchAnswerStreamBody
            }
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
                baseURL: URL(string: "https://api.deepseek.com")!,
                apiStyle: .responses,
                apiKey: "sk-test",
                model: "deepseek-v4-flash",
                messages: [LLMCompletionMessage(role: "user", content: "Search the current status")],
                timeoutProfile: .validation(timeoutSeconds: 10),
                webSearchEnabled: true
            ),
            onPartialText: { await recorder.append($0) }
        )

        XCTAssertEqual(response.text, "Live answer")
        XCTAssertEqual(MockURLProtocol.requestPaths, ["/responses", "/responses"])
        XCTAssertEqual(MockURLProtocol.requestBodies.count, 2)
        let partialValues = await recorder.values()
        XCTAssertEqual(partialValues, ["Live ", "Live answer"])

        let secondBody = try XCTUnwrap(MockURLProtocol.requestBodies.last)
        let secondJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: secondBody) as? [String: Any]
        )
        XCTAssertEqual(secondJSON["tool_choice"] as? String, "none")
        let secondInput = try XCTUnwrap(secondJSON["input"] as? [[String: Any]])
        let replayedCallIDs = secondInput
            .filter { $0["type"] as? String == "web_search_call" }
            .compactMap { $0["id"] as? String }
        XCTAssertEqual(replayedCallIDs, ["ws_ok"])
    }

    func testResponsesStreamingUsesTerminalMessageWhenProviderOmitsTextDeltas() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.requestHandler = { request in
            (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "text/event-stream"]
                )!,
                Data(Self.responsesBufferedWebSearchAnswerStreamBody.utf8)
            )
        }
        let recorder = StreamingTextRecorder()
        let provider = OpenAICompatibleLLMProvider(sessionConfigurationOverride: configuration)

        let response = try await provider.completeStreaming(
            request: LLMCompletionRequest(
                baseURL: URL(string: "https://api.deepseek.com")!,
                apiStyle: .responses,
                apiKey: "sk-test",
                model: "deepseek-v4-flash",
                messages: [LLMCompletionMessage(role: "user", content: "Search")],
                webSearchEnabled: true
            ),
            onPartialText: { await recorder.append($0) }
        )

        XCTAssertEqual(response.text, "Buffered answer")
        XCTAssertEqual(MockURLProtocol.requestBodies.count, 1)
        let partialValues = await recorder.values()
        XCTAssertEqual(partialValues, ["Buffered answer"])
        XCTAssertEqual(
            response.webSearchSources.map(\.urlString),
            ["https://buffered.example.test/source"]
        )
    }

    func testResponsesWebSearchContinuesAcrossMultipleAnswerlessCalls() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.requestHandler = { request in
            let body: String
            switch MockURLProtocol.requestBodies.count {
            case 1:
                body = Self.responsesWebSearchCallOnlyBody
            case 2:
                body = Self.responsesSecondWebSearchCallOnlyBody
            default:
                body = Self.responsesWebSearchAnswerBody
            }
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(body.utf8)
            )
        }
        let provider = OpenAICompatibleLLMProvider(sessionConfigurationOverride: configuration)

        let response = try await provider.complete(request: LLMCompletionRequest(
            baseURL: URL(string: "https://api.deepseek.com")!,
            apiStyle: .responses,
            apiKey: "sk-test",
            model: "deepseek-v4-flash",
            messages: [LLMCompletionMessage(role: "user", content: "Research the current status")],
            webSearchEnabled: true
        ))

        XCTAssertEqual(response.text, "DeepSeek answered from the restored search results.")
        XCTAssertEqual(MockURLProtocol.requestBodies.count, 3)
        XCTAssertEqual(response.webSearchSources.map(\.urlString), [
            "https://example.test/source",
            "https://example.test/details"
        ])

        let finalBody = try XCTUnwrap(MockURLProtocol.requestBodies.last)
        let finalJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: finalBody) as? [String: Any]
        )
        XCTAssertEqual(finalJSON["tool_choice"] as? String, "none")
        let finalInput = try XCTUnwrap(finalJSON["input"] as? [[String: Any]])
        XCTAssertEqual(finalInput.filter { $0["type"] as? String == "web_search_call" }.count, 2)
    }

    func testResponsesWebSearchStopsWhenContinuationReturnsSameCall() async throws {
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
                Data(Self.responsesWebSearchCallOnlyBody.utf8)
            )
        }
        let provider = OpenAICompatibleLLMProvider(sessionConfigurationOverride: configuration)

        do {
            _ = try await provider.complete(request: LLMCompletionRequest(
                baseURL: URL(string: "https://api.deepseek.com")!,
                apiStyle: .responses,
                apiKey: "sk-test",
                model: "deepseek-v4-flash",
                messages: [LLMCompletionMessage(role: "user", content: "Search")],
                webSearchEnabled: true
            ))
            XCTFail("Expected a repeated search call to stop continuation.")
        } catch let error as LLMProviderError {
            XCTAssertEqual(error, .webSearchCompletedWithoutAnswer)
        }

        XCTAssertEqual(MockURLProtocol.requestBodies.count, 2)
    }

    func testResponsesStreamingMergesTraceLikeTerminalCallsAndNormalizesSources() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.requestHandler = { request in
            let isInitialRequest = MockURLProtocol.requestBodies.count == 1
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [
                        "Content-Type": isInitialRequest
                            ? "text/event-stream"
                            : "application/json"
                    ]
                )!,
                Data(
                    (isInitialRequest
                        ? Self.responsesTraceLikeWebSearchCallOnlyStreamBody
                        : Self.responsesWebSearchAnswerBody).utf8
                )
            )
        }
        let provider = OpenAICompatibleLLMProvider(sessionConfigurationOverride: configuration)

        let response = try await provider.completeStreaming(
            request: LLMCompletionRequest(
                baseURL: URL(string: "https://api.deepseek.com")!,
                apiStyle: .responses,
                apiKey: "sk-test",
                model: "deepseek-v4-flash",
                messages: [LLMCompletionMessage(role: "user", content: "Find the IANA page")],
                webSearchEnabled: true
            ),
            onPartialText: { _ in }
        )

        XCTAssertEqual(response.text, "DeepSeek answered from the restored search results.")
        XCTAssertEqual(
            response.webSearchSources.map(\.urlString),
            ["https://www.iana.org/help/example-domains"]
        )
        XCTAssertEqual(MockURLProtocol.requestBodies.count, 2)

        let continuationBody = try XCTUnwrap(MockURLProtocol.requestBodies.last)
        let continuationJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: continuationBody) as? [String: Any]
        )
        let continuationInput = try XCTUnwrap(continuationJSON["input"] as? [[String: Any]])
        let replayedCalls = continuationInput.filter {
            $0["type"] as? String == "web_search_call"
        }
        XCTAssertEqual(replayedCalls.compactMap { $0["id"] as? String }, ["ws_open", "ws_find"])
        let replayedURLs = replayedCalls.compactMap {
            ($0["action"] as? [String: Any])?["url"] as? String
        }
        XCTAssertEqual(replayedURLs, [
            "https://www.iana.org/help/example-domains#ws_call_id=call_01",
            "https://www.iana.org/help/example-domains#ws_call_id=call_02"
        ])
    }

    func testResponsesFailureSurfacesProviderMessage() async throws {
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
                Data(Self.responsesFailureBody.utf8)
            )
        }
        let provider = OpenAICompatibleLLMProvider(sessionConfigurationOverride: configuration)

        do {
            _ = try await provider.complete(request: LLMCompletionRequest(
                baseURL: URL(string: "https://api.deepseek.com")!,
                apiStyle: .responses,
                apiKey: "sk-test",
                model: "deepseek-v4-flash",
                messages: [LLMCompletionMessage(role: "user", content: "Search")],
                webSearchEnabled: true
            ))
            XCTFail("Expected the failed Responses API status to throw.")
        } catch let error as LLMProviderError {
            XCTAssertEqual(error, .network("Search backend unavailable."))
        }
    }

    func testResponsesStreamingIncompleteStatusThrowsInsteadOfReturningPartialText() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.requestHandler = { request in
            (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "text/event-stream"]
                )!,
                Data(Self.responsesIncompleteStreamBody.utf8)
            )
        }
        let provider = OpenAICompatibleLLMProvider(sessionConfigurationOverride: configuration)

        do {
            _ = try await provider.completeStreaming(
                request: LLMCompletionRequest(
                    baseURL: URL(string: "https://api.deepseek.com")!,
                    apiStyle: .responses,
                    apiKey: "sk-test",
                    model: "deepseek-v4-flash",
                    messages: [LLMCompletionMessage(role: "user", content: "Search")],
                    webSearchEnabled: true
                ),
                onPartialText: { _ in }
            )
            XCTFail("Expected the incomplete Responses API status to throw.")
        } catch let error as LLMProviderError {
            XCTAssertEqual(
                error,
                .network(AppLocalization.format(
                    "The provider returned an incomplete response: %@",
                    "max_output_tokens"
                ))
            )
        }
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

    private static let responsesWebSearchCallOnlyBody = """
    {
      "id": "resp-search-call",
      "object": "response",
      "status": "completed",
      "model": "deepseek-v4-flash",
      "output": [
        {
          "type": "web_search_call",
          "id": "ws_1",
          "status": "completed",
          "action": {
            "type": "search",
            "query": "latest release",
            "sources": [{"type": "url", "url": "https://example.test/source"}]
          }
        }
      ]
    }
    """

    private static let responsesWebSearchAnswerBody = """
    {
      "id": "resp-search-answer",
      "object": "response",
      "status": "completed",
      "model": "deepseek-v4-flash",
      "output": [
        {
          "type": "message",
          "id": "msg_answer",
          "role": "assistant",
          "status": "completed",
          "content": [
            {"type": "output_text", "text": "DeepSeek answered from the restored search results."}
          ]
        }
      ]
    }
    """

    private static let responsesSecondWebSearchCallOnlyBody = """
    {
      "id": "resp-search-call-2",
      "object": "response",
      "status": "completed",
      "model": "deepseek-v4-flash",
      "output": [
        {
          "type": "web_search_call",
          "id": "ws_2",
          "status": "completed",
          "action": {
            "type": "open_page",
            "url": "https://example.test/details",
            "title": "Details"
          }
        }
      ]
    }
    """

    private static let responsesWebSearchCallAndAnswerBody = """
    {
      "id": "resp-search-call-and-answer",
      "object": "response",
      "status": "completed",
      "model": "deepseek-v4-flash",
      "output": [
        {
          "type": "web_search_call",
          "id": "ws_1",
          "status": "completed",
          "action": {
            "type": "search",
            "query": "latest release",
            "sources": [
              {"type": "url", "url": "https://search.example.test/result", "title": "Search result"}
            ]
          }
        },
        {
          "type": "message",
          "id": "msg_direct",
          "role": "assistant",
          "status": "completed",
          "content": [
            {
              "type": "output_text",
              "text": "DeepSeek answered directly after search.",
              "annotations": [
                {
                  "type": "url_citation",
                  "url": "https://docs.example.test/answer",
                  "title": "Answer documentation"
                }
              ]
            }
          ]
        }
      ]
    }
    """

    private static let responsesWebSearchCallOnlyStreamBody = """
    event: response.output_item.done
    data: {"type":"response.output_item.done","output_index":0,"item":{"type":"web_search_call","id":"ws_1","status":"completed","action":{"type":"search","query":"current status","sources":[{"type":"url","url":"https://status.example.test/current","title":"Service status"}]}}}

    event: response.completed
    data: {"type":"response.completed","response":{"id":"resp_1","object":"response","status":"completed","output":[{"type":"web_search_call","id":"ws_1","status":"completed","action":{"type":"search","query":"current status","sources":[{"type":"url","url":"https://status.example.test/current","title":"Service status"}]}}]}}

    """

    private static let responsesWebSearchCallWithFailedItemStreamBody = """
    event: response.output_item.done
    data: {"type":"response.output_item.done","output_index":0,"item":{"type":"web_search_call","id":"ws_ok","status":"completed","action":{"type":"search","query":"current status","sources":[{"type":"url","url":"https://status.example.test/current","title":"Service status"}]}}}

    event: response.output_item.done
    data: {"type":"response.output_item.done","output_index":1,"item":{"type":"web_search_call","id":"ws_bad","status":"failed","action":{"type":"open_page","url":"https://broken.example.test/bad"}}}

    event: response.completed
    data: {"type":"response.completed","response":{"id":"resp_1","object":"response","status":"completed","output":[{"type":"web_search_call","id":"ws_ok","status":"completed","action":{"type":"search","query":"current status","sources":[{"type":"url","url":"https://status.example.test/current","title":"Service status"}]}},{"type":"web_search_call","id":"ws_bad","status":"failed","action":{"type":"open_page","url":"https://broken.example.test/bad"}}]}}

    """

    private static let responsesTraceLikeWebSearchCallOnlyStreamBody = """
    event: response.output_item.done
    data: {"type":"response.output_item.done","output_index":0,"item":{"type":"web_search_call","id":"ws_open","status":"completed","action":{"type":"open_page","url":"https://www.iana.org/help/example-domains#ws_call_id=call_01"}}}

    event: response.completed
    data: {"type":"response.completed","response":{"id":"resp_trace","object":"response","status":"completed","output":[{"type":"web_search_call","id":"ws_open","status":"completed","action":{"type":"open_page","url":"https://www.iana.org/help/example-domains#ws_call_id=call_01"}},{"type":"web_search_call","id":"ws_find","status":"completed","action":{"type":"find_in_page","pattern":"Further Reading","url":"https://www.iana.org/help/example-domains#ws_call_id=call_02"}},{"type":"web_search_call","id":"ws_failed","status":"failed","action":{"type":"open_page","url":"https://www.iana.org/domains/example#ws_call_id=call_03"}}]}}

    """

    private static let responsesWebSearchAnswerStreamBody = """
    event: response.output_text.delta
    data: {"type":"response.output_text.delta","delta":"Live "}

    event: response.output_text.delta
    data: {"type":"response.output_text.delta","delta":"answer"}

    event: response.completed
    data: {"type":"response.completed","response":{"id":"resp_2","object":"response","status":"completed"}}

    """

    private static let responsesBufferedWebSearchAnswerStreamBody = """
    event: response.output_item.done
    data: {"type":"response.output_item.done","output_index":0,"item":{"type":"web_search_call","id":"ws_buffered","status":"completed","action":{"type":"search","query":"current status","sources":[{"type":"url","url":"https://buffered.example.test/source"}]}}}

    event: response.completed
    data: {"type":"response.completed","response":{"id":"resp_buffered","object":"response","status":"completed","output":[{"type":"web_search_call","id":"ws_buffered","status":"completed","action":{"type":"search","query":"current status","sources":[{"type":"url","url":"https://buffered.example.test/source"}]}},{"type":"message","id":"msg_buffered","role":"assistant","status":"completed","content":[{"type":"output_text","text":"Buffered answer"}]}]}}

    """

    private static let responsesFailureBody = """
    {
      "id": "resp_failed",
      "object": "response",
      "status": "failed",
      "error": {"code": "server_error", "message": "Search backend unavailable."},
      "output": []
    }
    """

    private static let responsesIncompleteStreamBody = """
    event: response.output_text.delta
    data: {"type":"response.output_text.delta","delta":"Partial answer"}

    event: response.incomplete
    data: {"type":"response.incomplete","response":{"id":"resp_incomplete","object":"response","status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"output":[]}}

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
