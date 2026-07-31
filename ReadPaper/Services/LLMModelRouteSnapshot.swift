import Foundation

struct LLMModelRouteSnapshot: Equatable, Sendable {
    var providerProfileID: UUID
    var providerName: String
    var modelProfileID: UUID
    var modelProfileName: String
    var baseURL: String
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
        self.apiKeyRef = apiKeyRef
        self.modelName = modelName
        self.temperature = temperature
        self.topP = topP
        self.maxTokens = maxTokens
        self.thinkingMode = thinkingMode
        self.reasoningEffort = reasoningEffort
    }
}

struct ResolvedLLMModelRoute: Sendable {
    var snapshot: LLMModelRouteSnapshot
    var apiKey: String
}
