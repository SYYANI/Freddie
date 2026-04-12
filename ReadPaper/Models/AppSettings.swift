import Foundation
import SwiftData

@Model
final class AppSettings {
    @Attribute(.unique) var id: UUID
    var lastOpenedPaperID: UUID?
    var selectedHTMLModelProfileID: UUID?
    var selectedPDFModelProfileID: UUID?
    var targetLanguage: String
    var htmlTranslationConcurrency: Int
    var babelDocQPS: Int
    var babelDocVersion: String
    var createdAt: Date
    var modifiedAt: Date

    init(
        id: UUID = UUID(),
        lastOpenedPaperID: UUID? = nil,
        selectedHTMLModelProfileID: UUID? = nil,
        selectedPDFModelProfileID: UUID? = nil,
        targetLanguage: String = "zh-CN",
        htmlTranslationConcurrency: Int = 4,
        babelDocQPS: Int = 4,
        babelDocVersion: String = "0.5.24",
        createdAt: Date = Date(),
        modifiedAt: Date = Date()
    ) {
        self.id = id
        self.lastOpenedPaperID = lastOpenedPaperID
        self.selectedHTMLModelProfileID = selectedHTMLModelProfileID
        self.selectedPDFModelProfileID = selectedPDFModelProfileID
        self.targetLanguage = targetLanguage
        self.htmlTranslationConcurrency = htmlTranslationConcurrency
        self.babelDocQPS = babelDocQPS
        self.babelDocVersion = babelDocVersion
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }
}
