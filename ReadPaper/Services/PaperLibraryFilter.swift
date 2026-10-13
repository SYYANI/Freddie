import Foundation
import SwiftData

/// Sidebar filter. View state only: it is never persisted, so a relaunch always
/// shows the whole library.
struct PaperLibraryFilter: Equatable {
    enum Criterion: String, CaseIterable, Identifiable {
        case favorites
        case translated
        case notes

        var id: String { rawValue }
    }

    /// What the filter needs to know that `Paper` itself does not record.
    struct Facts {
        var translatedPaperIDs: Set<UUID> = []
        var notedPaperIDs: Set<UUID> = []
        var itemTypes: PaperItemTypeResolution?
    }

    var criteria: Set<Criterion> = []
    var itemTypes: Set<PaperItemType> = []

    var isActive: Bool {
        !criteria.isEmpty || !itemTypes.isEmpty
    }

    /// A paper must meet every selected criterion and be one of the selected
    /// item types, if any are selected.
    func matches(_ paper: Paper, facts: Facts) -> Bool {
        if !itemTypes.isEmpty {
            let itemType = facts.itemTypes?.itemType(of: paper.id) ?? .document
            guard itemTypes.contains(itemType) else { return false }
        }

        return criteria.allSatisfy { criterion in
            switch criterion {
            case .favorites:
                return paper.isFavorite
            case .translated:
                return facts.translatedPaperIDs.contains(paper.id)
            case .notes:
                return facts.notedPaperIDs.contains(paper.id)
            }
        }
    }

    /// Papers with a translated PDF (BabelDOC or LaTeX) or cached HTML translations.
    static func translatedPaperIDs(
        attachments: [PaperAttachment],
        htmlTranslatedPaperIDs: Set<UUID>
    ) -> Set<UUID> {
        htmlTranslatedPaperIDs.union(
            attachments.lazy.filter { $0.kind == .translatedPDF }.map(\.paperID)
        )
    }

    /// Fetched on demand instead of through `@Query`, so a running HTML translation
    /// does not redraw the whole window for every cached segment.
    @MainActor
    static func htmlTranslatedPaperIDs(modelContext: ModelContext) throws -> Set<UUID> {
        let htmlSourceType = "html"
        var descriptor = FetchDescriptor<TranslationSegment>(
            predicate: #Predicate { $0.sourceType == htmlSourceType }
        )
        descriptor.propertiesToFetch = [\.paperID]
        return Set(try modelContext.fetch(descriptor).map(\.paperID))
    }
}
