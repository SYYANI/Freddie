import Foundation

struct TranslationPreferencesSnapshot: Sendable {
    var targetLanguage: String
    var htmlTranslationConcurrency: Int
    var babelDocQPS: Int
    var babelDocVersion: String

    init(
        targetLanguage: String,
        htmlTranslationConcurrency: Int,
        babelDocQPS: Int,
        babelDocVersion: String
    ) {
        self.targetLanguage = targetLanguage
        self.htmlTranslationConcurrency = htmlTranslationConcurrency
        self.babelDocQPS = babelDocQPS
        self.babelDocVersion = babelDocVersion
    }

    init(_ settings: AppSettings) {
        self.targetLanguage = settings.targetLanguage
        self.htmlTranslationConcurrency = settings.htmlTranslationConcurrency
        self.babelDocQPS = settings.babelDocQPS
        self.babelDocVersion = settings.babelDocVersion
    }
}
