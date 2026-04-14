import Foundation
import SwiftData

@Model
final class PaperAttachment {
    @Attribute(.unique) var id: UUID
    var paperID: UUID
    var kindRawValue: String
    var sourceRawValue: String
    var filename: String
    var filePath: String
    var translatedLastPage: Int?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        paperID: UUID,
        kind: AttachmentKind,
        source: AttachmentSource,
        filename: String,
        filePath: String,
        translatedLastPage: Int? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.paperID = paperID
        self.kindRawValue = kind.rawValue
        self.sourceRawValue = source.rawValue
        self.filename = filename
        self.filePath = filePath
        self.translatedLastPage = translatedLastPage
        self.createdAt = createdAt
    }

    var kind: AttachmentKind {
        get { AttachmentKind(rawValue: kindRawValue) ?? .resource }
        set { kindRawValue = newValue.rawValue }
    }

    var source: AttachmentSource {
        get { AttachmentSource(rawValue: sourceRawValue) ?? .generated }
        set { sourceRawValue = newValue.rawValue }
    }

    var fileURL: URL {
        URL(fileURLWithPath: filePath)
    }
}
