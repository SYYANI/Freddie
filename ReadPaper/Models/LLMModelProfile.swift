import Foundation
import SwiftData

@Model
final class LLMModelProfile {
    @Attribute(.unique) var id: UUID
    var providerID: UUID
    var name: String
    var modelName: String
    var temperature: Double?
    var topP: Double?
    var maxTokens: Int?
    var isEnabled: Bool
    var lastTestedAt: Date?
    var createdAt: Date
    var modifiedAt: Date

    init(
        id: UUID = UUID(),
        providerID: UUID,
        name: String,
        modelName: String,
        temperature: Double? = nil,
        topP: Double? = nil,
        maxTokens: Int? = nil,
        isEnabled: Bool = true,
        lastTestedAt: Date? = nil,
        createdAt: Date = Date(),
        modifiedAt: Date = Date()
    ) {
        self.id = id
        self.providerID = providerID
        self.name = name
        self.modelName = modelName
        self.temperature = temperature
        self.topP = topP
        self.maxTokens = maxTokens
        self.isEnabled = isEnabled
        self.lastTestedAt = lastTestedAt
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }
}
