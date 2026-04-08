import Foundation
import SwiftData

@Model
final class Note {
    @Attribute(.unique) var id: UUID
    var paperID: UUID
    var attachmentID: UUID?
    var quote: String
    var body: String
    var pageIndex: Int?
    var htmlSelector: String?
    var createdAt: Date
    var modifiedAt: Date

    init(
        id: UUID = UUID(),
        paperID: UUID,
        attachmentID: UUID? = nil,
        quote: String = "",
        body: String = "",
        pageIndex: Int? = nil,
        htmlSelector: String? = nil,
        createdAt: Date = Date(),
        modifiedAt: Date = Date()
    ) {
        self.id = id
        self.paperID = paperID
        self.attachmentID = attachmentID
        self.quote = quote
        self.body = body
        self.pageIndex = pageIndex
        self.htmlSelector = htmlSelector
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }
}
