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

struct LLMWebSearchSource: Equatable, Sendable {
    let urlString: String
    let title: String?

    init?(urlString: String, title: String? = nil) {
        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else {
            return nil
        }
        self.urlString = Self.removingInternalWebSearchCallID(from: url).absoluteString
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = trimmedTitle?.isEmpty == false ? trimmedTitle : nil
    }

    static func detected(in text: String) -> [LLMWebSearchSource] {
        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue
        ) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var sources: [LLMWebSearchSource] = []
        detector.enumerateMatches(in: text, range: range) { result, _, _ in
            guard let url = result?.url,
                  let source = LLMWebSearchSource(urlString: url.absoluteString) else {
                return
            }
            sources.append(source)
        }
        var seen = Set<String>()
        return sources.filter { seen.insert($0.urlString).inserted }
    }

    private static func removingInternalWebSearchCallID(from url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let fragment = components.fragment,
              fragment.isEmpty == false else {
            return url
        }

        let fragmentComponents = fragment.split(
            separator: "&",
            omittingEmptySubsequences: false
        )
        let filteredComponents = fragmentComponents.filter { component in
            let encodedName = component.split(
                separator: "=",
                maxSplits: 1,
                omittingEmptySubsequences: false
            ).first.map(String.init) ?? ""
            let name = encodedName.removingPercentEncoding ?? encodedName
            return name.caseInsensitiveCompare("ws_call_id") != .orderedSame
        }
        guard filteredComponents.count != fragmentComponents.count else {
            return url
        }

        let remainingFragment = filteredComponents.map(String.init).joined(separator: "&")
        components.fragment = remainingFragment.isEmpty ? nil : remainingFragment
        return components.url ?? url
    }
}

/// A completed `web_search_call` output item returned by a Responses API
/// provider. DeepSeek's stateless API accepts these items back in a later
/// request's `input` as-is and restores the server-held search results.
struct LLMResponsesWebSearchCallItem: Equatable, Sendable {
    enum JSONValue: Codable, Equatable, Sendable {
        case null
        case bool(Bool)
        case number(Double)
        case string(String)
        case array([JSONValue])
        case object([String: JSONValue])

        var stringValue: String? {
            if case .string(let value) = self {
                return value
            }
            return nil
        }

        var arrayValue: [JSONValue]? {
            if case .array(let value) = self {
                return value
            }
            return nil
        }

        var objectValue: [String: JSONValue]? {
            if case .object(let value) = self {
                return value
            }
            return nil
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .null
                return
            }
            if let value = try? container.decode(Bool.self) {
                self = .bool(value)
                return
            }
            if let value = try? container.decode(Double.self) {
                self = .number(value)
                return
            }
            if let value = try? container.decode(String.self) {
                self = .string(value)
                return
            }
            if let value = try? container.decode([JSONValue].self) {
                self = .array(value)
                return
            }
            if let value = try? container.decode([String: JSONValue].self) {
                self = .object(value)
                return
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value in web_search_call item."
            )
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .null:
                try container.encodeNil()
            case .bool(let value):
                try container.encode(value)
            case .number(let value):
                try container.encode(value)
            case .string(let value):
                try container.encode(value)
            case .array(let values):
                try container.encode(values)
            case .object(let values):
                try container.encode(values)
            }
        }
    }

    let json: [String: JSONValue]

    init(json: [String: JSONValue]) {
        self.json = json
    }

    var id: String? {
        let value = json["id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    var isCompleted: Bool {
        guard let status = json["status"]?.stringValue else {
            // `output_item.done` events carry the full item but may omit the
            // status field; treat a finished item as replayable unless the
            // provider explicitly reports it as still in progress/incomplete.
            return true
        }
        return status == "completed"
    }

    var webSearchSources: [LLMWebSearchSource] {
        guard let action = json["action"]?.objectValue else {
            return []
        }
        var sources: [LLMWebSearchSource] = []
        if let directSource = Self.webSearchSource(from: action) {
            sources.append(directSource)
        }
        for value in action["sources"]?.arrayValue ?? [] {
            guard let object = value.objectValue,
                  let source = Self.webSearchSource(from: object) else {
                continue
            }
            sources.append(source)
        }
        return Self.unique(sources)
    }

    func encodeAsJSONObject(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(json)
    }

    func hasSameIdentity(as other: LLMResponsesWebSearchCallItem) -> Bool {
        if let id, let otherID = other.id {
            return id == otherID
        }
        return self == other
    }

    private static func webSearchSource(
        from object: [String: JSONValue]
    ) -> LLMWebSearchSource? {
        guard let url = object["url"]?.stringValue else {
            return nil
        }
        return LLMWebSearchSource(
            urlString: url,
            title: object["title"]?.stringValue
        )
    }

    private static func unique(_ sources: [LLMWebSearchSource]) -> [LLMWebSearchSource] {
        var seen = Set<String>()
        return sources.filter { seen.insert($0.urlString).inserted }
    }
}

struct LLMCompletionRequest: Sendable {
    let baseURL: URL
    let apiStyle: LLMAPIStyle
    let apiKey: String
    let model: String
    let messages: [LLMCompletionMessage]
    let temperature: Double?
    let topP: Double?
    let maxTokens: Int?
    let thinkingMode: LLMThinkingMode?
    let reasoningEffort: LLMReasoningEffort?
    let timeoutProfile: LLMNetworkTimeoutProfile?
    /// Requests the Responses API's server-side `web_search` tool. DeepSeek
    /// normally executes the search on the server and returns the final answer
    /// in the same response. If a response instead ends with only completed
    /// `web_search_call` items, the provider echoes those items back so the
    /// server can restore the search results and finish the answer.
    let webSearchEnabled: Bool
    /// Completed `web_search_call` items from a prior stateless response. When
    /// DeepSeek returns search calls but no visible message, replaying these
    /// items restores the server-side results so the model can answer without
    /// issuing a fresh paid search.
    let responsesWebSearchReplay: [LLMResponsesWebSearchCallItem]
    let responsesWebSearchContinuationPrompt: String?
    let responsesWebSearchContinuationCount: Int
    let traceHandler: (@Sendable (String) async -> Void)?

    init(
        baseURL: URL,
        apiStyle: LLMAPIStyle = .chatCompletions,
        apiKey: String,
        model: String,
        messages: [LLMCompletionMessage],
        temperature: Double? = nil,
        topP: Double? = nil,
        maxTokens: Int? = nil,
        thinkingMode: LLMThinkingMode? = nil,
        reasoningEffort: LLMReasoningEffort? = nil,
        timeoutProfile: LLMNetworkTimeoutProfile? = nil,
        webSearchEnabled: Bool = false,
        responsesWebSearchReplay: [LLMResponsesWebSearchCallItem] = [],
        responsesWebSearchContinuationPrompt: String? = nil,
        responsesWebSearchContinuationCount: Int = 0,
        traceHandler: (@Sendable (String) async -> Void)? = nil
    ) {
        self.baseURL = baseURL
        self.apiStyle = apiStyle
        self.apiKey = apiKey
        self.model = model
        self.messages = messages
        self.temperature = temperature
        self.topP = topP
        self.maxTokens = maxTokens
        self.thinkingMode = thinkingMode
        self.reasoningEffort = reasoningEffort
        self.timeoutProfile = timeoutProfile
        self.webSearchEnabled = webSearchEnabled
        self.responsesWebSearchReplay = responsesWebSearchReplay
        self.responsesWebSearchContinuationPrompt = responsesWebSearchContinuationPrompt
        self.responsesWebSearchContinuationCount = max(0, responsesWebSearchContinuationCount)
        self.traceHandler = traceHandler
    }

    func withWebSearchReplay(
        _ replay: [LLMResponsesWebSearchCallItem],
        continuationPrompt: String?
    ) -> LLMCompletionRequest {
        var mergedReplay = responsesWebSearchReplay
        for item in replay where mergedReplay.contains(where: { $0.hasSameIdentity(as: item) }) == false {
            mergedReplay.append(item)
        }
        return LLMCompletionRequest(
            baseURL: baseURL,
            apiStyle: apiStyle,
            apiKey: apiKey,
            model: model,
            messages: messages,
            temperature: temperature,
            topP: topP,
            maxTokens: maxTokens,
            thinkingMode: thinkingMode,
            reasoningEffort: reasoningEffort,
            timeoutProfile: timeoutProfile,
            webSearchEnabled: webSearchEnabled,
            responsesWebSearchReplay: mergedReplay,
            responsesWebSearchContinuationPrompt: continuationPrompt ?? responsesWebSearchContinuationPrompt,
            responsesWebSearchContinuationCount: responsesWebSearchContinuationCount + 1,
            traceHandler: traceHandler
        )
    }
}

struct LLMCompletionResponse: Equatable, Sendable {
    let text: String
    let resolvedEndpoint: LLMResolvedEndpoint?
    let webSearchSources: [LLMWebSearchSource]

    init(
        text: String,
        resolvedEndpoint: LLMResolvedEndpoint?,
        webSearchSources: [LLMWebSearchSource] = []
    ) {
        self.text = text
        self.resolvedEndpoint = resolvedEndpoint
        self.webSearchSources = webSearchSources
    }
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
    case webSearchCompletedWithoutAnswer
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
        case .webSearchCompletedWithoutAnswer:
            return AppLocalization.localized(
                "The web search completed, but the provider did not generate an answer."
            )
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
            if let fallbackPlan = fallbackRoutePlanTogglingV1IfNeeded(primaryPlan: primaryPlan, error: primaryError) {
                do {
                    return try await performComplete(request: request, routePlan: fallbackPlan)
                } catch let fallbackError {
                    throw mapError(
                        fallbackError,
                        baseURL: request.baseURL,
                        apiStyle: request.apiStyle,
                        primaryPlan: primaryPlan,
                        fallbackPlanTried: fallbackPlan
                    )
                }
            }

            throw mapError(
                primaryError,
                baseURL: request.baseURL,
                apiStyle: request.apiStyle,
                primaryPlan: primaryPlan,
                fallbackPlanTried: nil
            )
        }
    }

    func completeStreaming(
        request: LLMCompletionRequest,
        onPartialText: @escaping @Sendable (String) async -> Void
    ) async throws -> LLMCompletionResponse {
        let primaryPlan = serviceRoutePlan(from: request.baseURL)

        do {
            return try await performStreamingComplete(
                request: request,
                routePlan: primaryPlan,
                onPartialText: onPartialText
            )
        } catch let primaryError {
            if let fallbackPlan = fallbackRoutePlanTogglingV1IfNeeded(
                primaryPlan: primaryPlan,
                error: primaryError
            ) {
                do {
                    return try await performStreamingComplete(
                        request: request,
                        routePlan: fallbackPlan,
                        onPartialText: onPartialText
                    )
                } catch let fallbackError {
                    throw mapError(
                        fallbackError,
                        baseURL: request.baseURL,
                        apiStyle: request.apiStyle,
                        primaryPlan: primaryPlan,
                        fallbackPlanTried: fallbackPlan
                    )
                }
            }

            throw mapError(
                primaryError,
                baseURL: request.baseURL,
                apiStyle: request.apiStyle,
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
        var version: String?
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

    func inferredEndpoint(from routePlan: ServiceRoutePlan, apiStyle: LLMAPIStyle) -> String {
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
        switch apiStyle {
        case .chatCompletions:
            segments.append("chat")
            segments.append("completions")
        case .responses:
            segments.append("responses")
        }

        components.path = "/" + segments.joined(separator: "/")
        components.query = nil
        components.fragment = nil
        return components.url?.absoluteString ?? "<invalid endpoint>"
    }

    private func performComplete(
        request: LLMCompletionRequest,
        routePlan: ServiceRoutePlan
    ) async throws -> LLMCompletionResponse {
        guard let endpoint = URL(string: inferredEndpoint(from: routePlan, apiStyle: request.apiStyle)) else {
            throw LLMProviderError.invalidConfiguration(
                AppLocalization.format(
                    "Invalid provider endpoint for base URL: %@",
                    request.baseURL.absoluteString
                )
            )
        }

        var urlRequestBuilder = URLRequest(url: endpoint)
        urlRequestBuilder.httpMethod = "POST"
        urlRequestBuilder.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequestBuilder.setValue("Bearer \(request.apiKey)", forHTTPHeaderField: "Authorization")
        switch request.apiStyle {
        case .chatCompletions:
            urlRequestBuilder.httpBody = try JSONEncoder().encode(LLMChatCompletionBody(request: request))
        case .responses:
            urlRequestBuilder.httpBody = try JSONEncoder().encode(LLMResponsesRequestBody(request: request))
        }
        let urlRequest = urlRequestBuilder
        await emitTrace(
            request: request,
            message: Self.requestTrace(urlRequest)
        )

        let session = makeURLSession(timeoutProfile: request.timeoutProfile)

        return try await withResourceTimeout(
            seconds: request.timeoutProfile?.resourceTimeoutSeconds,
            timeoutKind: .resource
        ) {
            let (data, response) = try await session.data(for: urlRequest)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            await emitTrace(
                request: request,
                message: Self.responseTrace(httpResponse, body: data)
            )
            guard httpResponse.statusCode == 200 else {
                throw Self.apiError(data: data, statusCode: httpResponse.statusCode)
            }

            let text: String
            let webSearchSources: [LLMWebSearchSource]
            switch request.apiStyle {
            case .chatCompletions:
                let decoded = try JSONDecoder().decode(LLMChatCompletionResponseBody.self, from: data)
                text = decoded.choices?.first?.message?.content ?? ""
                webSearchSources = []
            case .responses:
                let decoded = try JSONDecoder().decode(LLMResponsesResponseBody.self, from: data)
                if let terminalError = decoded.terminalError {
                    throw terminalError
                }
                if decoded.outputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   let continuationRequest = try webSearchContinuationRequest(
                       for: request,
                       completedCalls: decoded.webSearchCalls
                   ) {
                    await emitTrace(
                        request: request,
                        message: Self.continuationTrace(continuationRequest)
                    )
                    return try await performComplete(
                        request: continuationRequest,
                        routePlan: routePlan
                    )
                }
                text = decoded.outputText
                webSearchSources = Self.uniqueWebSearchSources(
                    decoded.webSearchSources
                        + request.responsesWebSearchReplay.flatMap(\.webSearchSources)
                )
            }
            return LLMCompletionResponse(
                text: text,
                resolvedEndpoint: makeResolvedEndpointSnapshot(
                    from: routePlan,
                    apiStyle: request.apiStyle
                ),
                webSearchSources: webSearchSources
            )
        }
    }

    private func performStreamingComplete(
        request: LLMCompletionRequest,
        routePlan: ServiceRoutePlan,
        onPartialText: @escaping @Sendable (String) async -> Void
    ) async throws -> LLMCompletionResponse {
        guard let endpoint = URL(string: inferredEndpoint(from: routePlan, apiStyle: request.apiStyle)) else {
            throw LLMProviderError.invalidConfiguration(
                AppLocalization.format(
                    "Invalid provider endpoint for base URL: %@",
                    request.baseURL.absoluteString
                )
            )
        }

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.setValue("Bearer \(request.apiKey)", forHTTPHeaderField: "Authorization")
        switch request.apiStyle {
        case .chatCompletions:
            urlRequest.httpBody = try JSONEncoder().encode(LLMChatCompletionBody(request: request, stream: true))
        case .responses:
            urlRequest.httpBody = try JSONEncoder().encode(LLMResponsesRequestBody(request: request, stream: true))
        }
        await emitTrace(
            request: request,
            message: Self.requestTrace(urlRequest)
        )

        let session = makeURLSession(timeoutProfile: request.timeoutProfile)
        let streamingRequest = urlRequest
        return try await withResourceTimeout(
            seconds: request.timeoutProfile?.resourceTimeoutSeconds,
            timeoutKind: .resource
        ) {
            let (bytes, response) = try await session.bytes(for: streamingRequest)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            await emitTrace(
                request: request,
                message: Self.responseHeaderTrace(httpResponse)
            )
            guard httpResponse.statusCode == 200 else {
                var data = Data()
                for try await byte in bytes {
                    data.append(byte)
                }
                await emitTrace(
                    request: request,
                    message: Self.bodyTrace(data)
                )
                throw Self.apiError(data: data, statusCode: httpResponse.statusCode)
            }

            let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
            if contentType.contains("application/json") {
                var data = Data()
                for try await byte in bytes {
                    data.append(byte)
                }
                await emitTrace(
                    request: request,
                    message: Self.bodyTrace(data)
                )
                let text: String
                let webSearchSources: [LLMWebSearchSource]
                switch request.apiStyle {
                case .chatCompletions:
                    text = try JSONDecoder().decode(LLMChatCompletionResponseBody.self, from: data)
                        .choices?.first?.message?.content ?? ""
                    webSearchSources = []
                case .responses:
                    let decoded = try JSONDecoder().decode(LLMResponsesResponseBody.self, from: data)
                    if let terminalError = decoded.terminalError {
                        throw terminalError
                    }
                    if decoded.outputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       let continuationRequest = try webSearchContinuationRequest(
                           for: request,
                           completedCalls: decoded.webSearchCalls
                       ) {
                        await emitTrace(
                            request: request,
                            message: Self.continuationTrace(continuationRequest)
                        )
                        let continued = try await performComplete(
                            request: continuationRequest,
                            routePlan: routePlan
                        )
                        if continued.text.isEmpty == false {
                            await onPartialText(continued.text)
                        }
                        return continued
                    }
                    text = decoded.outputText
                    webSearchSources = Self.uniqueWebSearchSources(
                        decoded.webSearchSources
                            + request.responsesWebSearchReplay.flatMap(\.webSearchSources)
                    )
                }
                if text.isEmpty == false {
                    await onPartialText(text)
                }
                return LLMCompletionResponse(
                    text: text,
                    resolvedEndpoint: makeResolvedEndpointSnapshot(
                        from: routePlan,
                        apiStyle: request.apiStyle
                    ),
                    webSearchSources: webSearchSources
                )
            }

            var accumulatedText = ""
            var eventName: String?
            var observedWebSearchCalls: [LLMResponsesWebSearchCallItem] = []
            var terminalResponseBody: LLMResponsesResponseBody?
            for try await line in bytes.lines {
                try Task.checkCancellation()
                if line.hasPrefix("event:") {
                    eventName = String(line.dropFirst("event:".count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    continue
                }
                guard line.hasPrefix("data:") else {
                    if line.isEmpty { eventName = nil }
                    continue
                }
                let payload = String(line.dropFirst("data:".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard payload.isEmpty == false, payload != "[DONE]" else { continue }
                await emitTrace(
                    request: request,
                    message: "SSE \(eventName ?? "message")\n\(Self.prettyJSON(payload))"
                )
                if let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] {
                    let eventType = (object["type"] as? String) ?? eventName
                    if eventType == "response.output_item.done",
                       let item = object["item"] as? [String: Any],
                       (item["type"] as? String) == "web_search_call",
                       let itemData = try? JSONSerialization.data(withJSONObject: item),
                       let rawItem = try? JSONDecoder().decode(
                           [String: LLMResponsesWebSearchCallItem.JSONValue].self,
                           from: itemData
                       ) {
                        observedWebSearchCalls.append(
                            LLMResponsesWebSearchCallItem(json: rawItem)
                        )
                    }
                    if Self.responsesTerminalEventTypes.contains(eventType ?? ""),
                       let response = object["response"],
                       let terminalData = try? JSONSerialization.data(withJSONObject: response) {
                        terminalResponseBody = try? JSONDecoder().decode(
                            LLMResponsesResponseBody.self,
                            from: terminalData
                        )
                    }
                }
                if let delta = Self.streamingTextDelta(
                    from: Data(payload.utf8),
                    eventName: eventName,
                    apiStyle: request.apiStyle
                ), delta.isEmpty == false {
                    accumulatedText += delta
                    await onPartialText(accumulatedText)
                }
            }

            if let terminalError = terminalResponseBody?.terminalError {
                throw terminalError
            }

            if accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let terminalText = terminalResponseBody?.outputText,
               terminalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                accumulatedText = terminalText
                await onPartialText(terminalText)
            }

            let replayCalls = Self.mergedWebSearchCalls(
                observedWebSearchCalls,
                terminalResponseBody?.webSearchCalls ?? []
            )
            if accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let continuationRequest = try webSearchContinuationRequest(
                   for: request,
                   completedCalls: replayCalls
               ) {
                await emitTrace(
                    request: request,
                    message: Self.continuationTrace(continuationRequest)
                )
                return try await performStreamingComplete(
                    request: continuationRequest,
                    routePlan: routePlan,
                    onPartialText: onPartialText
                )
            }

            return LLMCompletionResponse(
                text: accumulatedText,
                resolvedEndpoint: makeResolvedEndpointSnapshot(
                    from: routePlan,
                    apiStyle: request.apiStyle
                ),
                webSearchSources: Self.uniqueWebSearchSources(
                    LLMWebSearchSource.detected(in: accumulatedText)
                        + (terminalResponseBody?.webSearchSources ?? [])
                        + request.responsesWebSearchReplay.flatMap(\.webSearchSources)
                        + observedWebSearchCalls.flatMap(\.webSearchSources)
                )
            )
        }
    }

    private static func streamingTextDelta(
        from data: Data,
        eventName: String?,
        apiStyle: LLMAPIStyle
    ) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        switch apiStyle {
        case .chatCompletions:
            guard let choice = (object["choices"] as? [[String: Any]])?.first,
                  let delta = choice["delta"] as? [String: Any] else { return nil }
            if let content = delta["content"] as? String {
                return content
            }
            if let parts = delta["content"] as? [[String: Any]] {
                return parts.compactMap { $0["text"] as? String }.joined()
            }
            return nil
        case .responses:
            let type = (object["type"] as? String) ?? eventName
            guard type == nil || type == "response.output_text.delta" else { return nil }
            if let delta = object["delta"] as? String { return delta }
            if let delta = object["delta"] as? [String: Any] {
                return delta["text"] as? String
            }
            return nil
        }
    }

    /// When DeepSeek completes a server-side web search it can end the
    /// stateless response with only `web_search_call` items and no visible
    /// message. Those completed calls must be echoed back in the next request's
    /// `input` so the server can restore the search results and answer.
    private func webSearchContinuationRequest(
        for request: LLMCompletionRequest,
        completedCalls: [LLMResponsesWebSearchCallItem]
    ) throws -> LLMCompletionRequest? {
        // A single failed web_search_call must not discard the completed
        // search results that can still be restored for the follow-up answer.
        let replayableCalls = completedCalls.filter(\.isCompleted)
        guard request.apiStyle == .responses,
              request.webSearchEnabled else {
            return nil
        }
        guard request.responsesWebSearchContinuationCount < Self.maximumWebSearchContinuations else {
            throw LLMProviderError.webSearchCompletedWithoutAnswer
        }

        let newCalls = replayableCalls.filter { candidate in
            request.responsesWebSearchReplay.contains {
                $0.hasSameIdentity(as: candidate)
            } == false
        }
        guard newCalls.isEmpty == false else {
            throw LLMProviderError.webSearchCompletedWithoutAnswer
        }

        let prompt = request.responsesWebSearchContinuationPrompt
            ?? Self.defaultWebSearchContinuationPrompt
        return request.withWebSearchReplay(
            newCalls,
            continuationPrompt: prompt
        )
    }

    private static let defaultWebSearchContinuationPrompt = """
    The requested web search has completed. Answer the user's original request now based on the search results that were restored above. For every claim that relies on a web result, include that result's exact concrete URL directly after the claim. Do not assign source numbers yourself; the app will replace each URL with its final sequential source label. Never invent, shorten, or reformat URLs or sources that are not present in the restored results.
    """

    private static let maximumWebSearchContinuations = 3

    private static func mergedWebSearchCalls(
        _ observedCalls: [LLMResponsesWebSearchCallItem],
        _ terminalCalls: [LLMResponsesWebSearchCallItem]
    ) -> [LLMResponsesWebSearchCallItem] {
        var merged = observedCalls
        for terminalCall in terminalCalls {
            if let index = merged.firstIndex(where: {
                $0.hasSameIdentity(as: terminalCall)
            }) {
                // The terminal response is authoritative and may contain a
                // final status or fields omitted from output_item.done.
                merged[index] = terminalCall
            } else {
                merged.append(terminalCall)
            }
        }
        return merged
    }

    private static let responsesTerminalEventTypes: Set<String> = [
        "response.completed",
        "response.incomplete",
        "response.failed"
    ]

    private static func uniqueWebSearchSources(
        _ sources: [LLMWebSearchSource]
    ) -> [LLMWebSearchSource] {
        var seen = Set<String>()
        return sources.filter { seen.insert($0.urlString).inserted }
    }

    private func emitTrace(
        request: LLMCompletionRequest,
        message: String
    ) async {
        await request.traceHandler?(message)
    }

    private static func requestTrace(_ request: URLRequest) -> String {
        let method = request.httpMethod ?? "POST"
        let url = request.url?.absoluteString ?? "<invalid URL>"
        return """
        REQUEST \(method) \(url)
        Headers:
        \(headerTrace(request.allHTTPHeaderFields ?? [:]))
        Body:
        \(prettyJSON(request.httpBody ?? Data()))
        """
    }

    private static func responseHeaderTrace(_ response: HTTPURLResponse) -> String {
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, entry in
            result[String(describing: entry.key)] = String(describing: entry.value)
        }
        return """
        RESPONSE HTTP \(response.statusCode)
        Headers:
        \(headerTrace(headers))
        """
    }

    private static func responseTrace(_ response: HTTPURLResponse, body: Data) -> String {
        responseHeaderTrace(response) + "\nBody:\n" + prettyJSON(body)
    }

    private static func bodyTrace(_ body: Data) -> String {
        "Body:\n" + prettyJSON(body)
    }

    private static func continuationTrace(_ request: LLMCompletionRequest) -> String {
        "WEB SEARCH CONTINUATION \(request.responsesWebSearchContinuationCount)/\(maximumWebSearchContinuations) — replaying \(request.responsesWebSearchReplay.count) web_search_call item(s)"
    }

    private static func headerTrace(_ headers: [String: String]) -> String {
        headers.keys.sorted().map { key in
            let lowercased = key.lowercased()
            let value = lowercased == "authorization" || lowercased == "set-cookie"
                ? "<redacted>"
                : (headers[key] ?? "")
            return "\(key): \(value)"
        }.joined(separator: "\n")
    }

    private static func prettyJSON(_ data: Data) -> String {
        guard data.isEmpty == false else { return "<empty>" }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let prettyData = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              ),
              let pretty = String(data: prettyData, encoding: .utf8) else {
            return String(data: data, encoding: .utf8) ?? "<non-UTF-8 body>"
        }
        return pretty
    }

    private static func prettyJSON(_ text: String) -> String {
        prettyJSON(Data(text.utf8))
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

    private func makeResolvedEndpointSnapshot(
        from routePlan: ServiceRoutePlan,
        apiStyle: LLMAPIStyle
    ) -> LLMResolvedEndpoint? {
        guard let endpoint = URL(string: inferredEndpoint(from: routePlan, apiStyle: apiStyle)) else {
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
        apiStyle: LLMAPIStyle,
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
                    let primaryEndpoint = inferredEndpoint(
                        from: primaryPlan,
                        apiStyle: apiStyle
                    )
                    let retryDetails: String
                    if let fallbackPlanTried {
                        let fallbackEndpoint = inferredEndpoint(
                            from: fallbackPlanTried,
                            apiStyle: apiStyle
                        )
                        retryDetails = AppLocalization.format(
                            " Retried with resolved endpoint %@.",
                            fallbackEndpoint
                        )
                    } else {
                        retryDetails = ""
                    }
                    return .network(
                        AppLocalization.format(
                            "HTTP 404: endpoint not found. Current base URL is %@. Resolved endpoint is %@.%@ Check the selected API protocol and provider base URL.",
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

    private func fallbackRoutePlanTogglingV1IfNeeded(
        primaryPlan: ServiceRoutePlan,
        error: Error
    ) -> ServiceRoutePlan? {
        guard isHTTP404(error) else {
            return nil
        }
        if (primaryPlan.version ?? "").lowercased() == "v1" {
            return ServiceRoutePlan(
                overrideBaseURL: primaryPlan.overrideBaseURL,
                proxyPath: primaryPlan.proxyPath,
                version: nil
            )
        }
        return ServiceRoutePlan(
            overrideBaseURL: primaryPlan.overrideBaseURL,
            proxyPath: primaryPlan.proxyPath,
            version: "v1"
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
    let stream: Bool?

    init(request: LLMCompletionRequest, stream: Bool? = nil) {
        model = request.model
        messages = request.messages.map { Message(role: $0.role, content: $0.content) }
        temperature = request.temperature
        topP = request.topP
        maxTokens = request.maxTokens
        self.stream = stream

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
        case stream
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

private struct LLMResponsesRequestBody: Encodable {
    struct Reasoning: Encodable {
        let effort: String
    }

    enum InputItem: Encodable {
        case message(role: String, content: String)
        case webSearchCall(LLMResponsesWebSearchCallItem)

        func encode(to encoder: Encoder) throws {
            switch self {
            case .message(let role, let content):
                var container = encoder.container(keyedBy: MessageCodingKey.self)
                try container.encode(role, forKey: .role)
                try container.encode(content, forKey: .content)
            case .webSearchCall(let item):
                try item.encodeAsJSONObject(to: encoder)
            }
        }
    }

    enum ToolChoice: Encodable {
        case mode(String)
        case webSearch

        func encode(to encoder: Encoder) throws {
            switch self {
            case .mode(let value):
                var container = encoder.singleValueContainer()
                try container.encode(value)
            case .webSearch:
                var container = encoder.container(keyedBy: ToolCodingKey.self)
                try container.encode("web_search", forKey: .type)
            }
        }
    }

    private enum MessageCodingKey: String, CodingKey {
        case role
        case content
    }

    private enum ToolCodingKey: String, CodingKey {
        case type
    }

    let model: String
    let input: [InputItem]
    let temperature: Double?
    let topP: Double?
    let maxOutputTokens: Int?
    let reasoning: Reasoning?
    let stream: Bool?
    let tools: [[String: String]]?
    let toolChoice: ToolChoice?

    init(request: LLMCompletionRequest, stream: Bool? = nil) {
        model = request.model
        var inputItems = request.messages.map {
            InputItem.message(role: $0.role, content: $0.content)
        }
        if request.responsesWebSearchReplay.isEmpty == false {
            inputItems.append(
                contentsOf: request.responsesWebSearchReplay.map(InputItem.webSearchCall)
            )
            if let prompt = request.responsesWebSearchContinuationPrompt,
               prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                inputItems.append(.message(role: "user", content: prompt))
            }
        }
        input = inputItems
        temperature = request.temperature
        topP = request.topP
        maxOutputTokens = request.maxTokens
        self.stream = stream
        if request.webSearchEnabled {
            tools = [["type": "web_search"]]
            // An external-scope request must actually search instead of
            // allowing the model to answer from memory. Replayed calls already
            // contain restored results, so force the model to answer from them
            // without issuing another search.
            toolChoice = request.responsesWebSearchReplay.isEmpty
                ? .webSearch
                : .mode("none")
        } else {
            tools = nil
            toolChoice = nil
        }

        switch request.thinkingMode {
        case .disabled:
            reasoning = Reasoning(effort: "none")
        case .enabled:
            reasoning = request.reasoningEffort.map { Reasoning(effort: $0.rawValue) }
        case nil:
            reasoning = request.reasoningEffort.map { Reasoning(effort: $0.rawValue) }
        }
    }

    enum CodingKeys: String, CodingKey {
        case model
        case input
        case temperature
        case topP = "top_p"
        case maxOutputTokens = "max_output_tokens"
        case reasoning
        case stream
        case tools
        case toolChoice = "tool_choice"
    }
}

private struct LLMResponsesResponseBody: Decodable {
    struct ResponseError: Decodable {
        let message: String?
    }

    struct IncompleteDetails: Decodable {
        let reason: String?
    }

    struct OutputItem {
        let type: String?
        let raw: [String: LLMResponsesWebSearchCallItem.JSONValue]

        init(raw: [String: LLMResponsesWebSearchCallItem.JSONValue]) {
            self.raw = raw
            type = raw["type"]?.stringValue
        }
    }

    let status: String?
    let error: ResponseError?
    let incompleteDetails: IncompleteDetails?
    let output: [OutputItem]?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        error = try container.decodeIfPresent(ResponseError.self, forKey: .error)
        incompleteDetails = try container.decodeIfPresent(
            IncompleteDetails.self,
            forKey: .incompleteDetails
        )
        let rawOutput = try container.decodeIfPresent(
            [LLMResponsesWebSearchCallItem.JSONValue].self,
            forKey: .output
        )
        output = rawOutput?.compactMap { value in
            guard case .object(let object) = value else {
                return nil
            }
            return OutputItem(raw: object)
        }
    }

    var outputText: String {
        var texts: [String] = []
        for item in output ?? [] {
            guard item.type == nil || item.type == "message" else {
                continue
            }
            guard case .array(let contentParts)? = item.raw["content"] else {
                continue
            }
            for part in contentParts {
                guard case .object(let object) = part else {
                    continue
                }
                let partType = object["type"]?.stringValue
                guard partType == nil || partType == "output_text" else {
                    continue
                }
                if let text = object["text"]?.stringValue, text.isEmpty == false {
                    texts.append(text)
                }
            }
        }
        return texts.joined(separator: "\n")
    }

    var webSearchCalls: [LLMResponsesWebSearchCallItem] {
        guard let output else {
            return []
        }
        return output.compactMap { item in
            guard item.type == "web_search_call" else {
                return nil
            }
            return LLMResponsesWebSearchCallItem(json: item.raw)
        }
    }

    var webSearchSources: [LLMWebSearchSource] {
        var sources: [LLMWebSearchSource] = []
        for item in output ?? [] where item.type == nil || item.type == "message" {
            guard let contentParts = item.raw["content"]?.arrayValue else {
                continue
            }
            for part in contentParts {
                guard let annotations = part.objectValue?["annotations"]?.arrayValue else {
                    continue
                }
                for annotation in annotations {
                    guard let object = annotation.objectValue,
                          let url = object["url"]?.stringValue,
                          let source = LLMWebSearchSource(
                            urlString: url,
                            title: object["title"]?.stringValue
                          ) else {
                        continue
                    }
                    sources.append(source)
                }
            }
        }
        sources.append(contentsOf: LLMWebSearchSource.detected(in: outputText))
        sources.append(contentsOf: webSearchCalls.flatMap(\.webSearchSources))

        var seen = Set<String>()
        return sources.filter { seen.insert($0.urlString).inserted }
    }

    var terminalError: LLMProviderError? {
        switch status?.lowercased() {
        case "failed":
            let providerMessage = error?.message?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let providerMessage, providerMessage.isEmpty == false {
                return .network(providerMessage)
            }
            return .network(AppLocalization.localized(
                "Provider request failed due to a network or server error."
            ))
        case "incomplete":
            let reason = incompleteDetails?.reason?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let reason, reason.isEmpty == false {
                return .network(AppLocalization.format(
                    "The provider returned an incomplete response: %@",
                    reason
                ))
            }
            return .network(AppLocalization.localized(
                "The provider returned an incomplete response."
            ))
        default:
            return nil
        }
    }

    enum CodingKeys: String, CodingKey {
        case status
        case error
        case incompleteDetails = "incomplete_details"
        case output
    }
}

private struct LLMAPIErrorResponseBody: Decodable {
    struct Error: Decodable {
        let message: String?
    }

    let error: Error?
}
