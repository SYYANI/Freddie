import Foundation
import XCTest
@testable import ReadPaper

final class BabelDocToolManagerTests: XCTestCase {
    override func tearDown() {
        MockBabelDocMetadataURLProtocol.reset()
        super.tearDown()
    }

    func testLatestPublishedVersionParsesPyPIResponse() async throws {
        let session = makeSession()
        MockBabelDocMetadataURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://pypi.org/pypi/BabelDOC/json")
            let body = """
            {
              "info": {
                "version": "0.6.1"
              }
            }
            """
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(body.utf8))
        }

        let manager = BabelDocToolManager(session: session)

        let version = try await manager.latestPublishedVersion()

        XCTAssertEqual(version, "0.6.1")
        XCTAssertEqual(MockBabelDocMetadataURLProtocol.requestCount, 1)
    }

    func testResolvedInstallVersionUsesLatestKeywordAndEmptyValue() async throws {
        let session = makeSession()
        MockBabelDocMetadataURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"info":{"version":"0.6.2"}}"#.utf8))
        }

        let manager = BabelDocToolManager(session: session)

        let latestKeywordVersion = try await manager.resolvedInstallVersion("latest")
        let emptyVersion = try await manager.resolvedInstallVersion("   ")

        XCTAssertEqual(latestKeywordVersion, "0.6.2")
        XCTAssertEqual(emptyVersion, "0.6.2")
        XCTAssertEqual(MockBabelDocMetadataURLProtocol.requestCount, 2)
    }

    func testResolvedInstallVersionKeepsPinnedVersionWithoutRequest() async throws {
        let session = makeSession()
        MockBabelDocMetadataURLProtocol.requestHandler = { request in
            XCTFail("Unexpected request: \(String(describing: request.url))")
            throw URLError(.badURL)
        }

        let manager = BabelDocToolManager(session: session)

        let version = try await manager.resolvedInstallVersion("0.5.24")

        XCTAssertEqual(version, "0.5.24")
        XCTAssertEqual(MockBabelDocMetadataURLProtocol.requestCount, 0)
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockBabelDocMetadataURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class MockBabelDocMetadataURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var requestCount = 0

    static func reset() {
        requestHandler = nil
        requestCount = 0
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.requestCount += 1

        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
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
