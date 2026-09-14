import Foundation

struct LLMProviderConnectionTestResult: Equatable, Sendable {
    let model: String
    let baseURL: String
    let latencyMs: Int
    let outputPreview: String
}

struct LLMProviderWebSearchTestResult: Equatable, Sendable {
    let model: String
    let baseURL: String
    let latencyMs: Int
    let outputPreview: String
    let sources: [LLMWebSearchSource]
    let trace: String
}

enum LLMProviderValidationError: LocalizedError, Equatable {
    case invalidBaseURL
    case unsupportedBaseURLScheme
    case emptyModel
    case emptyAPIKey
    case webSearchRequiresResponsesAPI
    case webSearchReturnedNoSources

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return AppLocalization.localized("Please enter a valid Base URL.")
        case .unsupportedBaseURLScheme:
            return AppLocalization.localized("Only http:// or https:// Base URL is supported.")
        case .emptyModel:
            return AppLocalization.localized("Model name cannot be empty.")
        case .emptyAPIKey:
            return AppLocalization.localized("API key cannot be empty.")
        case .webSearchRequiresResponsesAPI:
            return AppLocalization.localized("Web search testing requires the Responses API.")
        case .webSearchReturnedNoSources:
            return AppLocalization.localized("The model answered, but no web search source URL was returned.")
        }
    }
}

struct LLMProviderValidationUseCase {
    let provider: OpenAICompatibleLLMProvider

    init(provider: OpenAICompatibleLLMProvider = OpenAICompatibleLLMProvider()) {
        self.provider = provider
    }

    func normalizedBaseURL(_ rawValue: String) throws -> String {
        try validateBaseURLAsURL(rawValue).absoluteString
    }

    func validateModelName(_ rawValue: String) throws -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.isEmpty == false else {
            throw LLMProviderValidationError.emptyModel
        }
        return value
    }

    func testConnection(
        baseURL: String,
        apiStyle: LLMAPIStyle = .chatCompletions,
        apiKey: String,
        model: String,
        temperature: Double? = nil,
        topP: Double? = nil,
        maxTokens: Int? = nil,
        thinkingMode: LLMThinkingMode? = nil,
        reasoningEffort: LLMReasoningEffort? = nil,
        timeoutSeconds: TimeInterval = 30,
        systemMessage: String = "You are a concise assistant.",
        userMessage: String = "Reply with exactly: ok"
    ) async throws -> LLMProviderConnectionTestResult {
        let normalizedBaseURL = try normalizedBaseURL(baseURL)
        let validatedModel = try validateModelName(model)
        let validatedAPIKey = try validateAPIKey(apiKey)

        let request = LLMCompletionRequest(
            baseURL: try validateBaseURLAsURL(baseURL),
            apiStyle: apiStyle,
            apiKey: validatedAPIKey,
            model: validatedModel,
            messages: [
                LLMCompletionMessage(role: "system", content: systemMessage.trimmingCharacters(in: .whitespacesAndNewlines)),
                LLMCompletionMessage(role: "user", content: userMessage.trimmingCharacters(in: .whitespacesAndNewlines))
            ],
            temperature: temperature,
            topP: topP,
            maxTokens: maxTokens,
            thinkingMode: thinkingMode,
            reasoningEffort: reasoningEffort,
            timeoutProfile: .validation(timeoutSeconds: timeoutSeconds)
        )

        let start = ContinuousClock.now
        let response = try await provider.complete(request: request)
        let elapsed = start.duration(to: .now)
        let latencyMs = max(
            1,
            Int(elapsed.components.seconds) * 1_000 +
                Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
        )

        return LLMProviderConnectionTestResult(
            model: validatedModel,
            baseURL: normalizedBaseURL,
            latencyMs: latencyMs,
            outputPreview: sanitizeOutputPreview(response.text)
        )
    }

    func testWebSearch(
        baseURL: String,
        apiStyle: LLMAPIStyle,
        apiKey: String,
        model: String,
        timeoutSeconds: TimeInterval = 60,
        onTraceUpdated: (@Sendable ([String]) async -> Void)? = nil
    ) async throws -> LLMProviderWebSearchTestResult {
        guard apiStyle == .responses else {
            throw LLMProviderValidationError.webSearchRequiresResponsesAPI
        }
        let normalizedBaseURL = try normalizedBaseURL(baseURL)
        let validatedModel = try validateModelName(model)
        let validatedAPIKey = try validateAPIKey(apiKey)
        let recorder = LLMProviderWebSearchTraceRecorder(apiKey: validatedAPIKey)
        let traceHandler: @Sendable (String) async -> Void = { entry in
            let appendedEntries = await recorder.append(entry)
            if appendedEntries.isEmpty == false, let onTraceUpdated {
                await onTraceUpdated(appendedEntries)
            }
        }

        await traceHandler("""
        WEB SEARCH CAPABILITY TEST
        Model: \(validatedModel)
        Base URL: \(normalizedBaseURL)
        Protocol: Responses API
        """)

        let request = LLMCompletionRequest(
            baseURL: try validateBaseURLAsURL(baseURL),
            apiStyle: .responses,
            apiKey: validatedAPIKey,
            model: validatedModel,
            messages: [
                LLMCompletionMessage(
                    role: "system",
                    content: "Use web search and answer concisely. Include the concrete source URL."
                ),
                LLMCompletionMessage(
                    role: "user",
                    content: "Find the official IANA Example Domains page and return its current URL."
                )
            ],
            timeoutProfile: .validation(timeoutSeconds: timeoutSeconds),
            webSearchEnabled: true,
            traceHandler: traceHandler
        )

        let start = ContinuousClock.now
        let response: LLMCompletionResponse
        do {
            response = try await provider.completeStreaming(
                request: request,
                onPartialText: { _ in }
            )
        } catch {
            await publishPendingTraceEntries(from: recorder, to: onTraceUpdated)
            throw error
        }
        let latencyMs = Self.elapsedMilliseconds(from: start.duration(to: .now))
        await traceHandler("""
        RESULT
        Output characters: \(response.text.count)
        Source URLs: \(response.webSearchSources.count)
        Latency: \(latencyMs) ms
        """)
        await publishPendingTraceEntries(from: recorder, to: onTraceUpdated)
        let trace = await recorder.value()

        guard response.webSearchSources.isEmpty == false else {
            throw LLMProviderValidationError.webSearchReturnedNoSources
        }
        return LLMProviderWebSearchTestResult(
            model: validatedModel,
            baseURL: normalizedBaseURL,
            latencyMs: latencyMs,
            outputPreview: sanitizeOutputPreview(response.text),
            sources: response.webSearchSources,
            trace: trace
        )
    }

    /// Delivers trace entries that the streaming throttle has not published yet.
    ///
    /// The caller receives incremental batches so it never has to re-render the
    /// whole trace on every update; this final flush keeps the delivered entries
    /// identical to `LLMProviderWebSearchTestResult.trace`.
    private func publishPendingTraceEntries(
        from recorder: LLMProviderWebSearchTraceRecorder,
        to onTraceUpdated: (@Sendable ([String]) async -> Void)?
    ) async {
        guard let onTraceUpdated else { return }
        let appendedEntries = await recorder.flushPendingEntries()
        guard appendedEntries.isEmpty == false else { return }
        await onTraceUpdated(appendedEntries)
    }

    private func validateBaseURLAsURL(_ rawValue: String) throws -> URL {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else {
            throw LLMProviderValidationError.invalidBaseURL
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw LLMProviderValidationError.unsupportedBaseURLScheme
        }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.query = nil
        components?.fragment = nil
        var normalizedPath = components?.path ?? ""
        while normalizedPath.count > 1 && normalizedPath.hasSuffix("/") {
            normalizedPath.removeLast()
        }
        components?.path = normalizedPath

        guard let normalized = components?.url else {
            throw LLMProviderValidationError.invalidBaseURL
        }
        return normalized
    }

    private func validateAPIKey(_ rawValue: String) throws -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.isEmpty == false else {
            throw LLMProviderValidationError.emptyAPIKey
        }
        return value
    }

    private func sanitizeOutputPreview(_ text: String) -> String {
        let compact = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if compact.count <= 80 {
            return compact
        }
        let idx = compact.index(compact.startIndex, offsetBy: 80)
        return String(compact[..<idx]) + "..."
    }

    private static func elapsedMilliseconds(from duration: Duration) -> Int {
        max(
            1,
            Int(duration.components.seconds) * 1_000
                + Int(duration.components.attoseconds / 1_000_000_000_000_000)
        )
    }
}

private actor LLMProviderWebSearchTraceRecorder {
    private let apiKey: String
    private var entries: [String] = []
    private var pendingEntries: [String] = []

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    /// Appends one redacted entry and returns the entries that are ready to publish.
    func append(_ entry: String) -> [String] {
        let sanitized = entry.replacingOccurrences(of: apiKey, with: "<redacted>")
        let numberedEntry = "[\(entries.count + 1)] \(sanitized)"
        entries.append(numberedEntry)
        pendingEntries.append(numberedEntry)

        // Streaming deltas arrive in tight bursts, so only publish them periodically.
        let shouldPublish = numberedEntry.contains(".delta") == false
            || entries.count.isMultiple(of: 25)
        return drainPendingEntries(if: shouldPublish)
    }

    /// Returns the entries that are still waiting for the periodic stream flush.
    func flushPendingEntries() -> [String] {
        drainPendingEntries(if: true)
    }

    func value() -> String {
        entries.joined(separator: "\n\n")
    }

    private func drainPendingEntries(if shouldPublish: Bool) -> [String] {
        guard shouldPublish, pendingEntries.isEmpty == false else { return [] }
        let drainedEntries = pendingEntries
        pendingEntries.removeAll(keepingCapacity: true)
        return drainedEntries
    }
}
