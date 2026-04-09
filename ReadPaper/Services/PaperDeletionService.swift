import Foundation
import SwiftData

@MainActor
struct PaperDeletionService {
    let fileStore: PaperFileStore

    init(fileStore: PaperFileStore = PaperFileStore()) {
        self.fileStore = fileStore
    }

    func delete(_ paper: Paper, modelContext: ModelContext) throws {
        let paperID = paper.id

        do {
            try deleteAttachments(for: paperID, in: modelContext)
            try deleteNotes(for: paperID, in: modelContext)
            try deleteReadingStates(for: paperID, in: modelContext)
            try deleteTranslationSegments(for: paperID, in: modelContext)
            try deleteTranslationJobs(for: paperID, in: modelContext)

            modelContext.delete(paper)
            try fileStore.removeDirectory(for: paperID)
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private func deleteAttachments(for paperID: UUID, in modelContext: ModelContext) throws {
        let descriptor = FetchDescriptor<PaperAttachment>(
            predicate: #Predicate<PaperAttachment> { $0.paperID == paperID }
        )
        try modelContext.fetch(descriptor).forEach(modelContext.delete)
    }

    private func deleteNotes(for paperID: UUID, in modelContext: ModelContext) throws {
        let descriptor = FetchDescriptor<Note>(
            predicate: #Predicate<Note> { $0.paperID == paperID }
        )
        try modelContext.fetch(descriptor).forEach(modelContext.delete)
    }

    private func deleteReadingStates(for paperID: UUID, in modelContext: ModelContext) throws {
        let descriptor = FetchDescriptor<ReadingState>(
            predicate: #Predicate<ReadingState> { $0.paperID == paperID }
        )
        try modelContext.fetch(descriptor).forEach(modelContext.delete)
    }

    private func deleteTranslationSegments(for paperID: UUID, in modelContext: ModelContext) throws {
        let descriptor = FetchDescriptor<TranslationSegment>(
            predicate: #Predicate<TranslationSegment> { $0.paperID == paperID }
        )
        try modelContext.fetch(descriptor).forEach(modelContext.delete)
    }

    private func deleteTranslationJobs(for paperID: UUID, in modelContext: ModelContext) throws {
        let descriptor = FetchDescriptor<TranslationJob>(
            predicate: #Predicate<TranslationJob> { $0.paperID == paperID }
        )
        try modelContext.fetch(descriptor).forEach(modelContext.delete)
    }
}
