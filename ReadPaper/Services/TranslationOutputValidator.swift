import Foundation

enum TranslationOutputIssue: String, Equatable, Sendable {
    /// The output contains the prompt envelope, e.g. `<<<SOURCE_SEGMENT_TO_TRANSLATE>>>`.
    case promptEcho
    /// The output is the untranslated source segment.
    case sourceEcho
    /// The output repeats a neighboring context segment that is not part of the source.
    case contextEcho
    /// The output is far longer than any faithful translation of the source.
    case excessiveLength
    /// Protected placeholders such as `[PROTECTED_0]` were lost, duplicated, or invented.
    case placeholderMismatch

    /// Fatal issues mean the output is not a translation at all and must never be shown or cached.
    /// A placeholder mismatch is still a usable translation, so it is retried but accepted as a last resort.
    var isFatal: Bool {
        self != .placeholderMismatch
    }

    var localizedDescription: String {
        switch self {
        case .promptEcho:
            return AppLocalization.localized("the model repeated the translation prompt")
        case .sourceEcho:
            return AppLocalization.localized("the model returned the source text untranslated")
        case .contextEcho:
            return AppLocalization.localized("the model repeated neighboring context")
        case .excessiveLength:
            return AppLocalization.localized("the output was far longer than the source")
        case .placeholderMismatch:
            return AppLocalization.localized("protected placeholders were lost or duplicated")
        }
    }
}

struct TranslationOutputValidationError: LocalizedError, Equatable {
    let issue: TranslationOutputIssue
    let attempts: Int

    var errorDescription: String? {
        AppLocalization.format(
            "The model returned an invalid translation after %lld attempts: %@.",
            attempts,
            issue.localizedDescription
        )
    }
}

enum TranslationOutputValidator {
    static let maximumAttempts = 3

    private static let placeholderPattern = try! NSRegularExpression(
        pattern: #"\[(?:PROTECTED_SEMANTIC|PROTECTED|BABELDOC_FORMULA)_\d+\]"#
    )
    /// Below this size an identical output may legitimately be a name, symbol, or short title.
    private static let minimumComparableWords = 6

    static func issue(
        in translation: String,
        source: String,
        context: AcademicTranslationContext
    ) -> TranslationOutputIssue? {
        if echoesPromptEnvelope(translation, source: source) {
            return .promptEcho
        }

        let normalizedTranslation = normalized(translation)
        let normalizedSource = normalized(source)
        if isComparable(normalizedSource), normalizedTranslation == normalizedSource {
            return .sourceEcho
        }

        for neighbor in [context.previousSegment, context.nextSegment].compactMap({ $0 }) {
            let normalizedNeighbor = normalized(neighbor)
            guard isComparable(normalizedNeighbor),
                  normalizedSource.contains(normalizedNeighbor) == false
            else {
                continue
            }
            if normalizedTranslation.contains(normalizedNeighbor) {
                return .contextEcho
            }
        }

        if translation.count > source.count * 3 + 200 {
            return .excessiveLength
        }

        if placeholderCounts(in: translation) != placeholderCounts(in: source) {
            return .placeholderMismatch
        }

        return nil
    }

    private static func echoesPromptEnvelope(_ translation: String, source: String) -> Bool {
        AcademicTranslationPrompt.envelopeLabels.contains { label in
            translation.contains(label) && source.contains(label) == false
        }
    }

    private static func placeholderCounts(in text: String) -> [String: Int] {
        let range = NSRange(text.startIndex..., in: text)
        var counts: [String: Int] = [:]
        for match in placeholderPattern.matches(in: text, range: range) {
            guard let tokenRange = Range(match.range, in: text) else { continue }
            counts[String(text[tokenRange]), default: 0] += 1
        }
        return counts
    }

    /// Case-, diacritic-, punctuation- and whitespace-insensitive form, so quote styles or
    /// re-wrapped lines do not hide an echo.
    private static func normalized(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        let words = folded.unicodeScalars
            .split { CharacterSet.alphanumerics.contains($0) == false }
            .map { String($0) }
        return words.joined(separator: " ")
    }

    private static func isComparable(_ normalizedText: String) -> Bool {
        normalizedText.split(separator: " ").count >= minimumComparableWords
    }
}

extension AcademicTranslationContext {
    /// Neighbor segments are the largest part of the prompt and the text weak models most often
    /// echo, so retries drop them while keeping titles and glossary.
    var withoutNeighborSegments: AcademicTranslationContext {
        AcademicTranslationContext(
            documentTitle: documentTitle,
            sectionTitle: sectionTitle,
            glossary: glossary
        )
    }
}

extension TranslationLLMClientProtocol {
    /// Translates and validates the output, retrying when the model echoes the prompt, the source,
    /// or its context. Throws `TranslationOutputValidationError` when every attempt is unusable.
    func validatedTranslate(
        _ text: String,
        targetLanguage: String,
        route: LLMModelRouteSnapshot,
        apiKey: String,
        context: AcademicTranslationContext,
        maximumAttempts: Int = TranslationOutputValidator.maximumAttempts
    ) async throws -> String {
        let attempts = max(1, maximumAttempts)
        var lastIssue = TranslationOutputIssue.promptEcho
        var usableFallback: String?

        for attempt in 1...attempts {
            try Task.checkCancellation()
            let translation = try await translate(
                text,
                targetLanguage: targetLanguage,
                route: route,
                apiKey: apiKey,
                context: attempt == 1 ? context : context.withoutNeighborSegments
            )
            guard let issue = TranslationOutputValidator.issue(in: translation, source: text, context: context) else {
                return translation
            }
            lastIssue = issue
            if issue.isFatal == false {
                usableFallback = translation
            }
        }

        if let usableFallback {
            return usableFallback
        }
        throw TranslationOutputValidationError(issue: lastIssue, attempts: attempts)
    }
}
