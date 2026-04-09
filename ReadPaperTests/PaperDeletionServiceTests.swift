import SwiftData
import XCTest
@testable import ReadPaper

final class PaperDeletionServiceTests: XCTestCase {
    @MainActor
    func testDeleteRemovesPaperRelatedModelsAndFilesOnly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fileStore = PaperFileStore(applicationSupportDirectory: root)
        let service = PaperDeletionService(fileStore: fileStore)
        let container = try makeContainer()
        let modelContext = ModelContext(container)

        let targetPaper = Paper(title: "Target Paper")
        targetPaper.localDirectoryPath = try fileStore.directory(for: targetPaper.id).path
        _ = try fileStore.write(Data("paper".utf8), named: "paper.pdf", for: targetPaper.id)

        let otherPaper = Paper(title: "Other Paper")
        otherPaper.localDirectoryPath = try fileStore.directory(for: otherPaper.id).path

        modelContext.insert(targetPaper)
        modelContext.insert(otherPaper)
        modelContext.insert(PaperAttachment(
            paperID: targetPaper.id,
            kind: .pdf,
            source: .localImport,
            filename: "paper.pdf",
            filePath: URL(fileURLWithPath: targetPaper.localDirectoryPath).appendingPathComponent("paper.pdf").path
        ))
        modelContext.insert(PaperAttachment(
            paperID: otherPaper.id,
            kind: .pdf,
            source: .localImport,
            filename: "paper.pdf",
            filePath: URL(fileURLWithPath: otherPaper.localDirectoryPath).appendingPathComponent("paper.pdf").path
        ))
        modelContext.insert(Note(paperID: targetPaper.id, body: "Target note"))
        modelContext.insert(Note(paperID: otherPaper.id, body: "Other note"))
        modelContext.insert(ReadingState(paperID: targetPaper.id))
        modelContext.insert(ReadingState(paperID: otherPaper.id))
        modelContext.insert(TranslationSegment(
            paperID: targetPaper.id,
            sourceType: "html",
            targetLanguage: "zh-CN",
            sourceHash: "hash-1",
            sourceText: "source",
            translatedText: "translated",
            modelName: "model"
        ))
        modelContext.insert(TranslationSegment(
            paperID: otherPaper.id,
            sourceType: "html",
            targetLanguage: "zh-CN",
            sourceHash: "hash-2",
            sourceText: "source",
            translatedText: "translated",
            modelName: "model"
        ))
        modelContext.insert(TranslationJob(paperID: targetPaper.id, kind: "html"))
        modelContext.insert(TranslationJob(paperID: otherPaper.id, kind: "html"))
        try modelContext.save()

        XCTAssertTrue(FileManager.default.fileExists(atPath: targetPaper.localDirectoryPath))

        try service.delete(targetPaper, modelContext: modelContext)

        XCTAssertFalse(FileManager.default.fileExists(atPath: targetPaper.localDirectoryPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: otherPaper.localDirectoryPath))
        XCTAssertEqual(try modelContext.fetch(FetchDescriptor<Paper>()).map(\.id), [otherPaper.id])
        XCTAssertEqual(try relatedAttachmentPaperIDs(in: modelContext), [otherPaper.id])
        XCTAssertEqual(try relatedNotePaperIDs(in: modelContext), [otherPaper.id])
        XCTAssertEqual(try relatedReadingStatePaperIDs(in: modelContext), [otherPaper.id])
        XCTAssertEqual(try relatedSegmentPaperIDs(in: modelContext), [otherPaper.id])
        XCTAssertEqual(try relatedJobPaperIDs(in: modelContext), [otherPaper.id])
    }

    @MainActor
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            Paper.self,
            PaperAttachment.self,
            ReadingState.self,
            Note.self,
            TranslationSegment.self,
            TranslationJob.self
        ])
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    @MainActor
    private func relatedAttachmentPaperIDs(in modelContext: ModelContext) throws -> [UUID] {
        try modelContext.fetch(FetchDescriptor<PaperAttachment>()).map(\.paperID)
    }

    @MainActor
    private func relatedNotePaperIDs(in modelContext: ModelContext) throws -> [UUID] {
        try modelContext.fetch(FetchDescriptor<Note>()).map(\.paperID)
    }

    @MainActor
    private func relatedReadingStatePaperIDs(in modelContext: ModelContext) throws -> [UUID] {
        try modelContext.fetch(FetchDescriptor<ReadingState>()).map(\.paperID)
    }

    @MainActor
    private func relatedSegmentPaperIDs(in modelContext: ModelContext) throws -> [UUID] {
        try modelContext.fetch(FetchDescriptor<TranslationSegment>()).map(\.paperID)
    }

    @MainActor
    private func relatedJobPaperIDs(in modelContext: ModelContext) throws -> [UUID] {
        try modelContext.fetch(FetchDescriptor<TranslationJob>()).map(\.paperID)
    }
}
