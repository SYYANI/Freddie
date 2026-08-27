import Foundation

struct LLMModelRouteSnapshot: Equatable, Sendable {
    var providerProfileID: UUID
    var providerName: String
    var modelProfileID: UUID
    var modelProfileName: String
    var baseURL: String
    var apiStyle: LLMAPIStyle
    var apiKeyRef: String
    var modelName: String
    var temperature: Double?
    var topP: Double?
    var maxTokens: Int?
    var thinkingMode: LLMThinkingMode?
    var reasoningEffort: LLMReasoningEffort?

    init(
        providerProfileID: UUID,
        providerName: String,
        modelProfileID: UUID,
        modelProfileName: String,
        baseURL: String,
        apiStyle: LLMAPIStyle = .chatCompletions,
        apiKeyRef: String,
        modelName: String,
        temperature: Double? = nil,
        topP: Double? = nil,
        maxTokens: Int? = nil,
        thinkingMode: LLMThinkingMode? = nil,
        reasoningEffort: LLMReasoningEffort? = nil
    ) {
        self.providerProfileID = providerProfileID
        self.providerName = providerName
        self.modelProfileID = modelProfileID
        self.modelProfileName = modelProfileName
        self.baseURL = baseURL
        self.apiStyle = apiStyle
        self.apiKeyRef = apiKeyRef
        self.modelName = modelName
        self.temperature = temperature
        self.topP = topP
        self.maxTokens = maxTokens
        self.thinkingMode = thinkingMode
        self.reasoningEffort = reasoningEffort
    }

    /// Stable identity for translation output. Keep this separate from the
    /// persisted model profile ID because editing advanced parameters changes
    /// the generated translation without creating a new profile.
    var translationCacheIdentity: String {
        let temperatureIdentity = temperature.map { String($0) } ?? "default"
        let topPIdentity = topP.map { String($0) } ?? "default"
        let maxTokensIdentity = maxTokens.map { String($0) } ?? "default"
        return [
            "model=\(modelName)",
            "api=\(apiStyle.rawValue)",
            "temperature=\(temperatureIdentity)",
            "topP=\(topPIdentity)",
            "maxTokens=\(maxTokensIdentity)",
            "thinking=\(thinkingMode?.rawValue ?? "default")",
            "reasoning=\(reasoningEffort?.rawValue ?? "default")",
            "prompt=\(AcademicTranslationPrompt.version)",
        ].joined(separator: "|")
    }
}

struct ResolvedLLMModelRoute: Sendable {
    var snapshot: LLMModelRouteSnapshot
    var apiKey: String
}
