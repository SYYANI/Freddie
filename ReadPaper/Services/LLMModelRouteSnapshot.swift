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
}

struct ResolvedLLMModelRoute: Sendable {
    var snapshot: LLMModelRouteSnapshot
    var apiKey: String
}
