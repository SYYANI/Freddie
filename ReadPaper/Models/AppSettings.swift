import Foundation
import SwiftData

@Model
final class AppSettings {
    @Attribute(.unique) var id: UUID
    var openAIBaseURL: String
    var normalModelName: String
    var quickModelName: String
    var heavyModelName: String
    var targetLanguage: String
    var htmlTranslationConcurrency: Int
    var babelDocQPS: Int
    var babelDocVersion: String
    var createdAt: Date
    var modifiedAt: Date

    init(
        id: UUID = UUID(),
        openAIBaseURL: String = "https://api.openai.com/v1",
        normalModelName: String = "gpt-4o-mini",
        quickModelName: String = "gpt-4o-mini",
        heavyModelName: String = "gpt-4o-mini",
        targetLanguage: String = "zh-CN",
        htmlTranslationConcurrency: Int = 4,
        babelDocQPS: Int = 4,
        babelDocVersion: String = "0.5.24",
        createdAt: Date = Date(),
        modifiedAt: Date = Date()
    ) {
        self.id = id
        self.openAIBaseURL = openAIBaseURL
        self.normalModelName = normalModelName
        self.quickModelName = quickModelName
        self.heavyModelName = heavyModelName
        self.targetLanguage = targetLanguage
        self.htmlTranslationConcurrency = htmlTranslationConcurrency
        self.babelDocQPS = babelDocQPS
        self.babelDocVersion = babelDocVersion
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }
}
