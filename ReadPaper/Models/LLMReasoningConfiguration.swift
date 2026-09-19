import Foundation

/// Thinking mode for OpenAI-compatible APIs (e.g. DeepSeek V4).
/// Chat Completions maps this to `thinking.type`; Responses maps disabled to
/// `reasoning.effort = "none"` and otherwise uses the selected effort.
enum LLMThinkingMode: String, CaseIterable, Sendable, Codable {
    case enabled
    case disabled
}

/// Reasoning effort for OpenAI-compatible APIs.
enum LLMReasoningEffort: String, CaseIterable, Sendable, Codable {
    case low
    case high
    case max
}

/// Wire protocol used by an OpenAI-compatible provider.
///
/// Keep this outside SwiftData. Provider-specific selections are stored in
/// UserDefaults so adding protocol support does not change the persisted model
/// schema used by older Freddie releases.
enum LLMAPIStyle: String, CaseIterable, Codable, Sendable {
    case chatCompletions = "chat-completions"
    case responses
}

struct LLMProviderAPIStyleStore {
    static let keyPrefix = "ReadPaper.LLM.ProviderAPIStyle."

    let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func apiStyle(for providerID: UUID) -> LLMAPIStyle {
        if let stored = userDefaults.string(forKey: key(for: providerID)),
           let style = LLMAPIStyle(rawValue: stored) {
            return style
        }
        return LLMDefaultProfiles.apiStyle(for: providerID) ?? .chatCompletions
    }

    func setAPIStyle(_ style: LLMAPIStyle, for providerID: UUID) {
        userDefaults.set(style.rawValue, forKey: key(for: providerID))
    }

    func removeAPIStyle(for providerID: UUID) {
        userDefaults.removeObject(forKey: key(for: providerID))
    }

    private func key(for providerID: UUID) -> String {
        Self.keyPrefix + providerID.uuidString.lowercased()
    }
}
