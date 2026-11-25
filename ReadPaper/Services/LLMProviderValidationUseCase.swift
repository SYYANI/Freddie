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
    case webSearchRequiresServerSearchAPI
    case webSearchReturnedNoSources
    case modelListUnavailable(Int)

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
        case .webSearchRequiresServerSearchAPI:
            return AppLocalization.localized("Web search testing requires the Responses API or the Anthropic Messages API.")
        case .webSearchReturnedNoSources:
            return AppLocalization.localized("The model answered, but no web search source URL was returned.")
        case .modelListUnavailable(let statusCode):
            return AppLocalization.format("The server did not list its models (HTTP %d).", statusCode)
        }
    }
}

struct LLMProviderValidationUseCase {
    let provider: OpenAICompatibleLLMProvider
    /// Used only to list a server's models (`GET {base}/models`).
    let session: URLSession

    init(
        provider: OpenAICompatibleLLMProvider = OpenAICompatibleLLMProvider(),
        session: URLSession = .shared
    ) {
        self.provider = provider
        self.session = session
    }

    /// The model IDs an OpenAI-compatible server reports at `{base}/models`, in the
    /// server's order. Used to fill in the model name for a local server.
    func listModels(
        baseURL: String,
        apiKey: String = "",
        timeoutSeconds: TimeInterval = 5
    ) async throws -> [String] {
        let base = try validateBaseURLAsURL(baseURL)
        var request = URLRequest(url: base.appendingPathComponent("models"), timeoutInterval: timeoutSeconds)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let key = LLMLocalEndpoint.effectiveAPIKey(apiKey, baseURL: baseURL) {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) == false {
            throw LLMProviderValidationError.modelListUnavailable(http.statusCode)
        }
        struct Body: Decodable {
            struct Entry: Decodable { let id: String }
            let data: [Entry]
        }
        var seen = Set<String>()
        return try JSONDecoder().decode(Body.self, from: data).data
            .map { $0.id.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false && seen.insert($0).inserted }
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
        let validatedAPIKey = try validateAPIKey(apiKey, baseURL: baseURL)

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
        guard apiStyle.supportsServerWebSearch else {
            throw LLMProviderValidationError.webSearchRequiresServerSearchAPI
        }
        let normalizedBaseURL = try normalizedBaseURL(baseURL)
        let validatedModel = try validateModelName(model)
        let validatedAPIKey = try validateAPIKey(apiKey, baseURL: baseURL)
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
        Protocol: \(apiStyle == .anthropicMessages ? "Anthropic Messages API" : "Responses API")
        """)

        let request = LLMCompletionRequest(
            baseURL: try validateBaseURLAsURL(baseURL),
            apiStyle: apiStyle,
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

    private func validateAPIKey(_ rawValue: String, baseURL: String) throws -> String {
        guard let value = LLMLocalEndpoint.effectiveAPIKey(rawValue, baseURL: baseURL) else {
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

        // Streaming deltas (Responses `*.delta`, Anthropic `*_delta`) arrive in
        // tight bursts, so only publish them periodically.
        let shouldPublish = numberedEntry.contains("delta") == false
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

/// Servers on this Mac or the local network (llama.cpp, vLLM, LM Studio, Ollama, oMLX…)
/// usually run without authentication, so their providers work without a saved API key.
/// A key the user does save still wins: such servers may be started with one.
enum LLMLocalEndpoint {
    /// Sent when a local provider has no saved key. Every route consumer (requests,
    /// the BabelDOC helper, LaTeX and scanned-page translation) expects a non-empty
    /// key, and servers without authentication ignore the header.
    static let placeholderAPIKey = "sk-no-key-required"

    static func isLocal(_ baseURL: String) -> Bool {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = url.host?.lowercased(), host.isEmpty == false
        else { return false }
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        if host.hasSuffix(".") { host.removeLast() }

        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") {
            return true
        }
        if host.contains(":") {
            // IPv6: loopback, unique local (fc00::/7) and link-local (fe80::/10).
            return host == "::1"
                || host.hasPrefix("fc") || host.hasPrefix("fd")
                || host.hasPrefix("fe8") || host.hasPrefix("fe9")
                || host.hasPrefix("fea") || host.hasPrefix("feb")
        }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard octets.count == 4,
              octets.allSatisfy({ $0.map { (0...255).contains($0) } ?? false })
        else { return false }
        let first = octets[0]!, second = octets[1]!
        switch first {
        case 127, 10: return true
        case 192: return second == 168
        case 172: return (16...31).contains(second)
        case 169: return second == 254
        default: return false
        }
    }

    /// The key to send: the saved or typed one, otherwise the placeholder for a local
    /// server; nil when the server needs a key and none is available.
    static func effectiveAPIKey(_ key: String?, baseURL: String) -> String? {
        let value = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if value.isEmpty == false { return value }
        return isLocal(baseURL) ? placeholderAPIKey : nil
    }
}
