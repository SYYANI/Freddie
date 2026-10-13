import XCTest
@testable import ReadPaper

final class WritingStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeStore() -> WritingStore {
        WritingStore(
            fileStore: PaperFileStore(applicationSupportDirectory: root),
            movesDeletedWritingsToTrash: false
        )
    }

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "WritingStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }

    // MARK: - Store

    func testSaveWritesMarkdownAndDerivedMetadata() throws {
        let store = makeStore()
        let paperID = UUID()
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let markdown = "# Literature *Review*\n\nTransformers [Vaswani 2017](readpaper://paper/\(paperID.uuidString)?p=2) 很强。\n"

        let metadata = try store.save(markdown: markdown, for: UUID(), createdAt: created, now: created.addingTimeInterval(60))

        XCTAssertEqual(metadata.title, "Literature Review")
        XCTAssertEqual(metadata.citedPaperIDs, [paperID])
        XCTAssertEqual(metadata.wordCount, 7)
        XCTAssertEqual(try store.loadMarkdown(for: metadata.id), markdown)
        let directory = try store.directory(for: metadata.id)
        XCTAssertEqual(directory.deletingLastPathComponent().lastPathComponent, WritingStore.directoryName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(WritingStore.metadataFilename).path))
    }

    func testLoadAllSortsByModificationAndSkipsStrayFolders() throws {
        let store = makeStore()
        // Created out of order; the file dates match the metadata, so it is trusted as is.
        let newer = try store.create(markdown: "Newer", now: Date(timeIntervalSince1970: 2_000))
        let older = try store.create(markdown: "Older", now: Date(timeIntervalSince1970: 1_000))
        for writing in [newer, older] {
            try FileManager.default.setAttributes(
                [.modificationDate: writing.modifiedAt],
                ofItemAtPath: store.markdownURL(for: writing.id).path
            )
        }
        try FileManager.default.createDirectory(
            at: store.writingsDirectory.appendingPathComponent("not-a-writing", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: store.writingsDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true),
            withIntermediateDirectories: true
        )

        XCTAssertEqual(try store.loadAll().map(\.id), [newer.id, older.id])
    }

    func testMissingOrStaleMetadataIsRebuiltFromTheMarkdown() throws {
        let store = makeStore()
        let created = Date(timeIntervalSince1970: 1_000)
        let writing = try store.create(markdown: "First title", now: created)
        let directory = try store.directory(for: writing.id)

        // Edited outside the app: the Markdown is newer than its metadata.
        try "# Edited elsewhere\n".write(
            to: directory.appendingPathComponent(WritingStore.markdownFilename),
            atomically: true,
            encoding: .utf8
        )
        let rebuilt = try XCTUnwrap(store.loadAll().first)
        XCTAssertEqual(rebuilt.title, "Edited elsewhere")
        XCTAssertEqual(rebuilt.createdAt, created)

        // Metadata lost entirely, e.g. a partial copy.
        try FileManager.default.removeItem(at: directory.appendingPathComponent(WritingStore.metadataFilename))
        XCTAssertEqual(try store.loadAll().first?.title, "Edited elsewhere")
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(WritingStore.metadataFilename).path))
    }

    func testMetadataFromANewerVersionIsNotOverwritten() throws {
        let store = makeStore()
        let writing = try store.create(markdown: "Text", now: Date(timeIntervalSince1970: 1_000))
        let metadataURL = try store.directory(for: writing.id).appendingPathComponent(WritingStore.metadataFilename)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as? [String: Any])
        json["version"] = WritingMetadata.currentVersion + 1
        json["futureField"] = "kept"
        let newerData = try JSONSerialization.data(withJSONObject: json)
        try newerData.write(to: metadataURL)

        XCTAssertEqual(try store.loadAll().first?.title, "Text")
        XCTAssertEqual(try Data(contentsOf: metadataURL), newerData)
    }

    func testDeleteRemovesTheWritingFolder() throws {
        let store = makeStore()
        let writing = try store.create(markdown: "Gone soon")

        try store.delete(writing.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: try store.directory(for: writing.id).path))
        XCTAssertEqual(try store.loadAll(), [])
    }

    // MARK: - Library

    @MainActor
    func testLibraryCreatesSelectsAndRemembersTheCurrentWriting() throws {
        let defaults = try makeDefaults()
        let library = WritingLibrary(store: makeStore(), userDefaults: defaults)
        library.loadIfNeeded()
        XCTAssertNil(library.currentWriting)

        let first = try library.createWriting(markdown: "First")
        let second = try library.createWriting(markdown: "Second")
        XCTAssertEqual(library.currentWritingID, second.id)
        library.selectWriting(first.id)

        let reopened = WritingLibrary(store: makeStore(), userDefaults: defaults)
        reopened.loadIfNeeded()
        XCTAssertEqual(reopened.currentWritingID, first.id)
        XCTAssertEqual(Set(reopened.writings.map(\.id)), [first.id, second.id])
    }

    @MainActor
    func testLibrarySaveMovesTheWritingFirstAndUpdatesBacklinks() throws {
        let library = WritingLibrary(store: makeStore(), userDefaults: try makeDefaults())
        let paperID = UUID()
        let older = try library.createWriting(markdown: "Older")
        let newer = try library.createWriting(markdown: "Newer")
        XCTAssertEqual(library.writings.map(\.id), [newer.id, older.id])

        XCTAssertTrue(library.save(markdown: "Older, now citing [x](readpaper://paper/\(paperID.uuidString))", for: older.id))

        XCTAssertEqual(library.writings.map(\.id), [older.id, newer.id])
        XCTAssertEqual(library.writings(citing: paperID).map(\.id), [older.id])
        XCTAssertNil(library.lastErrorMessage)
    }

    @MainActor
    func testDeletedWritingsAreNotRecreatedByALateSave() throws {
        let store = makeStore()
        let library = WritingLibrary(store: store, userDefaults: try makeDefaults())
        let kept = try library.createWriting(markdown: "Kept")
        let deleted = try library.createWriting(markdown: "Deleted")

        try library.deleteWriting(deleted.id)

        XCTAssertEqual(library.currentWritingID, kept.id)
        XCTAssertFalse(library.save(markdown: "Typed after deletion", for: deleted.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try store.directory(for: deleted.id).path))
    }

    // MARK: - Markdown helpers

    func testTitleSkipsSyntaxBlankLinesAndCode() {
        XCTAssertEqual(WritingTitle.derive(from: "\n\n## A [linked](https://x.y) **title**\nbody"), "A linked title")
        XCTAssertEqual(WritingTitle.derive(from: "```\ncode first\n```\n- Then a list"), "code first")
        XCTAssertEqual(WritingTitle.derive(from: "---\n> Quoted *start*"), "Quoted start")
        XCTAssertEqual(WritingTitle.derive(from: "   \n"), "")
        XCTAssertEqual(WritingTitle.derive(from: String(repeating: "长", count: 100)).count, WritingTitle.maximumLength + 1)
    }

    func testWordCountMixesCJKCharactersAndLatinWords() {
        XCTAssertEqual(WritingStatistics.wordCount(in: "Attention is all you need"), 5)
        XCTAssertEqual(WritingStatistics.wordCount(in: "注意力机制 is key"), 7)
        XCTAssertEqual(WritingStatistics.wordCount(in: "don't count [the link](readpaper://paper/\(UUID().uuidString)?p=2 \"a \\\"long\\\" quote\")"), 4)
    }

    func testBlockInsertionMakesItsOwnParagraph() {
        let block = "> Q\n>\n> — [A](x)"

        XCTAssertEqual(WritingInsertion.block(block, in: "", at: 0).replacement, block + "\n\n")

        let afterParagraph = WritingInsertion.block(block, in: "First line\nsame paragraph\n\nNext", at: 3)
        XCTAssertEqual(afterParagraph.range, NSRange(location: 25, length: 0))
        XCTAssertEqual(afterParagraph.replacement, "\n\n" + block)
        XCTAssertEqual(afterParagraph.selectionAfter.location, 25 + 2 + (block as NSString).length)

        let atEnd = WritingInsertion.block(block, in: "Last", at: 4)
        XCTAssertEqual(atEnd.replacement, "\n\n" + block + "\n\n")

        let onBlankLine = WritingInsertion.block(block, in: "A\n\nB", at: 2)
        XCTAssertEqual(onBlankLine.range.location, 2)
        XCTAssertEqual(onBlankLine.replacement, "\n" + block + "\n")
    }

    func testInlineInsertionAddsASpaceOnlyAfterLatinText() {
        XCTAssertEqual(WritingInsertion.inline("[A](x)", in: "As shown", selection: NSRange(location: 8, length: 0)).replacement, " [A](x)")
        XCTAssertEqual(WritingInsertion.inline("[A](x)", in: "如图", selection: NSRange(location: 2, length: 0)).replacement, "[A](x)")
        let keepsSelection = WritingInsertion.inline("[A](x)", in: "word ", selection: NSRange(location: 0, length: 4))
        XCTAssertEqual(keepsSelection.range, NSRange(location: 4, length: 0))
    }

    func testReturnContinuesOrEndsListsAndQuotes() {
        func newline(_ text: String, at location: Int? = nil) -> WritingEdit? {
            let caret = location ?? (text as NSString).length
            return WritingContinuation.newline(in: text, selection: NSRange(location: caret, length: 0), isInCodeBlock: false)
        }

        XCTAssertEqual(newline("- item")?.replacement, "\n- ")
        XCTAssertEqual(newline("  9. ninth")?.replacement, "\n  10. ")
        XCTAssertEqual(newline("> - quoted item")?.replacement, "\n> - ")
        XCTAssertEqual(newline("> quote")?.replacement, "\n> ")
        XCTAssertNil(newline("plain"))
        XCTAssertNil(newline("- item", at: 1))
        XCTAssertNil(WritingContinuation.newline(in: "- item", selection: NSRange(location: 6, length: 0), isInCodeBlock: true))

        let endList = newline("- a\n- ")
        XCTAssertEqual(endList?.range, NSRange(location: 4, length: 2))
        XCTAssertEqual(endList?.replacement, "\n")
        XCTAssertEqual(endList?.selectionAfter, NSRange(location: 5, length: 0))

        let endQuote = newline("> a\n> ")
        XCTAssertEqual(endQuote?.replacement, "\n")
    }

    func testCitationContextReadsTheQuoteAboveItsCitationLine() throws {
        let paperID = UUID()
        let citation = PaperCitation(paperID: paperID, pageIndex: 0, quotePrefix: "The dominant sequence")
        let markdown = """
        Intro paragraph.

        > Earlier passage
        >
        > The dominant sequence transduction *models*
        > are based on RNNs.
        >
        > — [Vaswani](\(citation.linkDestination))
        """
        let location = (markdown as NSString).range(of: "Vaswani").location

        XCTAssertEqual(
            WritingCitationContext.quote(forCitationAt: location, in: markdown, citation: citation),
            "The dominant sequence transduction models are based on RNNs."
        )

        let edited = markdown.replacingOccurrences(of: "The dominant", with: "A rewritten")
        let editedLocation = (edited as NSString).range(of: "Vaswani").location
        XCTAssertNil(WritingCitationContext.quote(forCitationAt: editedLocation, in: edited, citation: citation))

        let inline = "See [Vaswani](\(citation.linkDestination))."
        XCTAssertNil(WritingCitationContext.quote(forCitationAt: 5, in: inline, citation: citation))
    }
}
