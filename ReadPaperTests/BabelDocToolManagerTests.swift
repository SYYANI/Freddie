import Foundation
import XCTest
@testable import ReadPaper

final class BabelDocToolManagerTests: XCTestCase {
    override func tearDown() {
        MockBabelDocMetadataURLProtocol.reset()
        super.tearDown()
    }

    func testInstallCancellationRemovesDownloadedCache() async throws {
        let (manager, rootURL) = try makeTemporaryManager(
            runner: ProcessRunner { _, _, _, _, _ in
                throw CancellationError()
            }
        )
        defer { try? FileManager.default.removeItem(at: rootURL) }

        try writeExecutable("#!/bin/sh\n", to: manager.uvExecutableURL)
        let cachedWheel = try manager.cacheDirectory.appendingPathComponent("BabelDOC.whl")
        try FileManager.default.createDirectory(
            at: cachedWheel.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: cachedWheel.path, contents: Data("partial".utf8))

        do {
            _ = try await manager.installOrUpdateBabelDOC(version: "0.6.1")
            XCTFail("Expected installation cancellation.")
        } catch is CancellationError {
            // Expected path.
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: try manager.cacheDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try manager.toolRoot.path))
    }

    func testRemoveDownloadedCacheDeletesOnlyCacheDirectory() throws {
        let (manager, rootURL) = try makeTemporaryManager()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let cacheFile = try manager.cacheDirectory.appendingPathComponent("download.tmp")
        let keepFile = try manager.toolBinDirectory.appendingPathComponent("babeldoc")
        try FileManager.default.createDirectory(
            at: cacheFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: keepFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: cacheFile.path, contents: Data("cache".utf8))
        FileManager.default.createFile(atPath: keepFile.path, contents: Data("keep".utf8))

        try manager.removeDownloadedCache()

        XCTAssertFalse(FileManager.default.fileExists(atPath: try manager.cacheDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: keepFile.path))
    }

    func testRemoveBabelDOCDeletesManagedToolDirectory() throws {
        let (manager, rootURL) = try makeTemporaryManager()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let executable = try manager.babelDocExecutableURL
        try writeExecutable("#!/bin/sh\n", to: executable)

        XCTAssertTrue(FileManager.default.fileExists(atPath: try manager.toolRoot.path))

        try manager.removeBabelDOC()

        XCTAssertFalse(FileManager.default.fileExists(atPath: try manager.toolRoot.path))
    }

    func testLatestPublishedVersionParsesPyPISimpleIndex() async throws {
        let session = makeSession()
        MockBabelDocMetadataURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://pypi.org/simple/babeldoc/")
            let body = """
            <html>
              <body>
                <a href="https://files.pythonhosted.org/packages/babeldoc-0.6.0-py3-none-any.whl">babeldoc-0.6.0-py3-none-any.whl</a>
                <a href="https://files.pythonhosted.org/packages/babeldoc-0.6.1.tar.gz">babeldoc-0.6.1.tar.gz</a>
              </body>
            </html>
            """
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html; charset=utf-8"]
            )!
            return (response, Data(body.utf8))
        }

        let manager = BabelDocToolManager(session: session, installSource: .official)

        let version = try await manager.latestPublishedVersion()

        XCTAssertEqual(version, "0.6.1")
        XCTAssertEqual(MockBabelDocMetadataURLProtocol.requestCount, 1)
    }

    func testLatestPublishedVersionUsesTsinghuaSimpleIndexWhenSelected() async throws {
        let session = makeSession()
        MockBabelDocMetadataURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://pypi.tuna.tsinghua.edu.cn/simple/babeldoc/")
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html; charset=utf-8"]
            )!
            return (
                response,
                Data(
                    #"""
                    <html>
                      <body>
                        <a href="https://pypi.tuna.tsinghua.edu.cn/packages/babeldoc-0.6.2-py3-none-any.whl">babeldoc-0.6.2-py3-none-any.whl</a>
                        <a href="https://pypi.tuna.tsinghua.edu.cn/packages/babeldoc-0.6.4-py3-none-any.whl">babeldoc-0.6.4-py3-none-any.whl</a>
                      </body>
                    </html>
                    """#.utf8
                )
            )
        }

        let manager = BabelDocToolManager(session: session, installSource: .tsinghua)

        let version = try await manager.latestPublishedVersion()

        XCTAssertEqual(version, "0.6.4")
        XCTAssertEqual(MockBabelDocMetadataURLProtocol.requestCount, 1)
    }

    func testLatestPublishedVersionFallsBackToMetadataReleasesWhenSimpleIndexIsStale() async throws {
        let session = makeSession()
        MockBabelDocMetadataURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: [
                    "Content-Type": request.url?.absoluteString.contains("/simple/") == true
                        ? "text/html; charset=utf-8"
                        : "application/json"
                ]
            )!

            if request.url?.absoluteString == "https://pypi.tuna.tsinghua.edu.cn/simple/babeldoc/" {
                return (response, Data("<html><body>No package links yet.</body></html>".utf8))
            }

            XCTAssertEqual(request.url?.absoluteString, "https://pypi.tuna.tsinghua.edu.cn/pypi/BabelDOC/json")
            return (
                response,
                Data(
                    #"""
                    {
                      "info": {
                        "version": "0.6.2"
                      },
                      "releases": {
                        "0.6.2": [],
                        "0.6.5": []
                      }
                    }
                    """#.utf8
                )
            )
        }

        let manager = BabelDocToolManager(session: session, installSource: .tsinghua)

        let version = try await manager.latestPublishedVersion()

        XCTAssertEqual(version, "0.6.5")
        XCTAssertEqual(MockBabelDocMetadataURLProtocol.requestCount, 2)
    }

    func testResolvedInstallVersionUsesLatestKeywordAndEmptyValue() async throws {
        let session = makeSession()
        MockBabelDocMetadataURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html; charset=utf-8"]
            )!
            return (
                response,
                Data(
                    #"""
                    <html>
                      <body>
                        <a href="https://files.pythonhosted.org/packages/babeldoc-0.6.2-py3-none-any.whl">babeldoc-0.6.2-py3-none-any.whl</a>
                      </body>
                    </html>
                    """#.utf8
                )
            )
        }

        let manager = BabelDocToolManager(session: session, installSource: .official)

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

        let manager = BabelDocToolManager(session: session, installSource: .official)

        let version = try await manager.resolvedInstallVersion("0.5.24")

        XCTAssertEqual(version, "0.5.24")
        XCTAssertEqual(MockBabelDocMetadataURLProtocol.requestCount, 0)
    }

    func testInstallArgumentsUseSelectedSourceIndex() {
        XCTAssertEqual(
            BabelDocToolManager.installArguments(version: "0.6.1", source: .official),
            ["tool", "install", "--force", "--default-index", "https://pypi.org/simple", "BabelDOC==0.6.1"]
        )
        XCTAssertEqual(
            BabelDocToolManager.installArguments(version: "0.6.1", source: .tsinghua),
            ["tool", "install", "--force", "--default-index", "https://pypi.tuna.tsinghua.edu.cn/simple", "BabelDOC==0.6.1"]
        )
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockBabelDocMetadataURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeTemporaryManager(
        runner: ProcessRunner = ProcessRunner()
    ) throws -> (manager: BabelDocToolManager, rootURL: URL) {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        return (
            BabelDocToolManager(
                fileStore: PaperFileStore(applicationSupportDirectory: rootURL),
                runner: runner
            ),
            rootURL
        )
    }

    private func writeExecutable(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
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
