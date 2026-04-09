import Foundation
import SwiftData

@Model
final class LLMProviderProfile {
    @Attribute(.unique) var id: UUID
    var name: String
    var baseURL: String
    var apiKeyRef: String
    var testModel: String
    var isEnabled: Bool
    var createdAt: Date
    var modifiedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        baseURL: String,
        apiKeyRef: String,
        testModel: String,
        isEnabled: Bool = true,
        createdAt: Date = Date(),
        modifiedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.apiKeyRef = apiKeyRef
        self.testModel = testModel
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }
}
