import Foundation

protocol LibrarySyncTransport: Sendable {
    func info() async throws -> LibrarySyncInfo
    func changes(after: UInt64, until: UInt64?) async throws -> LibrarySyncPage
    func push(_ request: LibrarySyncPush) async throws -> LibrarySyncReceipt
    func hasBlob(_ hash: String) async throws -> Bool
    func upload(_ file: URL, hash: String) async throws
    func download(_ hash: String) async throws -> URL
}

/// Authorization never follows redirects, including redirects to another HTTPS host.
private final class LibrarySyncRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

actor LibrarySyncClient: LibrarySyncTransport {
    private let baseURL: URL
    private let token: String
    private let session: URLSession

    deinit { session.invalidateAndCancel() }

    init(baseURL: URL, token: String, configuration: URLSessionConfiguration = .ephemeral) throws {
        self.baseURL = try Self.validatedBaseURL(baseURL)
        guard token.range(of: #"^fs1_[0-9a-f]{64}$"#, options: .regularExpression) != nil else {
            throw LibrarySyncError.message("The device credential is not valid.")
        }
        self.token = token
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 900
        configuration.httpMaximumConnectionsPerHost = 2
        self.session = URLSession(configuration: configuration, delegate: LibrarySyncRedirectPolicy(), delegateQueue: nil)
    }

    static func validatedBaseURL(_ url: URL) throws -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https", components.host?.isEmpty == false,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw LibrarySyncError.message("Enter an HTTPS server URL without credentials, query, or fragment.")
        }
        if !components.path.hasSuffix("/") { components.path += "/" }
        guard let normalized = components.url else {
            throw LibrarySyncError.message("The sync server URL is not valid.")
        }
        return normalized
    }

    func info() async throws -> LibrarySyncInfo {
        try await json(request("v1/info"))
    }

    func changes(after: UInt64, until: UInt64?) async throws -> LibrarySyncPage {
        var components = URLComponents(url: baseURL.appendingPathComponent("v1/changes"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "after", value: String(after)), URLQueryItem(name: "limit", value: "100")]
        if let until { components.queryItems?.append(.init(name: "until", value: String(until))) }
        var outgoing = request("v1/changes")
        outgoing.url = components.url
        return try await json(outgoing)
    }

    func push(_ body: LibrarySyncPush) async throws -> LibrarySyncReceipt {
        var outgoing = request("v1/changes", method: "POST")
        outgoing.setValue("application/json", forHTTPHeaderField: "Content-Type")
        outgoing.httpBody = try LibrarySyncCoding.encoder().encode(body)
        return try await json(outgoing)
    }

    func hasBlob(_ hash: String) async throws -> Bool {
        try Self.validateHash(hash)
        return try await retry {
            let (data, response) = try await session.data(for: request("v1/blobs/" + hash, method: "HEAD"))
            if (response as? HTTPURLResponse)?.statusCode == 404 { return false }
            try check(response, data: data)
            return true
        }
    }

    func upload(_ file: URL, hash: String) async throws {
        try Self.validateHash(hash)
        var outgoing = request("v1/blobs/" + hash, method: "PUT")
        outgoing.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        outgoing.setValue(String(size), forHTTPHeaderField: "Content-Length")
        try await retry {
            let (data, response) = try await session.upload(for: outgoing, fromFile: file)
            try check(response, data: data)
        }
    }

    func download(_ hash: String) async throws -> URL {
        try Self.validateHash(hash)
        return try await retry {
            let (file, response) = try await session.download(for: request("v1/blobs/" + hash))
            do {
                try check(response, data: Data())
                return file
            } catch {
                try? FileManager.default.removeItem(at: file)
                throw error
            }
        }
    }

    private func request(_ path: String, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func json<Value: Decodable>(_ outgoing: URLRequest) async throws -> Value {
        let data = try await retry {
            let (data, response) = try await session.data(for: outgoing)
            try check(response, data: data)
            return data
        }
        guard data.count <= 8 * 1024 * 1024 else {
            throw LibrarySyncError.message("The sync server response is too large.")
        }
        return try LibrarySyncCoding.decoder().decode(Value.self, from: data)
    }

    private func retry<Value>(_ operation: () async throws -> Value) async throws -> Value {
        for attempt in 0...5 {
            try Task.checkCancellation()
            do { return try await operation() }
            catch {
                let delay: TimeInterval
                if case LibrarySyncError.server(let status, _, let requested) = error, status == 429 || status == 503 {
                    delay = requested ?? pow(2, Double(attempt))
                } else if let urlError = error as? URLError,
                          [.networkConnectionLost, .timedOut].contains(urlError.code), attempt < 2 {
                    delay = pow(2, Double(attempt))
                } else { throw error }
                guard attempt < 5, delay <= 30 else { throw error }
                try await Task.sleep(for: .seconds(max(0.2, delay) + Double.random(in: 0...0.3)))
            }
        }
        throw LibrarySyncError.message("The sync server response is not valid.")
    }

    private func check(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw LibrarySyncError.message("The sync server response is not valid.")
        }
        guard (200..<300).contains(http.statusCode) else {
            struct Failure: Decodable {
                struct Details: Decodable { var code: String; var current: LibrarySyncRecord? }
                var error: Details
            }
            let details = try? LibrarySyncCoding.decoder().decode(Failure.self, from: data).error
            if http.statusCode == 409, details?.code == "revision_conflict" {
                throw LibrarySyncError.conflict(details?.current)
            }
            throw LibrarySyncError.server(
                status: http.statusCode, code: details?.code ?? "http_error",
                retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            )
        }
    }

    static func validateHash(_ hash: String) throws {
        guard hash.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil else {
            throw LibrarySyncError.message("The synced file hash is not valid.")
        }
    }
}
