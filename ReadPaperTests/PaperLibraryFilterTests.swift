import SwiftData
import XCTest
#if os(iOS)
@testable import ReadPaperiPad
#else
@testable import ReadPaper
#endif

final class PaperLibraryFilterTests: XCTestCase {
    func testInactiveFilterMatchesEveryPaper() {
        let filter = PaperLibraryFilter()

        XCTAssertFalse(filter.isActive)
        XCTAssertTrue(filter.matches(Paper(title: "Plain"), facts: .init()))
    }

    func testSelectedCriteriaMustAllMatch() {
        let favorite = Paper(title: "Favorite", isFavorite: true)
        let favoriteWithNotes = Paper(title: "Favorite with notes", isFavorite: true)
        let notesOnly = Paper(title: "Notes only")
        let facts = PaperLibraryFilter.Facts(notedPaperIDs: [favoriteWithNotes.id, notesOnly.id])
        var filter = PaperLibraryFilter(criteria: [.favorites])

        XCTAssertTrue(filter.matches(favorite, facts: facts))
        XCTAssertTrue(filter.matches(favoriteWithNotes, facts: facts))
        XCTAssertFalse(filter.matches(notesOnly, facts: facts))

        filter.criteria.insert(.notes)

        XCTAssertFalse(filter.matches(favorite, facts: facts))
        XCTAssertTrue(filter.matches(favoriteWithNotes, facts: facts))
        XCTAssertFalse(filter.matches(notesOnly, facts: facts))
    }

    func testTranslatedPapersIncludeTranslatedPDFsAndHTMLTranslations() {
        let pdfTranslated = UUID()
        let htmlTranslated = UUID()
        let untranslated = UUID()
        let attachments = [
            PaperAttachment(paperID: pdfTranslated, kind: .translatedPDF, source: .babeldoc, filename: "t.pdf", filePath: "t.pdf"),
            PaperAttachment(paperID: untranslated, kind: .pdf, source: .localImport, filename: "paper.pdf", filePath: "paper.pdf"),
            PaperAttachment(paperID: untranslated, kind: .html, source: .webPage, filename: "paper.html", filePath: "paper.html"),
        ]

        let translated = PaperLibraryFilter.translatedPaperIDs(
            attachments: attachments,
            htmlTranslatedPaperIDs: [htmlTranslated]
        )

        XCTAssertEqual(translated, [pdfTranslated, htmlTranslated])
    }

    @MainActor
    func testHTMLTranslatedPaperIDsIgnoreAbstractTranslations() throws {
        let modelContext = ModelContext(try makeContainer())
        let htmlPaperID = UUID()
        let abstractPaperID = UUID()
        modelContext.insert(segment(paperID: htmlPaperID, sourceType: "html"))
        modelContext.insert(segment(paperID: htmlPaperID, sourceType: "html"))
        modelContext.insert(segment(paperID: abstractPaperID, sourceType: "abstract"))
        try modelContext.save()

        XCTAssertEqual(
            try PaperLibraryFilter.htmlTranslatedPaperIDs(modelContext: modelContext),
            [htmlPaperID]
        )
    }

    func testFilteredGroupingKeepsEveryFolderAndLibraryOrder() {
        let first = Paper(title: "First")
        let second = Paper(title: "Second")
        let third = Paper(title: "Third")
        let unfiled = Paper(title: "Unfiled")
        let reading = PaperFolder(name: "Reading")
        let archive = PaperFolder(name: "Archive")
        let grouping = PaperLibraryGrouping(
            papers: [first, second, third, unfiled],
            folders: [reading, archive],
            memberships: [
                PaperFolderMembership(paperID: first.id, folderID: reading.id),
                PaperFolderMembership(paperID: second.id, folderID: archive.id),
                PaperFolderMembership(paperID: third.id, folderID: reading.id),
            ]
        )
        let visibleIDs: Set<UUID> = [first.id, third.id]

        let filtered = grouping.filtered { visibleIDs.contains($0.id) }

        XCTAssertEqual(filtered.folderSections.map(\.folder.name), ["Archive", "Reading"])
        XCTAssertEqual(filtered.folderSections.map { $0.papers.map(\.title) }, [[], ["First", "Third"]])
        XCTAssertTrue(filtered.unfiledPapers.isEmpty)
        XCTAssertEqual(filtered.orderedPaperIDs, [first.id, third.id])
        XCTAssertEqual(filtered.folderID(containing: second.id), archive.id)
    }

    private func segment(paperID: UUID, sourceType: String) -> TranslationSegment {
        TranslationSegment(
            paperID: paperID,
            sourceType: sourceType,
            targetLanguage: "zh-Hans",
            sourceHash: UUID().uuidString,
            sourceText: "Source",
            translatedText: "译文",
            modelName: "model"
        )
    }

    private func makeContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: ReadPaperModelStore.schema, configurations: [configuration])
    }
}
