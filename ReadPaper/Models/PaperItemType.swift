import Foundation
import SwiftData

/// Bibliographic item type. Raw values are Zotero's item type identifiers
/// (also used by CSL and Zotero's RDF/RIS mappings), so a later citation export
/// or Zotero import can use them as is.
enum PaperItemType: String, CaseIterable, Identifiable, Sendable {
    case artwork
    case audioRecording
    case bill
    case blogPost
    case book
    case bookSection
    case `case`
    case computerProgram
    case conferencePaper
    case dataset
    case dictionaryEntry
    case document
    case email
    case encyclopediaArticle
    case film
    case forumPost
    case hearing
    case instantMessage
    case interview
    case journalArticle
    case letter
    case magazineArticle
    case manuscript
    case map
    case newspaperArticle
    case patent
    case podcast
    case preprint
    case presentation
    case radioBroadcast
    case report
    case standard
    case statute
    case thesis
    case tvBroadcast
    case videoRecording
    case webpage

    var id: String { rawValue }

    /// Listed first in the type picker; the rest go under "More Types".
    static let common: [PaperItemType] = [
        .journalArticle,
        .conferencePaper,
        .preprint,
        .thesis,
        .book,
        .bookSection,
        .report,
        .webpage,
        .document,
    ]

    /// Sorted by localized title, looking each title up only once.
    static func sortedByTitle(
        _ itemTypes: some Sequence<PaperItemType>,
        bundle: Bundle? = nil
    ) -> [(itemType: PaperItemType, title: String)] {
        itemTypes
            .map { (itemType: $0, title: $0.title(bundle: bundle)) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func title(bundle: Bundle? = nil) -> String {
        let bundle = bundle ?? AppLocalization.currentBundle()
        switch self {
        case .artwork: return String(localized: "Artwork", bundle: bundle)
        case .audioRecording: return String(localized: "Audio Recording", bundle: bundle)
        case .bill: return String(localized: "Bill", bundle: bundle)
        case .blogPost: return String(localized: "Blog Post", bundle: bundle)
        case .book: return String(localized: "Book", bundle: bundle)
        case .bookSection: return String(localized: "Book Section", bundle: bundle)
        case .case: return String(localized: "Case", bundle: bundle)
        case .computerProgram: return String(localized: "Software", bundle: bundle)
        case .conferencePaper: return String(localized: "Conference Paper", bundle: bundle)
        case .dataset: return String(localized: "Dataset", bundle: bundle)
        case .dictionaryEntry: return String(localized: "Dictionary Entry", bundle: bundle)
        case .document: return String(localized: "Document", bundle: bundle)
        case .email: return String(localized: "E-mail", bundle: bundle)
        case .encyclopediaArticle: return String(localized: "Encyclopedia Article", bundle: bundle)
        case .film: return String(localized: "Film", bundle: bundle)
        case .forumPost: return String(localized: "Forum Post", bundle: bundle)
        case .hearing: return String(localized: "Hearing", bundle: bundle)
        case .instantMessage: return String(localized: "Instant Message", bundle: bundle)
        case .interview: return String(localized: "Interview", bundle: bundle)
        case .journalArticle: return String(localized: "Journal Article", bundle: bundle)
        case .letter: return String(localized: "Letter", bundle: bundle)
        case .magazineArticle: return String(localized: "Magazine Article", bundle: bundle)
        case .manuscript: return String(localized: "Manuscript", bundle: bundle)
        case .map: return String(localized: "Map", bundle: bundle)
        case .newspaperArticle: return String(localized: "Newspaper Article", bundle: bundle)
        case .patent: return String(localized: "Patent", bundle: bundle)
        case .podcast: return String(localized: "Podcast", bundle: bundle)
        case .preprint: return String(localized: "Preprint", bundle: bundle)
        case .presentation: return String(localized: "Presentation", bundle: bundle)
        case .radioBroadcast: return String(localized: "Radio Broadcast", bundle: bundle)
        case .report: return String(localized: "Report", bundle: bundle)
        case .standard: return String(localized: "Standard", bundle: bundle)
        case .statute: return String(localized: "Statute", bundle: bundle)
        case .thesis: return String(localized: "Thesis", bundle: bundle)
        case .tvBroadcast: return String(localized: "TV Broadcast", bundle: bundle)
        case .videoRecording: return String(localized: "Video Recording", bundle: bundle)
        case .webpage: return String(localized: "Web Page", bundle: bundle)
        }
    }
}

/// An item type the user chose by hand. Papers without one use the type
/// detected from how they were imported, so existing libraries need no
/// backfill. Kept apart from `Paper`, like folder membership, so neither its
/// schema nor `modifiedAt` (which orders the library) changes.
@Model
final class PaperItemTypeAssignment {
    @Attribute(.unique) var paperID: UUID
    var itemTypeRawValue: String
    var assignedAt: Date

    init(paperID: UUID, itemType: PaperItemType, assignedAt: Date = Date()) {
        self.paperID = paperID
        self.itemTypeRawValue = itemType.rawValue
        self.assignedAt = assignedAt
    }

    /// Nil for a raw value a newer version wrote; the paper then falls back to
    /// its detected type.
    var itemType: PaperItemType? {
        PaperItemType(rawValue: itemTypeRawValue)
    }
}
