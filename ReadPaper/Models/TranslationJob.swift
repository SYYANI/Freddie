import Foundation
import SwiftData

@Model
final class TranslationJob {
    @Attribute(.unique) var id: UUID
    var paperID: UUID
    var attachmentID: UUID?
    var kind: String
    var targetLanguage: String
    var stateRawValue: String
    var progress: Double
    var processedSegments: Int
    var totalSegments: Int
    var lastError: String?
    var createdAt: Date
    var modifiedAt: Date

    init(
        id: UUID = UUID(),
        paperID: UUID,
        attachmentID: UUID? = nil,
        kind: String,
        targetLanguage: String = "zh-CN",
        state: TranslationJobState = .queued,
        progress: Double = 0,
        processedSegments: Int = 0,
        totalSegments: Int = 0,
        lastError: String? = nil,
        createdAt: Date = Date(),
        modifiedAt: Date = Date()
    ) {
        self.id = id
        self.paperID = paperID
        self.attachmentID = attachmentID
        self.kind = kind
        self.targetLanguage = targetLanguage
        self.stateRawValue = state.rawValue
        self.progress = progress
        self.processedSegments = processedSegments
        self.totalSegments = totalSegments
        self.lastError = lastError
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }

    var state: TranslationJobState {
        get { TranslationJobState(rawValue: stateRawValue) ?? .queued }
        set { stateRawValue = newValue.rawValue }
    }
}
