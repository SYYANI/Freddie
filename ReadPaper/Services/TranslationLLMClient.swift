import Foundation

protocol TranslationLLMClientProtocol: Sendable {
    func translate(
        _ text: String,
        targetLanguage: String,
        route: LLMModelRouteSnapshot,
        apiKey: String
    ) async throws -> String
}

struct TranslationLLMClient: TranslationLLMClientProtocol {
    let provider: OpenAICompatibleLLMProvider

    init(provider: OpenAICompatibleLLMProvider = OpenAICompatibleLLMProvider()) {
        self.provider = provider
    }

    func translate(
        _ text: String,
        targetLanguage: String,
        route: LLMModelRouteSnapshot,
        apiKey: String
    ) async throws -> String {
        guard let baseURL = URL(string: route.baseURL) else {
            throw LLMProviderError.invalidConfiguration("Invalid provider base URL: \(route.baseURL)")
        }

        let response = try await provider.complete(
            request: LLMCompletionRequest(
                baseURL: baseURL,
                apiKey: apiKey,
                model: route.modelName,
                messages: [
                    LLMCompletionMessage(role: "system", content: systemPrompt(targetLanguage: targetLanguage)),
                    LLMCompletionMessage(role: "user", content: text)
                ],
                temperature: route.temperature ?? 0.2,
                topP: route.topP,
                maxTokens: route.maxTokens,
                timeoutProfile: .translationDefault
            )
        )

        let content = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard content.isEmpty == false else {
            throw LLMProviderError.emptyResponse
        }
        return content
    }

    private func systemPrompt(targetLanguage: String) -> String {
        """
        You are a professional academic translator. Translate into \(targetLanguage).
        Preserve academic tone and terminology.
        Do not change placeholders such as [PROTECTED_0].
        Preserve Markdown emphasis markers if present.
        Output only the translation.
        """
    }
}
