import Foundation
import SwiftData

@Model
final class PaperFolder {
    @Attribute(.unique) var id: UUID
    var name: String
    /// Reserved for nested folders; the library currently shows one level only.
    var parentID: UUID?
    var createdAt: Date
    var modifiedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        parentID: UUID? = nil,
        createdAt: Date = Date(),
        modifiedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }
}

/// Places a paper in a folder. Kept apart from `Paper` so moving a paper
/// neither touches `Paper.modifiedAt` (which orders the library) nor its schema.
@Model
final class PaperFolderMembership {
    @Attribute(.unique) var paperID: UUID
    var folderID: UUID
    var addedAt: Date

    init(paperID: UUID, folderID: UUID, addedAt: Date = Date()) {
        self.paperID = paperID
        self.folderID = folderID
        self.addedAt = addedAt
    }
}
