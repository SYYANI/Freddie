import SwiftData
import XCTest
#if os(iOS)
@testable import ReadPaperiPad
#else
@testable import ReadPaper
#endif

final class PaperItemTypeTests: XCTestCase {
    func testDetectionFollowsImportSource() {
        let arxiv = Paper(arxivID: "2303.08774", title: "arXiv")
        let webPage = Paper(title: "Web page", htmlURLString: "https://example.com/post")
        let webPDF = Paper(title: "Web PDF", htmlURLString: "https://example.com/paper.pdf")
        let doiPDF = Paper(doi: "10.1000/xyz", title: "DOI PDF")
        let attachments = [
            PaperAttachment(paperID: arxiv.id, kind: .html, source: .arxivHTML, filename: "paper.html", filePath: "paper.html"),
            PaperAttachment(paperID: webPage.id, kind: .html, source: .webPage, filename: "paper.html", filePath: "paper.html"),
            PaperAttachment(paperID: webPDF.id, kind: .pdf, source: .webPage, filename: "paper.pdf", filePath: "paper.pdf"),
            PaperAttachment(paperID: doiPDF.id, kind: .pdf, source: .localImport, filename: "paper.pdf", filePath: "paper.pdf"),
        ]

        let resolution = PaperItemTypeResolution(
            papers: [arxiv, webPage, webPDF, doiPDF],
            attachments: attachments,
            assignments: []
        )

        XCTAssertEqual(resolution.itemType(of: arxiv.id), .preprint)
        XCTAssertEqual(resolution.itemType(of: webPage.id), .webpage)
        XCTAssertEqual(resolution.itemType(of: webPDF.id), .document)
        XCTAssertEqual(resolution.itemType(of: doiPDF.id), .document)
        XCTAssertFalse(resolution.isAssigned(arxiv.id))
    }

    func testAssignmentOverridesDetectionAndUnknownRawValueFallsBack() {
        let published = Paper(arxivID: "1706.03762", title: "Published")
        let future = Paper(arxivID: "2401.00001", title: "Future type")
        let unknown = PaperItemTypeAssignment(paperID: future.id, itemType: .book)
        unknown.itemTypeRawValue = "someFutureType"

        let resolution = PaperItemTypeResolution(
            papers: [published, future],
            attachments: [],
            assignments: [
                PaperItemTypeAssignment(paperID: published.id, itemType: .conferencePaper),
                unknown,
            ]
        )

        XCTAssertEqual(resolution.itemType(of: published.id), .conferencePaper)
        XCTAssertEqual(resolution.detectedType(of: published.id), .preprint)
        XCTAssertTrue(resolution.isAssigned(published.id))
        XCTAssertEqual(resolution.itemType(of: future.id), .preprint)
        XCTAssertEqual(resolution.counts(in: [published, future]), [.conferencePaper: 1, .preprint: 1])
    }

    @MainActor
    func testSettingDetectedTypeOrNilRemovesTheAssignment() throws {
        let modelContext = ModelContext(try makeContainer())
        let service = PaperItemTypeService()
        let paper = Paper(arxivID: "1706.03762", title: "Paper")
        let modifiedAt = paper.modifiedAt
        modelContext.insert(paper)
        try modelContext.save()

        try service.setItemType(.conferencePaper, for: paper.id, detectedType: .preprint, modelContext: modelContext)
        try service.setItemType(.journalArticle, for: paper.id, detectedType: .preprint, modelContext: modelContext)
        XCTAssertEqual(try assignedRawValues(in: modelContext), ["journalArticle"])

        try service.setItemType(.preprint, for: paper.id, detectedType: .preprint, modelContext: modelContext)
        XCTAssertEqual(try assignedRawValues(in: modelContext), [])

        try service.setItemType(.thesis, for: paper.id, detectedType: .preprint, modelContext: modelContext)
        try service.setItemType(nil, for: paper.id, detectedType: .preprint, modelContext: modelContext)
        XCTAssertEqual(try assignedRawValues(in: modelContext), [])
        XCTAssertEqual(paper.modifiedAt, modifiedAt)
    }

    func testFilterMatchesAnySelectedTypeAndAllCriteria() {
        let preprint = Paper(arxivID: "2303.08774", title: "Preprint", isFavorite: true)
        let article = Paper(title: "Article")
        let document = Paper(title: "Document", isFavorite: true)
        let resolution = PaperItemTypeResolution(
            papers: [preprint, article, document],
            attachments: [],
            assignments: [PaperItemTypeAssignment(paperID: article.id, itemType: .journalArticle)]
        )
        let facts = PaperLibraryFilter.Facts(itemTypes: resolution)
        var filter = PaperLibraryFilter(itemTypes: [.preprint, .journalArticle])

        XCTAssertTrue(filter.isActive)
        XCTAssertEqual([preprint, article, document].filter { filter.matches($0, facts: facts) }.map(\.title), ["Preprint", "Article"])

        filter.criteria = [.favorites]

        XCTAssertEqual([preprint, article, document].filter { filter.matches($0, facts: facts) }.map(\.title), ["Preprint"])
    }

    func testZoteroIdentifiersAndTitlesAreComplete() {
        XCTAssertEqual(PaperItemType.allCases.count, 37)
        XCTAssertEqual(PaperItemType.case.rawValue, "case")
        XCTAssertEqual(PaperItemType.computerProgram.rawValue, "computerProgram")
        XCTAssertTrue(Set(PaperItemType.common).isSubset(of: Set(PaperItemType.allCases)))

        let bundle = AppLocalization.currentBundle()
        let titles = PaperItemType.allCases.map { $0.title(bundle: bundle) }
        XCTAssertEqual(Set(titles).count, titles.count)
    }

    func testSelectionDescribesTheInspectorPicker() {
        let paper = Paper(arxivID: "1706.03762", title: "Paper")
        let assigned = PaperItemTypeResolution(
            papers: [paper],
            attachments: [],
            assignments: [PaperItemTypeAssignment(paperID: paper.id, itemType: .conferencePaper)]
        )
        let detected = PaperItemTypeResolution(papers: [paper], attachments: [], assignments: [])

        XCTAssertEqual(
            assigned.selection(for: paper.id),
            PaperItemTypeSelection(itemType: .conferencePaper, detectedType: .preprint, isAssigned: true)
        )
        XCTAssertEqual(
            detected.selection(for: paper.id),
            PaperItemTypeSelection(itemType: .preprint, detectedType: .preprint, isAssigned: false)
        )
    }

    func testSortedByTitleKeepsEveryTypeInLocalizedOrder() {
        let bundle = AppLocalization.currentBundle()

        let sorted = PaperItemType.sortedByTitle(PaperItemType.allCases, bundle: bundle)

        XCTAssertEqual(Set(sorted.map(\.itemType)), Set(PaperItemType.allCases))
        XCTAssertEqual(sorted.map(\.title), sorted.map { $0.itemType.title(bundle: bundle) })
        XCTAssertEqual(
            sorted.map(\.title),
            sorted.map(\.title).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        )
    }

    /// A store written before item types existed must open with them, and a
    /// store with item types must still open with the older schema (downgrade).
    @MainActor
    func testStoreOpensAcrossItemTypeSchemaInBothDirections() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = try ReadPaperModelStore.storeURL(applicationSupportDirectory: root)
        let paperID = UUID()

        do {
            let container = try makeDiskContainer(schema: preItemTypeSchema, url: storeURL)
            let context = ModelContext(container)
            context.insert(Paper(id: paperID, title: "Existing"))
            try context.save()
        }

        do {
            let container = try ReadPaperModelStore.makeModelContainer(applicationSupportDirectory: root)
            let context = ModelContext(container)
            XCTAssertEqual(try context.fetch(FetchDescriptor<Paper>()).map(\.id), [paperID])
            try PaperItemTypeService().setItemType(.thesis, for: paperID, detectedType: .document, modelContext: context)
        }

        do {
            let container = try makeDiskContainer(schema: preItemTypeSchema, url: storeURL)
            let context = ModelContext(container)
            XCTAssertEqual(try context.fetch(FetchDescriptor<Paper>()).map(\.id), [paperID])
        }
    }

    private var preItemTypeSchema: Schema {
        Schema([
            Paper.self,
            PaperAttachment.self,
            PaperFolder.self,
            PaperFolderMembership.self,
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
    private func assignedRawValues(in modelContext: ModelContext) throws -> [String] {
        try modelContext.fetch(FetchDescriptor<PaperItemTypeAssignment>()).map(\.itemTypeRawValue)
    }

    @MainActor
    private func makeDiskContainer(schema: Schema, url: URL) throws -> ModelContainer {
        let configuration = ModelConfiguration(schema: schema, url: url, allowsSave: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private func makeContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: ReadPaperModelStore.schema, configurations: [configuration])
    }
}
