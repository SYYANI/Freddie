import Foundation
import SwiftData

/// Splits the library into folders and unfiled papers, in display order.
struct PaperLibraryGrouping {
    struct FolderSection: Identifiable {
        let folder: PaperFolder
        let papers: [Paper]

        var id: UUID { folder.id }
    }

    let folderSections: [FolderSection]
    let unfiledPapers: [Paper]
    private let folderIDByPaperID: [UUID: UUID]

    /// Paper order within each group follows `papers`; folders sort by name.
    /// A membership whose folder no longer exists leaves the paper unfiled.
    init(papers: [Paper], folders: [PaperFolder], memberships: [PaperFolderMembership]) {
        let sortedFolders = folders.sorted { lhs, rhs in
            switch lhs.name.localizedStandardCompare(rhs.name) {
            case .orderedAscending:
                return true
            case .orderedDescending:
                return false
            case .orderedSame:
                return lhs.createdAt < rhs.createdAt
            }
        }
        let knownFolderIDs = Set(sortedFolders.map(\.id))

        var folderIDByPaperID: [UUID: UUID] = [:]
        for membership in memberships where knownFolderIDs.contains(membership.folderID) {
            folderIDByPaperID[membership.paperID] = membership.folderID
        }

        var papersByFolderID: [UUID: [Paper]] = [:]
        var unfiledPapers: [Paper] = []
        for paper in papers {
            if let folderID = folderIDByPaperID[paper.id] {
                papersByFolderID[folderID, default: []].append(paper)
            } else {
                unfiledPapers.append(paper)
            }
        }

        self.folderSections = sortedFolders.map { folder in
            FolderSection(folder: folder, papers: papersByFolderID[folder.id] ?? [])
        }
        self.unfiledPapers = unfiledPapers
        self.folderIDByPaperID = folderIDByPaperID
    }

    var hasFolders: Bool {
        !folderSections.isEmpty
    }

    var orderedPaperIDs: [UUID] {
        folderSections.flatMap { $0.papers.map(\.id) } + unfiledPapers.map(\.id)
    }

    func folderID(containing paperID: UUID) -> UUID? {
        folderIDByPaperID[paperID]
    }
}

@MainActor
struct PaperFolderService {
    @discardableResult
    func createFolder(
        named name: String,
        containing paperID: UUID? = nil,
        modelContext: ModelContext
    ) throws -> PaperFolder {
        do {
            let existingNames = try modelContext.fetch(FetchDescriptor<PaperFolder>()).map(\.name)
            let trimmedName = Self.normalizedName(name)
            let folderName = trimmedName.isEmpty
                ? Self.uniqueName(AppLocalization.localized("New Folder"), existingNames: existingNames)
                : trimmedName
            let folder = PaperFolder(name: folderName)
            modelContext.insert(folder)
            if let paperID {
                try assign(paperID: paperID, to: folder.id, in: modelContext)
            }
            try modelContext.save()
            return folder
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    /// An empty name keeps the current one.
    func rename(_ folder: PaperFolder, to name: String, modelContext: ModelContext) throws {
        let trimmedName = Self.normalizedName(name)
        guard !trimmedName.isEmpty, trimmedName != folder.name else { return }

        folder.name = trimmedName
        folder.modifiedAt = Date()
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    /// Removes the folder only; its papers become unfiled.
    func delete(_ folder: PaperFolder, modelContext: ModelContext) throws {
        let folderID = folder.id
        do {
            let descriptor = FetchDescriptor<PaperFolderMembership>(
                predicate: #Predicate<PaperFolderMembership> { $0.folderID == folderID }
            )
            try modelContext.fetch(descriptor).forEach(modelContext.delete)
            modelContext.delete(folder)
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    /// Moving to `nil` removes the paper from its folder.
    func move(paperID: UUID, to folderID: UUID?, modelContext: ModelContext) throws {
        do {
            if let folderID {
                try assign(paperID: paperID, to: folderID, in: modelContext)
            } else {
                try memberships(of: paperID, in: modelContext).forEach(modelContext.delete)
            }
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private func assign(paperID: UUID, to folderID: UUID, in modelContext: ModelContext) throws {
        let existing = try memberships(of: paperID, in: modelContext)
        if let membership = existing.first {
            if membership.folderID != folderID {
                membership.folderID = folderID
                membership.addedAt = Date()
            }
            existing.dropFirst().forEach(modelContext.delete)
        } else {
            modelContext.insert(PaperFolderMembership(paperID: paperID, folderID: folderID))
        }
    }

    private func memberships(of paperID: UUID, in modelContext: ModelContext) throws -> [PaperFolderMembership] {
        let descriptor = FetchDescriptor<PaperFolderMembership>(
            predicate: #Predicate<PaperFolderMembership> { $0.paperID == paperID }
        )
        return try modelContext.fetch(descriptor)
    }

    static func normalizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Finder-style naming: "New Folder", then "New Folder 2", "New Folder 3", …
    static func uniqueName(_ baseName: String, existingNames: [String]) -> String {
        let taken = Set(existingNames)
        guard taken.contains(baseName) else { return baseName }
        var index = 2
        while taken.contains("\(baseName) \(index)") {
            index += 1
        }
        return "\(baseName) \(index)"
    }
}
