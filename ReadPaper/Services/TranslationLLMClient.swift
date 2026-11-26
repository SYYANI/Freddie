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
                messages: Self.messages(for: text, targetLanguage: targetLanguage, context: context),
                temperature: route.temperature ?? route.apiStyle.samplingDefault(0.2),
                topP: route.topP,
                maxTokens: route.maxTokens,
                thinkingMode: route.thinkingMode,
                reasoningEffort: route.reasoningEffort,
                timeoutProfile: .translationDefault
            )
        )

        // Chat Completions returns partial text with finish_reason=length.
        // Never let the HTML/abstract pipeline cache it as a complete translation.
        if response.finishReason == .length {
            throw LLMProviderError.outputTokenLimitExceeded(reason: "length")
        }

        let content = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard content.isEmpty == false else {
            throw LLMProviderError.emptyResponse
        }
        return content
    }

    static func messages(
        for text: String,
        targetLanguage: String,
        context: AcademicTranslationContext
    ) -> [LLMCompletionMessage] {
        switch context.promptStyle {
        case .contextual:
            return [
                LLMCompletionMessage(
                    role: "system",
                    content: AcademicTranslationPrompt.systemPrompt(targetLanguage: targetLanguage)
                ),
                LLMCompletionMessage(
                    role: "user",
                    content: AcademicTranslationPrompt.userPrompt(sourceText: text, context: context)
                )
            ]
        case .plain:
            return [
                LLMCompletionMessage(
                    role: "user",
                    content: AcademicTranslationPrompt.plainPrompt(
                        sourceText: text,
                        targetLanguage: targetLanguage,
                        glossary: context.glossary
                    )
                )
            ]
        }
    }
}

/// Tells a translation-only model from one that follows instructions with one real
/// request: the full prompt with titles and neighboring paragraphs. A model that
/// translates the labelled envelope instead of the source segment is translation-only,
/// provided the plain prompt then gets a usable translation.
enum TranslationModelKindProbe {
    enum Result: Equatable, Sendable {
        case general
        case translationOnly
        /// Neither prompt got a usable translation; the issue of the last attempt.
        case inconclusive(TranslationOutputIssue)
    }

    struct Outcome: Equatable, Sendable {
        var result: Result
        /// What the model returned for the full prompt, shown in settings.
        var contextualOutput: String
    }

    static let source = "Attention layers let every token weigh all other tokens in the sequence, so their cost grows quadratically with the sequence length."
    static let context = AcademicTranslationContext(
        documentTitle: "Efficient Long-Context Modeling",
        sectionTitle: "Introduction",
        previousSegment: "Recent work has explored sparse, low-rank and kernel-based approximations of attention.",
        nextSegment: "Section 2 reviews related work, and Section 3 introduces our method in detail."
    )

    static func detect(
        client: TranslationLLMClientProtocol,
        route: LLMModelRouteSnapshot,
        apiKey: String,
        targetLanguage: String
    ) async throws -> Outcome {
        let contextual = try await client.translate(
            source,
            targetLanguage: targetLanguage,
            route: route,
            apiKey: apiKey,
            context: context
        )
        let contextualIssue = TranslationOutputValidator.issue(in: contextual, source: source, context: context)
        guard let contextualIssue, contextualIssue.isFatal else {
            return Outcome(result: .general, contextualOutput: contextual)
        }
        // An untranslated or context-repeating answer says nothing about the envelope.
        guard [.promptEcho, .excessiveLength].contains(contextualIssue) else {
            return Outcome(result: .inconclusive(contextualIssue), contextualOutput: contextual)
        }

        let plain = try await client.translate(
            source,
            targetLanguage: targetLanguage,
            route: route,
            apiKey: apiKey,
            context: context.asPlainPrompt
        )
        let plainIssue = TranslationOutputValidator.issue(in: plain, source: source, context: context)
        if let plainIssue, plainIssue.isFatal {
            return Outcome(result: .inconclusive(plainIssue), contextualOutput: contextual)
        }
        return Outcome(result: .translationOnly, contextualOutput: contextual)
    }
}
