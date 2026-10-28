import Foundation
import Network
import Observation
import SwiftData

/// The local API the browser extension in `BrowserExtension/` saves pages through, after
/// Zotero's connector server: plain HTTP bound to 127.0.0.1, running while Freddie runs.
enum BrowserClipperAPI {
    static let port: UInt16 = 23240
    static let version = 1
    /// Required on every request. A web page can only send a custom header after a CORS
    /// preflight, which this server never approves, so pages cannot call the API themselves.
    static let headerName = "x-freddie-clipper"
    /// Origins of extension pages; a web page's origin is refused even with the header.
    static let extensionOriginPrefixes = ["chrome-extension://", "moz-extension://", "safari-web-extension://"]
    /// Large enough for a base64 PDF of about 100 MB.
    static let maxBodyLength = 140 << 20
    static let maxHeaderLength = 32 << 10
}

struct BrowserClipperHTTPRequest: Equatable, Sendable {
    var method: String
    var path: String
    /// Names are lowercased.
    var headers: [String: String]
    var body: Data

    enum ParseResult: Equatable, Sendable {
        case incomplete
        case complete(BrowserClipperHTTPRequest)
        case invalid(status: Int)
    }

    /// Reads one request with a `Content-Length` body; chunked bodies are not supported.
    static func parse(
        _ buffer: Data,
        maxBodyLength: Int = BrowserClipperAPI.maxBodyLength
    ) -> ParseResult {
        guard let headerEnd = buffer.firstRange(of: Data("\r\n\r\n".utf8)) else {
            return buffer.count > BrowserClipperAPI.maxHeaderLength ? .invalid(status: 431) : .incomplete
        }
        guard let head = String(data: buffer[buffer.startIndex..<headerEnd.lowerBound], encoding: .utf8) else {
            return .invalid(status: 400)
        }
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else {
            return .invalid(status: 400)
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return .invalid(status: 400) }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        if headers["transfer-encoding"] != nil {
            return .invalid(status: 501)
        }
        let contentLength: Int
        if let value = headers["content-length"] {
            guard let length = Int(value), length >= 0 else { return .invalid(status: 400) }
            contentLength = length
        } else {
            contentLength = 0
        }
        guard contentLength <= maxBodyLength else { return .invalid(status: 413) }

        let bodyStart = headerEnd.upperBound
        guard buffer.endIndex - bodyStart >= contentLength else { return .incomplete }
        let target = String(requestLine[1])
        return .complete(BrowserClipperHTTPRequest(
            method: String(requestLine[0]).uppercased(),
            path: String(target.prefix { $0 != "?" }),
            headers: headers,
            body: Data(buffer[bodyStart..<(bodyStart + contentLength)])
        ))
    }
}

struct BrowserClipperHTTPResponse: Equatable, Sendable {
    var status: Int
    var body: Data

    static func json(_ status: Int, _ value: some Encodable) -> BrowserClipperHTTPResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return BrowserClipperHTTPResponse(status: status, body: (try? encoder.encode(value)) ?? Data("{}".utf8))
    }

    static func error(_ status: Int, _ message: String) -> BrowserClipperHTTPResponse {
        json(status, ["error": message])
    }

    /// No CORS headers: only extensions, which skip CORS for hosts they may access, read responses.
    var serialized: Data {
        var head = "HTTP/1.1 \(status) \(HTTPURLResponse.localizedString(forStatusCode: status).capitalized)\r\n"
        head += "Content-Type: application/json; charset=utf-8\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}

@MainActor
final class BrowserClipperRequestHandler {
    struct Ping: Encodable {
        var app = "Freddie"
        var version: String
        var api = BrowserClipperAPI.version
    }

    struct FolderList: Encodable {
        struct Folder: Encodable {
            var id: UUID
            var name: String
        }

        var folders: [Folder]
    }

    struct SaveResult: Encodable {
        /// `saved`, or `exists` when the library already had the page.
        var status: String
        var paperID: UUID
        var title: String
    }

    private let modelContainer: ModelContainer
    private let port: UInt16
    private let makeImporter: @MainActor () -> BrowserClipImporter

    init(
        modelContainer: ModelContainer,
        port: UInt16 = BrowserClipperAPI.port,
        makeImporter: @escaping @MainActor () -> BrowserClipImporter = { BrowserClipImporter() }
    ) {
        self.modelContainer = modelContainer
        self.port = port
        self.makeImporter = makeImporter
    }

    func response(to request: BrowserClipperHTTPRequest) async -> BrowserClipperHTTPResponse {
        if let rejection = Self.rejection(for: request, port: port) {
            return rejection
        }
        let modelContext = modelContainer.mainContext
        switch (request.method, request.path) {
        case ("GET", "/ping"):
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
            return .json(200, Ping(version: version))
        case ("GET", "/folders"):
            do {
                let folders = try modelContext.fetch(FetchDescriptor<PaperFolder>())
                    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                    .map { FolderList.Folder(id: $0.id, name: $0.name) }
                return .json(200, FolderList(folders: folders))
            } catch {
                return .error(500, error.localizedDescription)
            }
        case ("POST", "/save"):
            let clip: BrowserClip
            do {
                clip = try await Self.decode(BrowserClip.self, from: request.body)
            } catch {
                return .error(400, error.localizedDescription)
            }
            do {
                let result = try await makeImporter().importClip(clip, modelContext: modelContext)
                return .json(200, SaveResult(
                    status: result.isExisting ? "exists" : "saved",
                    paperID: result.paper.id,
                    title: result.paper.title
                ))
            } catch {
                return .error(500, error.localizedDescription)
            }
        case (_, "/ping"), (_, "/folders"), (_, "/save"):
            return .error(405, "Method not allowed.")
        default:
            return .error(404, "Not found.")
        }
    }

    /// Requests that did not come from the extension. The host check stops DNS rebinding:
    /// a page on a domain resolving to 127.0.0.1 would otherwise be same-origin with the API.
    nonisolated static func rejection(
        for request: BrowserClipperHTTPRequest,
        port: UInt16
    ) -> BrowserClipperHTTPResponse? {
        let allowedHosts = ["127.0.0.1:\(port)", "localhost:\(port)"]
        guard let host = request.headers["host"]?.lowercased(), allowedHosts.contains(host) else {
            return .error(403, "Forbidden host.")
        }
        if let origin = request.headers["origin"]?.lowercased(),
           !BrowserClipperAPI.extensionOriginPrefixes.contains(where: { origin.hasPrefix($0) }) {
            return .error(403, "Forbidden origin.")
        }
        guard request.headers[BrowserClipperAPI.headerName] != nil else {
            return .error(403, "Missing \(BrowserClipperAPI.headerName) header.")
        }
        return nil
    }

    /// Off the main actor: a clip with a PDF can be a 100 MB document.
    nonisolated private static func decode<Value: Decodable>(_ type: Value.Type, from body: Data) async throws -> Value {
        try JSONDecoder().decode(type, from: body)
    }
}

/// Listens on the loopback interface for the browser extension.
@MainActor
@Observable
final class BrowserClipperServer {
    enum State: Equatable {
        case stopped
        case listening(port: UInt16)
        case failed(String)
    }

    static let shared = BrowserClipperServer()

    private(set) var state: State = .stopped
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private let queue = DispatchQueue(label: "com.yiyan.ReadPaper.browser-clipper")

    func start(modelContainer: ModelContainer, port: UInt16 = BrowserClipperAPI.port) {
        guard listener == nil, let endpointPort = NWEndpoint.Port(rawValue: port) else { return }
        let handler = BrowserClipperRequestHandler(modelContainer: modelContainer, port: port)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: endpointPort)
        parameters.acceptLocalOnly = true

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        let queue = queue
        listener.newConnectionHandler = { connection in
            BrowserClipperConnection(connection: connection, handler: handler, queue: queue).start()
        }
        listener.stateUpdateHandler = { [weak self] listenerState in
            Task { @MainActor in
                self?.update(listenerState, port: port)
            }
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        state = .stopped
    }

    private func update(_ listenerState: NWListener.State, port: UInt16) {
        switch listenerState {
        case .ready:
            state = .listening(port: port)
        case .failed(let error):
            // Usually another copy of Freddie holds the port.
            state = .failed(error.localizedDescription)
            listener?.cancel()
            listener = nil
        case .cancelled:
            if case .listening = state {
                state = .stopped
            }
        default:
            break
        }
    }

    /// Unit tests run inside the app; they must not take the port from a running Freddie.
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}

/// One request and response per connection. The buffer is only touched on `queue`.
private final class BrowserClipperConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let handler: BrowserClipperRequestHandler
    private let queue: DispatchQueue
    private var buffer = Data()

    init(connection: NWConnection, handler: BrowserClipperRequestHandler, queue: DispatchQueue) {
        self.connection = connection
        self.handler = handler
        self.queue = queue
    }

    func start() {
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4 << 20) { [self] data, _, isComplete, error in
            if let data {
                buffer.append(data)
            }
            switch BrowserClipperHTTPRequest.parse(buffer) {
            case .incomplete:
                if isComplete || error != nil {
                    connection.cancel()
                } else {
                    receive()
                }
            case .invalid(let status):
                send(.error(status, HTTPURLResponse.localizedString(forStatusCode: status)))
            case .complete(let request):
                buffer = Data()
                let handler = handler
                Task { @MainActor in
                    let response = await handler.response(to: request)
                    self.send(response)
                }
            }
        }
    }

    private func send(_ response: BrowserClipperHTTPResponse) {
        connection.send(
            content: response.serialized,
            contentContext: .finalMessage,
            isComplete: true,
            completion: .contentProcessed { [connection] _ in connection.cancel() }
        )
    }
}

/// The extension ships inside the app. Chrome's "Load unpacked" keeps reading from the folder
/// it was given, so it gets a copy at a stable path outside the bundle, refreshed on each
/// export so it matches the running app.
enum BrowserExtensionFolder {
    static func export(fileStore: PaperFileStore = PaperFileStore(), bundle: Bundle = .main) throws -> URL {
        guard let source = bundle.url(forResource: "BrowserExtension", withExtension: nil) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let fileManager = fileStore.fileManager
        let destination = try fileStore.applicationSupportDirectory
            .appendingPathComponent("BrowserExtension", isDirectory: true)
        try fileStore.ensureDirectory(destination.deletingLastPathComponent())
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: source, to: destination)
        return destination
    }
}
