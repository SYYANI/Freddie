import Foundation
import SwiftData

@MainActor
struct PaperDeletionService {
    let fileStore: PaperFileStore

    init(fileStore: PaperFileStore = PaperFileStore()) {
        self.fileStore = fileStore
    }

    func delete(_ paper: Paper, modelContext: ModelContext) throws {
        do {
            try Self.deleteRecords(of: paper, in: modelContext)
            try fileStore.removeDirectory(for: paper.id)
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    /// Deletes the paper and every row that belongs to it, without saving or
    /// touching its files. Library sync applies remote deletions through this.
    static func deleteRecords(of paper: Paper, in modelContext: ModelContext) throws {
        let paperID = paper.id
        try deleteAttachments(for: paperID, in: modelContext)
        try deleteNotes(for: paperID, in: modelContext)
        try deleteReadingStates(for: paperID, in: modelContext)
        try deleteTranslationSegments(for: paperID, in: modelContext)
        try deleteTranslationJobs(for: paperID, in: modelContext)
        try deleteFolderMemberships(for: paperID, in: modelContext)
        try deleteItemTypeAssignments(for: paperID, in: modelContext)
        modelContext.delete(paper)
    }

    private static func deleteAttachments(for paperID: UUID, in modelContext: ModelContext) throws {
        let descriptor = FetchDescriptor<PaperAttachment>(
            predicate: #Predicate<PaperAttachment> { $0.paperID == paperID }
        )
        try modelContext.fetch(descriptor).forEach(modelContext.delete)
    }

    private static func deleteNotes(for paperID: UUID, in modelContext: ModelContext) throws {
        let descriptor = FetchDescriptor<Note>(
            predicate: #Predicate<Note> { $0.paperID == paperID }
        )
        try modelContext.fetch(descriptor).forEach(modelContext.delete)
    }

    private static func deleteReadingStates(for paperID: UUID, in modelContext: ModelContext) throws {
        let descriptor = FetchDescriptor<ReadingState>(
            predicate: #Predicate<ReadingState> { $0.paperID == paperID }
        )
        try modelContext.fetch(descriptor).forEach(modelContext.delete)
    }

    private static func deleteTranslationSegments(for paperID: UUID, in modelContext: ModelContext) throws {
        let descriptor = FetchDescriptor<TranslationSegment>(
            predicate: #Predicate<TranslationSegment> { $0.paperID == paperID }
        )
        try modelContext.fetch(descriptor).forEach(modelContext.delete)
    }

    private static func deleteTranslationJobs(for paperID: UUID, in modelContext: ModelContext) throws {
        let descriptor = FetchDescriptor<TranslationJob>(
            predicate: #Predicate<TranslationJob> { $0.paperID == paperID }
        )
        try modelContext.fetch(descriptor).forEach(modelContext.delete)
    }

    private static func deleteFolderMemberships(for paperID: UUID, in modelContext: ModelContext) throws {
        let descriptor = FetchDescriptor<PaperFolderMembership>(
            predicate: #Predicate<PaperFolderMembership> { $0.paperID == paperID }
        )
        try modelContext.fetch(descriptor).forEach(modelContext.delete)
    }

    private static func deleteItemTypeAssignments(for paperID: UUID, in modelContext: ModelContext) throws {
        let descriptor = FetchDescriptor<PaperItemTypeAssignment>(
            predicate: #Predicate<PaperItemTypeAssignment> { $0.paperID == paperID }
        )
        try modelContext.fetch(descriptor).forEach(modelContext.delete)
    }
}
