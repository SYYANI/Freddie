import BabelDocKit
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
    /// Anthropic Messages API (`POST /v1/messages`, `x-api-key` auth).
    case anthropicMessages = "anthropic-messages"

    /// Returns a caller-chosen sampling default (for example a translation
    /// temperature) for use when the model profile leaves the value unset.
    /// Current Claude models reject `temperature` / `top_p`, so the Anthropic
    /// protocol only sends sampling values the user configured explicitly.
    func samplingDefault(_ value: Double) -> Double? {
        self == .anthropicMessages ? nil : value
    }

    /// Protocols with a provider-executed web search tool: the Responses API
    /// `web_search` tool and the Anthropic Messages `web_search_20250305`
    /// server tool. Chat Completions has no server-side search.
    var supportsServerWebSearch: Bool {
        self != .chatCompletions
    }

    /// BabelDOC speaks Chat Completions or Anthropic Messages. OpenAI
    /// Responses providers also serve `chat/completions`, which BabelDOC has
    /// always used for them.
    var babelDocAPIStyle: BabelDocLLMAPIStyle {
        switch self {
        case .chatCompletions, .responses: .chatCompletions
        case .anthropicMessages: .anthropicMessages
        }
    }
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

/// Whether a model follows instructions or only translates. Translation-only
/// models (HY-MT, NLLB, …) translate the whole prompt envelope, titles and
/// neighboring paragraphs included, so they get the plain prompt instead.
enum LLMTranslationModelKind: String, CaseIterable, Sendable {
    /// Starts with the full prompt and switches to the plain prompt during a run
    /// once the model keeps repeating the envelope. "Detect" in the model settings
    /// replaces it with one of the explicit kinds.
    case automatic = "auto"
    case translationOnly = "translation-only"
    case general

    var usesPlainPrompt: Bool {
        self == .translationOnly
    }

    /// BabelDOC follows the same rule: translation-only models get the plain prompt,
    /// general models the envelope, and "automatic" starts with the envelope and
    /// switches once the model keeps translating it.
    var babelDocPromptStyle: BabelDocTranslationPromptStyle {
        switch self {
        case .automatic: .adaptive
        case .translationOnly: .plain
        case .general: .envelope
        }
    }
}

/// Stored in UserDefaults per model profile, like the provider API style, so the
/// SwiftData schema stays unchanged.
struct LLMTranslationModelKindStore {
    static let keyPrefix = "ReadPaper.LLM.TranslationModelKind."

    let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func kind(for modelID: UUID) -> LLMTranslationModelKind {
        userDefaults.string(forKey: key(for: modelID)).flatMap(LLMTranslationModelKind.init(rawValue:))
            ?? .automatic
    }

    func setKind(_ kind: LLMTranslationModelKind, for modelID: UUID) {
        if kind == .automatic {
            userDefaults.removeObject(forKey: key(for: modelID))
        } else {
            userDefaults.set(kind.rawValue, forKey: key(for: modelID))
        }
    }

    private func key(for modelID: UUID) -> String {
        Self.keyPrefix + modelID.uuidString.lowercased()
    }
}
