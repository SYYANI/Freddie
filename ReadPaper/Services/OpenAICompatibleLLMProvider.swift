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
    let thinkingMode: LLMThinkingMode?
    let reasoningEffort: LLMReasoningEffort?
    let timeoutProfile: LLMNetworkTimeoutProfile?

    init(
        baseURL: URL,
        apiKey: String,
        model: String,
        messages: [LLMCompletionMessage],
        temperature: Double? = nil,
        topP: Double? = nil,
        maxTokens: Int? = nil,
        thinkingMode: LLMThinkingMode? = nil,
        reasoningEffort: LLMReasoningEffort? = nil,
        timeoutProfile: LLMNetworkTimeoutProfile? = nil
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.messages = messages
        self.temperature = temperature
        self.topP = topP
        self.maxTokens = maxTokens
        self.thinkingMode = thinkingMode
        self.reasoningEffort = reasoningEffort
        self.timeoutProfile = timeoutProfile
    }
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
            return AppLocalization.format("Invalid provider configuration: %@", message)
        case .network(let message):
            return message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? AppLocalization.localized("Provider request failed due to a network or server error.")
                : message
        case .timedOut(_, let message):
            return message?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? message
                : AppLocalization.localized("Request timed out.")
        case .unauthorized:
            return AppLocalization.localized("Authentication failed. Please check API key and endpoint permission.")
        case .cancelled:
            return AppLocalization.localized("The request was cancelled.")
        case .emptyResponse:
            return AppLocalization.localized("The provider returned an empty response.")
        case .unknown(let message):
            return message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? AppLocalization.localized("Provider request failed with an unknown error.")
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
        guard let endpoint = URL(string: inferredChatEndpoint(from: routePlan)) else {
            throw LLMProviderError.invalidConfiguration(
                AppLocalization.format(
                    "Invalid provider chat endpoint for base URL: %@",
                    request.baseURL.absoluteString
                )
            )
        }

        var urlRequestBuilder = URLRequest(url: endpoint)
        urlRequestBuilder.httpMethod = "POST"
        urlRequestBuilder.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequestBuilder.setValue("Bearer \(request.apiKey)", forHTTPHeaderField: "Authorization")
        urlRequestBuilder.httpBody = try JSONEncoder().encode(LLMChatCompletionBody(request: request))
        let urlRequest = urlRequestBuilder

        let session = makeURLSession(timeoutProfile: request.timeoutProfile)

        return try await withResourceTimeout(
            seconds: request.timeoutProfile?.resourceTimeoutSeconds,
            timeoutKind: .resource
        ) {
            let (data, response) = try await session.data(for: urlRequest)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            guard httpResponse.statusCode == 200 else {
                throw Self.apiError(data: data, statusCode: httpResponse.statusCode)
            }

            let decoded = try JSONDecoder().decode(LLMChatCompletionResponseBody.self, from: data)
            let text = decoded.choices?.first?.message?.content ?? ""
            return LLMCompletionResponse(
                text: text,
                resolvedEndpoint: makeResolvedEndpointSnapshot(from: routePlan)
            )
        }
    }

    private func makeURLSession(timeoutProfile: LLMNetworkTimeoutProfile?) -> URLSession {
        if let configuration = sessionConfigurationOverride
            ?? Self.makeURLSessionConfiguration(timeoutProfile: timeoutProfile) {
            return URLSession(configuration: configuration)
        }
        return URLSession.shared
    }

    private static func apiError(data: Data, statusCode: Int) -> APIError {
        var message = "status code \(statusCode)"
        if let body = try? JSONDecoder().decode(LLMAPIErrorResponseBody.self, from: data),
           let serverMessage = body.error?.message,
           serverMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            message = serverMessage
        }
        return APIError.responseUnsuccessful(description: message, statusCode: statusCode)
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
                throw LLMProviderError.timedOut(
                    kind: timeoutKind,
                    message: AppLocalization.localized("Request timed out.")
                )
            }

            guard let firstResult = try await group.next() else {
                group.cancelAll()
                throw LLMProviderError.timedOut(
                    kind: timeoutKind,
                    message: AppLocalization.localized("Request timed out.")
                )
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
            return .timedOut(kind: .request, message: AppLocalization.localized("Request timed out."))
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
                        retryDetails = AppLocalization.format(
                            " Retried with resolved endpoint %@.",
                            fallbackEndpoint
                        )
                    } else {
                        retryDetails = ""
                    }
                    return .network(
                        AppLocalization.format(
                            "HTTP 404: endpoint not found. Current base URL is %@. Resolved endpoint is %@.%@ Expected OpenAI-compatible chat endpoint is usually '<baseURL>/chat/completions'.",
                            baseURL.absoluteString,
                            primaryEndpoint,
                            retryDetails
                        )
                    )
                }
                let details = description.trimmingCharacters(in: .whitespacesAndNewlines)
                if details.isEmpty == false {
                    return .network(AppLocalization.format("HTTP %d: %@", statusCode, details))
                }
                return .network(AppLocalization.format("HTTP %d: %@", statusCode, apiError.displayDescription))
            case .requestFailed(let description):
                let details = description.trimmingCharacters(in: .whitespacesAndNewlines)
                if details.isEmpty == false {
                    return .network(details)
                }
                return .network(apiError.displayDescription)
            case .timeOutError:
                return .timedOut(kind: .request, message: AppLocalization.localized("Request timed out."))
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

private struct LLMChatCompletionBody: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    struct Thinking: Encodable {
        let type: String
    }

    let model: String
    let messages: [Message]
    let temperature: Double?
    let topP: Double?
    let maxTokens: Int?
    let reasoningEffort: String?
    let thinking: Thinking?

    init(request: LLMCompletionRequest) {
        model = request.model
        messages = request.messages.map { Message(role: $0.role, content: $0.content) }
        temperature = request.temperature
        topP = request.topP
        maxTokens = request.maxTokens

        switch request.thinkingMode {
        case .disabled:
            thinking = Thinking(type: "disabled")
            reasoningEffort = nil
        case .enabled:
            thinking = Thinking(type: "enabled")
            reasoningEffort = request.reasoningEffort?.rawValue
        case nil:
            thinking = nil
            reasoningEffort = request.reasoningEffort?.rawValue
        }
    }

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case temperature
        case topP = "top_p"
        case maxTokens = "max_tokens"
        case reasoningEffort = "reasoning_effort"
        case thinking
    }
}

private struct LLMChatCompletionResponseBody: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String?
        }

        let message: Message?
    }

    let choices: [Choice]?
}

private struct LLMAPIErrorResponseBody: Decodable {
    struct Error: Decodable {
        let message: String?
    }

    let error: Error?
}
