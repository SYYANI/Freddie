import Foundation

struct AppSettingsSnapshot: Sendable {
    var openAIBaseURL: String
    var normalModelName: String
    var quickModelName: String
    var heavyModelName: String
    var targetLanguage: String
    var htmlTranslationConcurrency: Int
    var babelDocQPS: Int
    var babelDocVersion: String

    init(
        openAIBaseURL: String,
        normalModelName: String,
        quickModelName: String,
        heavyModelName: String,
        targetLanguage: String,
        htmlTranslationConcurrency: Int,
        babelDocQPS: Int,
        babelDocVersion: String
    ) {
        self.openAIBaseURL = openAIBaseURL
        self.normalModelName = normalModelName
        self.quickModelName = quickModelName
        self.heavyModelName = heavyModelName
        self.targetLanguage = targetLanguage
        self.htmlTranslationConcurrency = htmlTranslationConcurrency
        self.babelDocQPS = babelDocQPS
        self.babelDocVersion = babelDocVersion
    }

    init(_ settings: AppSettings) {
        self.openAIBaseURL = settings.openAIBaseURL
        self.normalModelName = settings.normalModelName
        self.quickModelName = settings.quickModelName
        self.heavyModelName = settings.heavyModelName
        self.targetLanguage = settings.targetLanguage
        self.htmlTranslationConcurrency = settings.htmlTranslationConcurrency
        self.babelDocQPS = settings.babelDocQPS
        self.babelDocVersion = settings.babelDocVersion
    }
}
