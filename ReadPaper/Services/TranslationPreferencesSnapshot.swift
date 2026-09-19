import Foundation

struct TranslationPreferencesSnapshot: Sendable {
    var targetLanguage: String
    var htmlTranslationConcurrency: Int
    var babelDocQPS: Int
    var babelDocVersion: String
    var translationGlossary: String

    init(
        targetLanguage: String,
        htmlTranslationConcurrency: Int,
        babelDocQPS: Int,
        babelDocVersion: String,
        translationGlossary: String = ""
    ) {
        self.targetLanguage = targetLanguage
        self.htmlTranslationConcurrency = htmlTranslationConcurrency
        self.babelDocQPS = babelDocQPS
        self.babelDocVersion = babelDocVersion
        self.translationGlossary = TranslationGlossaryPreference.normalized(translationGlossary)
    }

    init(_ settings: AppSettings) {
        self.targetLanguage = settings.targetLanguage
        self.htmlTranslationConcurrency = settings.htmlTranslationConcurrency
        self.babelDocQPS = settings.babelDocQPS
        self.babelDocVersion = settings.babelDocVersion
        self.translationGlossary = TranslationGlossaryPreference.current()
    }

    func translationCacheIdentity(for route: LLMModelRouteSnapshot) -> String {
        guard translationGlossary.isEmpty == false else {
            return route.translationCacheIdentity
        }
        return "\(route.translationCacheIdentity)|glossary=\(Hashing.sha256Hex(translationGlossary))"
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
