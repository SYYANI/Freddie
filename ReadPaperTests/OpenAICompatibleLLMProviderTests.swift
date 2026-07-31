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
