import Foundation

struct TranslationPreferencesSnapshot: Sendable {
    var targetLanguage: String
    var htmlTranslationConcurrency: Int
    var babelDocQPS: Int
    var babelDocVersion: String
    var translationGlossary: String
    /// PDF translation also translates text inside figures (tick labels,
    /// legends, panel titles).
    var translatesFigureText: Bool

    init(
        targetLanguage: String,
        htmlTranslationConcurrency: Int,
        babelDocQPS: Int,
        babelDocVersion: String,
        translationGlossary: String = "",
        translatesFigureText: Bool = PDFFigureTextTranslationPreference.defaultValue
    ) {
        self.targetLanguage = targetLanguage
        self.htmlTranslationConcurrency = htmlTranslationConcurrency
        self.babelDocQPS = babelDocQPS
        self.babelDocVersion = babelDocVersion
        self.translationGlossary = TranslationGlossaryPreference.normalized(translationGlossary)
        self.translatesFigureText = translatesFigureText
    }

    init(_ settings: AppSettings) {
        self.targetLanguage = settings.targetLanguage
        self.htmlTranslationConcurrency = settings.htmlTranslationConcurrency
        self.babelDocQPS = settings.babelDocQPS
        self.babelDocVersion = settings.babelDocVersion
        self.translationGlossary = TranslationGlossaryPreference.current()
        self.translatesFigureText = PDFFigureTextTranslationPreference.current()
    }

    func translationCacheIdentity(for route: LLMModelRouteSnapshot) -> String {
        guard translationGlossary.isEmpty == false else {
            return route.translationCacheIdentity
        }
        return "\(route.translationCacheIdentity)|glossary=\(Hashing.sha256Hex(translationGlossary))"
    }
}

/// Whether PDF translation translates text drawn inside figures. Stored in
/// UserDefaults rather than `AppSettings` to keep the SwiftData schema unchanged.
enum PDFFigureTextTranslationPreference {
    static let userDefaultsKey = "ReadPaper.Settings.PDFTranslateFigureText"
    static let defaultValue = false

    static func current(userDefaults: UserDefaults = .standard) -> Bool {
        userDefaults.object(forKey: userDefaultsKey) as? Bool ?? defaultValue
    }
}

struct PDFTranslationBatchPreference {
    static let userDefaultsKey = "ReadPaper.Settings.PDFTranslationPageBatchSize"
    static let defaultValue = 10
    static let allowedRange: ClosedRange<Int> = 1...50

    static func normalized(_ value: Int) -> Int {
        min(max(value, allowedRange.lowerBound), allowedRange.upperBound)
    }
}
