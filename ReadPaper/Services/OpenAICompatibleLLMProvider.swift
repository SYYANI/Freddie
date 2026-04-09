import Foundation
@preconcurrency import SwiftOpenAI

struct LLMCompletionMessage: Sendable, Equatable {
    let role: String
    let content: String
}

struct LLMResolvedEndpoint: Equatable, Sendable {
    let url: String
    let host: String?
    let path: String?
}

struct LLMNetworkTimeoutProfile: Equatable, Sendable {
    let requestTimeoutSeconds: TimeInterval
    let resourceTimeoutSeconds: TimeInterval

    init(
        requestTimeoutSeconds: TimeInterval,
        resourceTimeoutSeconds: TimeInterval
    ) {
        self.requestTimeoutSeconds = max(1, requestTimeoutSeconds)
        self.resourceTimeoutSeconds = max(1, resourceTimeoutSeconds)
    }

    static let translationDefault = LLMNetworkTimeoutProfile(
        requestTimeoutSeconds: 120,
        resourceTimeoutSeconds: 600
    )

    static func validation(timeoutSeconds: TimeInterval) -> LLMNetworkTimeoutProfile {
        let clamped = max(1, timeoutSeconds)
        return LLMNetworkTimeoutProfile(
            requestTimeoutSeconds: clamped,
            resourceTimeoutSeconds: clamped
        )
    }
}

struct LLMCompletionRequest: Sendable {
    let baseURL: URL
    let apiKey: String
    let model: String
    let messages: [LLMCompletionMessage]
    let temperature: Double?
    let topP: Double?
    let maxTokens: Int?
    let timeoutProfile: LLMNetworkTimeoutProfile?
}

struct LLMCompletionResponse: Equatable, Sendable {
    let text: String
    let resolvedEndpoint: LLMResolvedEndpoint?
}

enum LLMProviderError: LocalizedError, Equatable {
    enum TimeoutKind: String, Sendable {
        case request
        case resource
    }

    case invalidConfiguration(String)
    case network(String)
    case timedOut(kind: TimeoutKind, message: String?)
    case unauthorized
    case cancelled
    case emptyResponse
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message):
            return "Invalid provider configuration: \(message)"
        case .network(let message):
            return message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Provider request failed due to a network or server error."
                : message
        case .timedOut(_, let message):
            return message?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? message
                : "Request timed out."
        case .unauthorized:
            return "Authentication failed. Please check API key and endpoint permission."
        case .cancelled:
            return "The request was cancelled."
        case .emptyResponse:
            return "The provider returned an empty response."
        case .unknown(let message):
            return message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Provider request failed with an unknown error."
                : message
        }
    }
}

nonisolated struct OpenAICompatibleLLMProvider: Sendable {
    struct ServiceRoutePlan: Equatable {
        let overrideBaseURL: String
        let proxyPath: String?
        let version: String?
    }

    private let sessionConfigurationOverride: URLSessionConfiguration?

    init(sessionConfigurationOverride: URLSessionConfiguration? = nil) {
        self.sessionConfigurationOverride = sessionConfigurationOverride
    }

    func complete(request: LLMCompletionRequest) async throws -> LLMCompletionResponse {
        let primaryPlan = serviceRoutePlan(from: request.baseURL)

        do {
            return try await performComplete(request: request, routePlan: primaryPlan)
        } catch let primaryError {
            if let fallbackPlan = fallbackRoutePlanRemovingVersionIfNeeded(primaryPlan: primaryPlan, error: primaryError) {
                do {
                    return try await performComplete(request: request, routePlan: fallbackPlan)
                } catch let fallbackError {
                    throw mapError(
                        fallbackError,
                        baseURL: request.baseURL,
                        primaryPlan: primaryPlan,
                        fallbackPlanTried: fallbackPlan
                    )
                }
            }

            throw mapError(
                primaryError,
                baseURL: request.baseURL,
                primaryPlan: primaryPlan,
                fallbackPlanTried: nil
            )
        }
    }

    static func makeURLSessionConfiguration(
        timeoutProfile: LLMNetworkTimeoutProfile?
    ) -> URLSessionConfiguration? {
        guard let timeoutProfile else {
            return nil
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeoutProfile.requestTimeoutSeconds
        configuration.timeoutIntervalForResource = timeoutProfile.resourceTimeoutSeconds
        return configuration
    }

    func serviceRoutePlan(from baseURL: URL) -> ServiceRoutePlan {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let rawPath = components?.path ?? ""
        let trimmedPath = rawPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        var pathSegments = trimmedPath.isEmpty ? [] : trimmedPath.split(separator: "/").map(String.init)
        var version: String? = "v1"
        if let lastSegment = pathSegments.last, isVersionSegment(lastSegment) {
            version = lastSegment
            pathSegments.removeLast()
        }

        let proxyPath = pathSegments.isEmpty ? nil : pathSegments.joined(separator: "/")

        components?.path = ""
        components?.query = nil
        components?.fragment = nil
        let overrideBaseURL = components?.url?.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            ?? baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        return ServiceRoutePlan(
            overrideBaseURL: overrideBaseURL,
            proxyPath: proxyPath,
            version: version
        )
    }

    func inferredChatEndpoint(from routePlan: ServiceRoutePlan) -> String {
        guard var components = URLComponents(string: routePlan.overrideBaseURL) else {
            return "<invalid endpoint>"
        }

        var segments: [String] = []
        if let proxyPath = routePlan.proxyPath?.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
           proxyPath.isEmpty == false {
            segments.append(proxyPath)
        }
        if let version = routePlan.version, version.isEmpty == false {
            segments.append(version)
        }
        segments.append("chat")
        segments.append("completions")

        components.path = "/" + segments.joined(separator: "/")
        components.query = nil
        components.fragment = nil
        return components.url?.absoluteString ?? "<invalid endpoint>"
    }

    private func performComplete(
        request: LLMCompletionRequest,
        routePlan: ServiceRoutePlan
    ) async throws -> LLMCompletionResponse {
        let service = makeService(
            routePlan: routePlan,
            apiKey: request.apiKey,
            timeoutProfile: request.timeoutProfile
        )

        let parameters = ChatCompletionParameters(
            messages: request.messages.map(makeMessage),
            model: .custom(request.model),
            maxTokens: request.maxTokens,
            temperature: request.temperature,
            topProbability: request.topP
        )

        return try await withResourceTimeout(
            seconds: request.timeoutProfile?.resourceTimeoutSeconds,
            timeoutKind: .resource
        ) {
            let response = try await service.startChat(parameters: parameters)
            let text = response.choices?.first?.message?.content ?? ""
            return LLMCompletionResponse(
                text: text,
                resolvedEndpoint: makeResolvedEndpointSnapshot(from: routePlan)
            )
        }
    }

    private func makeResolvedEndpointSnapshot(from routePlan: ServiceRoutePlan) -> LLMResolvedEndpoint? {
        guard let endpoint = URL(string: inferredChatEndpoint(from: routePlan)) else {
            return nil
        }
        let host = endpoint.host?.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = endpoint.path.trimmingCharacters(in: .whitespacesAndNewlines)
        return LLMResolvedEndpoint(
            url: endpoint.absoluteString,
            host: host?.isEmpty == false ? host : nil,
            path: path.isEmpty == false ? path : nil
        )
    }

    private func makeService(
        routePlan: ServiceRoutePlan,
        apiKey: String,
        timeoutProfile: LLMNetworkTimeoutProfile?
    ) -> OpenAIService {
        let httpClient: HTTPClient?
        if let configuration = sessionConfigurationOverride ?? Self.makeURLSessionConfiguration(timeoutProfile: timeoutProfile) {
            let session = URLSession(configuration: configuration)
            httpClient = URLSessionHTTPClientAdapter(urlSession: session)
        } else {
            httpClient = nil
        }
        return OpenAIServiceFactory.service(
            apiKey: apiKey,
            overrideBaseURL: routePlan.overrideBaseURL,
            proxyPath: routePlan.proxyPath,
            overrideVersion: routePlan.version,
            httpClient: httpClient,
            debugEnabled: false
        )
    }

    private func makeMessage(_ message: LLMCompletionMessage) -> ChatCompletionParameters.Message {
        ChatCompletionParameters.Message(
            role: mapRole(message.role),
            content: .text(message.content)
        )
    }

    private func mapRole(_ role: String) -> ChatCompletionParameters.Message.Role {
        switch role {
        case "system":
            return .system
        case "assistant":
            return .assistant
        default:
            return .user
        }
    }

    private func withResourceTimeout<T: Sendable>(
        seconds: TimeInterval?,
        timeoutKind: LLMProviderError.TimeoutKind,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        guard let seconds else {
            return try await operation()
        }

        let clampedSeconds = max(1, seconds)
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(clampedSeconds))
                throw LLMProviderError.timedOut(kind: timeoutKind, message: "Request timed out.")
            }

            guard let firstResult = try await group.next() else {
                group.cancelAll()
                throw LLMProviderError.timedOut(kind: timeoutKind, message: "Request timed out.")
            }
            group.cancelAll()
            return firstResult
        }
    }

    private func mapError(
        _ error: Error,
        baseURL: URL,
        primaryPlan: ServiceRoutePlan,
        fallbackPlanTried: ServiceRoutePlan?
    ) -> LLMProviderError {
        if let providerError = error as? LLMProviderError {
            return providerError
        }

        if error is CancellationError {
            return .cancelled
        }

        if isTimeoutLikeError(error) {
            return .timedOut(kind: .request, message: "Request timed out.")
        }

        if let apiError = error as? APIError {
            switch apiError {
            case .responseUnsuccessful(let description, let statusCode):
                if statusCode == 401 || statusCode == 403 {
                    return .unauthorized
                }
                if statusCode == 404 {
                    let primaryEndpoint = inferredChatEndpoint(from: primaryPlan)
                    let retryDetails: String
                    if let fallbackPlanTried {
                        let fallbackEndpoint = inferredChatEndpoint(from: fallbackPlanTried)
                        retryDetails = " Retried with resolved endpoint \(fallbackEndpoint)."
                    } else {
                        retryDetails = ""
                    }
                    return .network(
                        "HTTP 404: endpoint not found. Current base URL is \(baseURL.absoluteString). " +
                        "Resolved endpoint is \(primaryEndpoint)." +
                        retryDetails +
                        " Expected OpenAI-compatible chat endpoint is usually '<baseURL>/chat/completions'."
                    )
                }
                let details = description.trimmingCharacters(in: .whitespacesAndNewlines)
                if details.isEmpty == false {
                    return .network("HTTP \(statusCode): \(details)")
                }
                return .network("HTTP \(statusCode): \(apiError.displayDescription)")
            case .requestFailed(let description):
                let details = description.trimmingCharacters(in: .whitespacesAndNewlines)
                if details.isEmpty == false {
                    return .network(details)
                }
                return .network(apiError.displayDescription)
            case .timeOutError:
                return .timedOut(kind: .request, message: "Request timed out.")
            case .jsonDecodingFailure(let description):
                return .unknown(description)
            case .dataCouldNotBeReadMissingData(let description):
                return .unknown(description)
            case .invalidData, .bothDecodingStrategiesFailed:
                return .unknown(apiError.displayDescription)
            }
        }

        return .unknown(error.localizedDescription)
    }

    private func fallbackRoutePlanRemovingVersionIfNeeded(
        primaryPlan: ServiceRoutePlan,
        error: Error
    ) -> ServiceRoutePlan? {
        guard isHTTP404(error) else {
            return nil
        }
        guard (primaryPlan.version ?? "").lowercased() == "v1" else {
            return nil
        }
        return ServiceRoutePlan(
            overrideBaseURL: primaryPlan.overrideBaseURL,
            proxyPath: primaryPlan.proxyPath,
            version: ""
        )
    }

    private func isHTTP404(_ error: Error) -> Bool {
        guard case .responseUnsuccessful(_, let statusCode) = (error as? APIError) else {
            return false
        }
        return statusCode == 404
    }

    private func isVersionSegment(_ value: String) -> Bool {
        let lowercased = value.lowercased()
        guard lowercased.hasPrefix("v") else {
            return false
        }
        let suffix = lowercased.dropFirst()
        return suffix.isEmpty == false && suffix.allSatisfy(\.isNumber)
    }

    private func isTimeoutLikeError(_ error: Error) -> Bool {
        if let urlError = error as? URLError, urlError.code == .timedOut {
            return true
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == URLError.timedOut.rawValue {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ETIMEDOUT) {
            return true
        }
        let message = nsError.localizedDescription.lowercased()
        return message.contains("timed out") || message.contains("timeout")
    }
}
