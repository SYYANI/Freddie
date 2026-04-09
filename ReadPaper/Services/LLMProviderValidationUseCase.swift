import Foundation

struct LLMProviderConnectionTestResult: Equatable, Sendable {
    let model: String
    let baseURL: String
    let latencyMs: Int
    let outputPreview: String
}

enum LLMProviderValidationError: LocalizedError, Equatable {
    case invalidBaseURL
    case unsupportedBaseURLScheme
    case emptyModel
    case emptyAPIKey

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "Please enter a valid Base URL."
        case .unsupportedBaseURLScheme:
            return "Only http:// or https:// Base URL is supported."
        case .emptyModel:
            return "Model name cannot be empty."
        case .emptyAPIKey:
            return "API key cannot be empty."
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
        apiKey: String,
        model: String,
        temperature: Double? = nil,
        topP: Double? = nil,
        maxTokens: Int? = nil,
        timeoutSeconds: TimeInterval = 30,
        systemMessage: String = "You are a concise assistant.",
        userMessage: String = "Reply with exactly: ok"
    ) async throws -> LLMProviderConnectionTestResult {
        let normalizedBaseURL = try normalizedBaseURL(baseURL)
        let validatedModel = try validateModelName(model)
        let validatedAPIKey = try validateAPIKey(apiKey)

        let request = LLMCompletionRequest(
            baseURL: try validateBaseURLAsURL(baseURL),
            apiKey: validatedAPIKey,
            model: validatedModel,
            messages: [
                LLMCompletionMessage(role: "system", content: systemMessage.trimmingCharacters(in: .whitespacesAndNewlines)),
                LLMCompletionMessage(role: "user", content: userMessage.trimmingCharacters(in: .whitespacesAndNewlines))
            ],
            temperature: temperature,
            topP: topP,
            maxTokens: maxTokens,
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
}
