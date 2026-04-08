import Foundation
import SwiftData

@Model
final class TranslationSegment {
    @Attribute(.unique) var id: UUID
    var paperID: UUID
    var sourceType: String
    var targetLanguage: String
    var sourceHash: String
    var sourceText: String
    var translatedText: String
    var modelName: String
    var createdAt: Date
    var modifiedAt: Date

    init(
        id: UUID = UUID(),
        paperID: UUID,
        sourceType: String,
        targetLanguage: String,
        sourceHash: String,
        sourceText: String,
        translatedText: String,
        modelName: String,
        createdAt: Date = Date(),
        modifiedAt: Date = Date()
    ) {
        self.id = id
        self.paperID = paperID
        self.sourceType = sourceType
        self.targetLanguage = targetLanguage
        self.sourceHash = sourceHash
        self.sourceText = sourceText
        self.translatedText = translatedText
        self.modelName = modelName
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }

    static func cacheKey(paperID: UUID, sourceType: String, targetLanguage: String, sourceHash: String) -> String {
        "\(paperID.uuidString)|\(sourceType)|\(targetLanguage)|\(sourceHash)"
    }
}
