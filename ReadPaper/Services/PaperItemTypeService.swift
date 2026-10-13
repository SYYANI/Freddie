import Foundation
import SwiftData

/// Every paper's item type: the user's choice when there is one, otherwise the
/// type detected from how the paper was imported.
struct PaperItemTypeResolution {
    private let detectedTypes: [UUID: PaperItemType]
    private let assignedTypes: [UUID: PaperItemType]

    init(papers: [Paper], attachments: [PaperAttachment], assignments: [PaperItemTypeAssignment]) {
        let webPagePaperIDs = Set(
            attachments.lazy
                .filter { $0.source == .webPage && $0.kind == .html }
                .map(\.paperID)
        )
        var detectedTypes: [UUID: PaperItemType] = [:]
        for paper in papers {
            detectedTypes[paper.id] = Self.detectedType(
                for: paper,
                hasWebPageHTML: webPagePaperIDs.contains(paper.id)
            )
        }

        var assignedTypes: [UUID: PaperItemType] = [:]
        for assignment in assignments {
            if let itemType = assignment.itemType {
                assignedTypes[assignment.paperID] = itemType
            }
        }

        self.detectedTypes = detectedTypes
        self.assignedTypes = assignedTypes
    }

    /// arXiv papers are preprints and HTML web imports are web pages. Anything
    /// else, including a PDF with a DOI, stays a generic document: a DOI alone
    /// does not say whether it is a journal article or a conference paper.
    static func detectedType(for paper: Paper, hasWebPageHTML: Bool) -> PaperItemType {
        if paper.arxivID != nil {
            return .preprint
        }
        if hasWebPageHTML {
            return .webpage
        }
        return .document
    }

    func itemType(of paperID: UUID) -> PaperItemType {
        assignedTypes[paperID] ?? detectedType(of: paperID)
    }

    func detectedType(of paperID: UUID) -> PaperItemType {
        detectedTypes[paperID] ?? .document
    }

    func isAssigned(_ paperID: UUID) -> Bool {
        assignedTypes[paperID] != nil
    }

    func selection(for paperID: UUID) -> PaperItemTypeSelection {
        PaperItemTypeSelection(
            itemType: itemType(of: paperID),
            detectedType: detectedType(of: paperID),
            isAssigned: isAssigned(paperID)
        )
    }

    func counts(in papers: [Paper]) -> [PaperItemType: Int] {
        papers.reduce(into: [:]) { counts, paper in
            counts[itemType(of: paper.id), default: 0] += 1
        }
    }
}

/// One paper's item type as the inspector shows it. Equatable so the inspector
/// is not redrawn when unrelated papers change.
struct PaperItemTypeSelection: Equatable {
    var itemType: PaperItemType
    var detectedType: PaperItemType
    var isAssigned: Bool
}

@MainActor
struct PaperItemTypeService {
    /// Choosing the detected type, or nil, removes the user's choice so the
    /// paper follows detection again.
    func setItemType(
        _ itemType: PaperItemType?,
        for paperID: UUID,
        detectedType: PaperItemType,
        modelContext: ModelContext
    ) throws {
        do {
            let descriptor = FetchDescriptor<PaperItemTypeAssignment>(
                predicate: #Predicate<PaperItemTypeAssignment> { $0.paperID == paperID }
            )
            let existing = try modelContext.fetch(descriptor)

            if let itemType, itemType != detectedType {
                if let assignment = existing.first {
                    assignment.itemTypeRawValue = itemType.rawValue
                    assignment.assignedAt = Date()
                    existing.dropFirst().forEach(modelContext.delete)
                } else {
                    modelContext.insert(PaperItemTypeAssignment(paperID: paperID, itemType: itemType))
                }
            } else {
                existing.forEach(modelContext.delete)
            }
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }
}
