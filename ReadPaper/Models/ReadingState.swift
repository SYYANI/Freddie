import Foundation
import SwiftData

@Model
final class ReadingState {
    @Attribute(.unique) var id: UUID
    var paperID: UUID
    var attachmentID: UUID?
    var readerModeRawValue: String
    var pageIndex: Int
    var scrollRatio: Double
    var zoomScale: Double
    var htmlAnchor: String?
    var modifiedAt: Date

    init(
        id: UUID = UUID(),
        paperID: UUID,
        attachmentID: UUID? = nil,
        readerMode: ReaderMode = .html,
        pageIndex: Int = 0,
        scrollRatio: Double = 0,
        zoomScale: Double = 1,
        htmlAnchor: String? = nil,
        modifiedAt: Date = Date()
    ) {
        self.id = id
        self.paperID = paperID
        self.attachmentID = attachmentID
        self.readerModeRawValue = readerMode.rawValue
        self.pageIndex = pageIndex
        self.scrollRatio = scrollRatio
        self.zoomScale = zoomScale
        self.htmlAnchor = htmlAnchor
        self.modifiedAt = modifiedAt
    }

    var readerMode: ReaderMode {
        get { ReaderMode(rawValue: readerModeRawValue) ?? .html }
        set { readerModeRawValue = newValue.rawValue }
    }
}
