import Foundation

/// Thinking mode for OpenAI-compatible chat completions (e.g. DeepSeek V4).
/// Maps to the top-level `thinking: {"type": "enabled" | "disabled"}` body field.
enum LLMThinkingMode: String, CaseIterable, Sendable, Codable {
    case enabled
    case disabled
}

/// Reasoning effort for OpenAI-compatible chat completions.
/// Maps to the top-level `reasoning_effort` body field (`low` / `high` / `max`).
enum LLMReasoningEffort: String, CaseIterable, Sendable, Codable {
    case low
    case high
    case max
}
