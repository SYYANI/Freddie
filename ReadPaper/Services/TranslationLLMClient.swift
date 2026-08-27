import Foundation

protocol TranslationLLMClientProtocol: Sendable {
    func translate(
        _ text: String,
        targetLanguage: String,
        route: LLMModelRouteSnapshot,
        apiKey: String,
        context: AcademicTranslationContext
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
        apiKey: String,
        context: AcademicTranslationContext = AcademicTranslationContext()
    ) async throws -> String {
        guard let baseURL = URL(string: route.baseURL) else {
            throw LLMProviderError.invalidConfiguration(
                AppLocalization.format("Invalid provider base URL: %@", route.baseURL)
            )
        }

        let response = try await provider.complete(
            request: LLMCompletionRequest(
                baseURL: baseURL,
                apiStyle: route.apiStyle,
                apiKey: apiKey,
                model: route.modelName,
                messages: [
                    LLMCompletionMessage(
                        role: "system",
                        content: AcademicTranslationPrompt.systemPrompt(targetLanguage: targetLanguage)
                    ),
                    LLMCompletionMessage(
                        role: "user",
                        content: AcademicTranslationPrompt.userPrompt(sourceText: text, context: context)
                    )
                ],
                temperature: route.temperature ?? 0.2,
                topP: route.topP,
                maxTokens: route.maxTokens,
                thinkingMode: route.thinkingMode,
                reasoningEffort: route.reasoningEffort,
                timeoutProfile: .translationDefault
            )
        )

        let content = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard content.isEmpty == false else {
            throw LLMProviderError.emptyResponse
        }
        return content
    }

}
