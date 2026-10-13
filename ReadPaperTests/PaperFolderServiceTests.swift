import SwiftData
import XCTest
@testable import ReadPaper

final class PaperFolderServiceTests: XCTestCase {
    private var originalLanguageOverride: String?

    override func setUp() {
        super.setUp()
        originalLanguageOverride = AppLocalization.currentLanguageOverride()
        AppLocalization.setLanguageOverride("en")
    }

    override func tearDown() {
        AppLocalization.setLanguageOverride(originalLanguageOverride)
        super.tearDown()
    }

    @MainActor
    func testCreateFolderTrimsNameAndNamesUntitledFoldersLikeFinder() throws {
        let modelContext = ModelContext(try makeContainer())
        let service = PaperFolderService()

        let named = try service.createFolder(named: "  Diffusion \n", modelContext: modelContext)
        let first = try service.createFolder(named: "", modelContext: modelContext)
        let second = try service.createFolder(named: "   ", modelContext: modelContext)

        XCTAssertEqual(named.name, "Diffusion")
        XCTAssertEqual(first.name, "New Folder")
        XCTAssertEqual(second.name, "New Folder 2")
        XCTAssertEqual(try modelContext.fetch(FetchDescriptor<PaperFolder>()).count, 3)
    }

    @MainActor
    func testCreateFolderContainingPaperMovesThatPaper() throws {
        let modelContext = ModelContext(try makeContainer())
        let paper = Paper(title: "Paper")
        modelContext.insert(paper)
        try modelContext.save()

        let folder = try PaperFolderService().createFolder(
            named: "Reading",
            containing: paper.id,
            modelContext: modelContext
        )

        XCTAssertEqual(try folderIDs(of: paper.id, in: modelContext), [folder.id])
    }

    @MainActor
    func testMoveKeepsOneFolderPerPaperAndRemovesOnNil() throws {
        let modelContext = ModelContext(try makeContainer())
        let service = PaperFolderService()
        let paper = Paper(title: "Paper")
        modelContext.insert(paper)
        try modelContext.save()
        let first = try service.createFolder(named: "First", modelContext: modelContext)
        let second = try service.createFolder(named: "Second", modelContext: modelContext)

        try service.move(paperID: paper.id, to: first.id, modelContext: modelContext)
        try service.move(paperID: paper.id, to: second.id, modelContext: modelContext)
        XCTAssertEqual(try folderIDs(of: paper.id, in: modelContext), [second.id])

        try service.move(paperID: paper.id, to: nil, modelContext: modelContext)
        XCTAssertEqual(try folderIDs(of: paper.id, in: modelContext), [])
    }

    @MainActor
    func testMoveDoesNotChangePaperModificationDate() throws {
        let modelContext = ModelContext(try makeContainer())
        let modifiedAt = Date(timeIntervalSince1970: 1_000)
        let paper = Paper(title: "Paper", modifiedAt: modifiedAt)
        modelContext.insert(paper)
        try modelContext.save()
        let folder = try PaperFolderService().createFolder(named: "Folder", modelContext: modelContext)

        try PaperFolderService().move(paperID: paper.id, to: folder.id, modelContext: modelContext)

        XCTAssertEqual(paper.modifiedAt, modifiedAt)
    }

    @MainActor
    func testRenameTrimsAndIgnoresEmptyNames() throws {
        let modelContext = ModelContext(try makeContainer())
        let service = PaperFolderService()
        let folder = try service.createFolder(named: "Old", modelContext: modelContext)

        try service.rename(folder, to: "  ", modelContext: modelContext)
        XCTAssertEqual(folder.name, "Old")

        try service.rename(folder, to: " New ", modelContext: modelContext)
        XCTAssertEqual(folder.name, "New")
    }

    @MainActor
    func testDeleteFolderLeavesItsPapersInTheLibraryUnfiled() throws {
        let modelContext = ModelContext(try makeContainer())
        let service = PaperFolderService()
        let filed = Paper(title: "Filed")
        let elsewhere = Paper(title: "Elsewhere")
        modelContext.insert(filed)
        modelContext.insert(elsewhere)
        try modelContext.save()
        let doomed = try service.createFolder(named: "Doomed", containing: filed.id, modelContext: modelContext)
        let kept = try service.createFolder(named: "Kept", containing: elsewhere.id, modelContext: modelContext)

        try service.delete(doomed, modelContext: modelContext)

        XCTAssertEqual(try modelContext.fetch(FetchDescriptor<PaperFolder>()).map(\.id), [kept.id])
        XCTAssertEqual(Set(try modelContext.fetch(FetchDescriptor<Paper>()).map(\.id)), [filed.id, elsewhere.id])
        XCTAssertEqual(try folderIDs(of: filed.id, in: modelContext), [])
        XCTAssertEqual(try folderIDs(of: elsewhere.id, in: modelContext), [kept.id])
    }

    @MainActor
    func testDeletingPaperRemovesItsMembership() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileStore = PaperFileStore(applicationSupportDirectory: root)
        let modelContext = ModelContext(try makeContainer())
        let paper = Paper(title: "Paper")
        paper.localDirectoryPath = try fileStore.directory(for: paper.id).path
        modelContext.insert(paper)
        try modelContext.save()
        let folder = try PaperFolderService().createFolder(named: "Folder", containing: paper.id, modelContext: modelContext)

        try PaperDeletionService(fileStore: fileStore).delete(paper, modelContext: modelContext)

        XCTAssertTrue(try modelContext.fetch(FetchDescriptor<PaperFolderMembership>()).isEmpty)
        XCTAssertEqual(try modelContext.fetch(FetchDescriptor<PaperFolder>()).map(\.id), [folder.id])
    }

    @MainActor
    func testGroupingSortsFoldersByNameAndKeepsLibraryOrderInside() {
        let newest = Paper(title: "Newest")
        let middle = Paper(title: "Middle")
        let oldest = Paper(title: "Oldest")
        let orphaned = Paper(title: "Orphaned")
        let folder10 = PaperFolder(name: "Folder 10")
        let folder2 = PaperFolder(name: "folder 2")
        let empty = PaperFolder(name: "Empty")

        let grouping = PaperLibraryGrouping(
            papers: [newest, middle, oldest, orphaned],
            folders: [folder10, folder2, empty],
            memberships: [
                PaperFolderMembership(paperID: oldest.id, folderID: folder2.id),
                PaperFolderMembership(paperID: newest.id, folderID: folder2.id),
                PaperFolderMembership(paperID: orphaned.id, folderID: UUID())
            ]
        )

        XCTAssertEqual(grouping.folderSections.map(\.folder.name), ["Empty", "folder 2", "Folder 10"])
        XCTAssertEqual(grouping.folderSections.map { $0.papers.map(\.title) }, [[], ["Newest", "Oldest"], []])
        XCTAssertEqual(grouping.unfiledPapers.map(\.title), ["Middle", "Orphaned"])
        XCTAssertEqual(grouping.orderedPaperIDs, [newest.id, oldest.id, middle.id, orphaned.id])
        XCTAssertEqual(grouping.folderID(containing: newest.id), folder2.id)
        XCTAssertNil(grouping.folderID(containing: orphaned.id))
    }

    func testCollapsedFolderStorageRoundTrips() {
        let ids: Set<UUID> = [UUID(), UUID()]

        XCTAssertEqual(LibraryFolderExpansion.decode(LibraryFolderExpansion.encode(ids)), ids)
        XCTAssertEqual(LibraryFolderExpansion.decode("not-a-uuid\n"), [])
    }

    /// A store written before folders existed must open with folders, and a
    /// store with folders must still open with the older schema (downgrade).
    @MainActor
    func testStoreOpensAcrossFolderSchemaInBothDirections() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = try ReadPaperModelStore.storeURL(applicationSupportDirectory: root)
        let paperID = UUID()

        do {
            let container = try makeDiskContainer(schema: preFolderSchema, url: storeURL)
            let context = ModelContext(container)
            context.insert(Paper(id: paperID, title: "Existing"))
            try context.save()
        }

        do {
            let container = try ReadPaperModelStore.makeModelContainer(applicationSupportDirectory: root)
            let context = ModelContext(container)
            XCTAssertEqual(try context.fetch(FetchDescriptor<Paper>()).map(\.id), [paperID])
            try PaperFolderService().createFolder(named: "Folder", containing: paperID, modelContext: context)
        }

        do {
            let container = try makeDiskContainer(schema: preFolderSchema, url: storeURL)
            let context = ModelContext(container)
            XCTAssertEqual(try context.fetch(FetchDescriptor<Paper>()).map(\.id), [paperID])
        }
    }

    private var preFolderSchema: Schema {
        Schema([
            Paper.self,
            PaperAttachment.self,
            ReadingState.self,
            Note.self,
            TranslationSegment.self,
            TranslationJob.self,
            ToolInstallState.self,
            LLMProviderProfile.self,
            LLMModelProfile.self,
            AppSettings.self
        ])
    }

    @MainActor
    private func makeDiskContainer(schema: Schema, url: URL) throws -> ModelContainer {
        let configuration = ModelConfiguration(schema: schema, url: url, allowsSave: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    @MainActor
    private func makeContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: ReadPaperModelStore.schema, configurations: [configuration])
    }

    @MainActor
    private func folderIDs(of paperID: UUID, in modelContext: ModelContext) throws -> [UUID] {
        let descriptor = FetchDescriptor<PaperFolderMembership>(
            predicate: #Predicate<PaperFolderMembership> { $0.paperID == paperID }
        )
        return try modelContext.fetch(descriptor).map(\.folderID)
    }
}
