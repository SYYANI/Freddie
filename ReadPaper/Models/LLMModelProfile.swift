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
    // Compatibility fields are optional so existing stores can adopt them via
    // lightweight migration. Do not remove or rename them without a versioned
    // SwiftData migration plan.
    var thinkingMode: String?
    var reasoningEffort: String?
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
        thinkingMode: LLMThinkingMode? = nil,
        reasoningEffort: LLMReasoningEffort? = nil,
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
        self.thinkingMode = thinkingMode?.rawValue
        self.reasoningEffort = reasoningEffort?.rawValue
        self.isEnabled = isEnabled
        self.lastTestedAt = lastTestedAt
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }

    var thinkingModeValue: LLMThinkingMode? {
        get { thinkingMode.flatMap(LLMThinkingMode.init(rawValue:)) }
        set { thinkingMode = newValue?.rawValue }
    }

    var reasoningEffortValue: LLMReasoningEffort? {
        get { reasoningEffort.flatMap(LLMReasoningEffort.init(rawValue:)) }
        set { reasoningEffort = newValue?.rawValue }
    }
}
