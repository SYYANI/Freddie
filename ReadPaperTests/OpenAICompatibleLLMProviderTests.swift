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
}

private final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static private(set) var requestPaths: [String] = []

    static func reset() {
        requestHandler = nil
        requestPaths = []
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
