import AppKit
import XCTest
@testable import ReadPaper

@MainActor
final class WritingEditorTests: XCTestCase {
    private let typography = WritingTypography(usesPaperAppearance: false)
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeLibrary() throws -> WritingLibrary {
        let suiteName = "WritingEditorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }
        let store = WritingStore(
            fileStore: PaperFileStore(applicationSupportDirectory: root),
            movesDeletedWritingsToTrash: false
        )
        return WritingLibrary(store: store, userDefaults: defaults)
    }

    private func makeLayout(for storage: NSTextStorage) -> WritingLayoutManager {
        let layoutManager = WritingLayoutManager(typography: typography)
        let container = NSTextContainer(size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: container)
        return layoutManager
    }

    private func glyphProperty(at characterIndex: Int, in layoutManager: NSLayoutManager) -> NSLayoutManager.GlyphProperty {
        layoutManager.ensureGlyphs(forCharacterRange: NSRange(location: 0, length: layoutManager.textStorage?.length ?? 0))
        return layoutManager.propertyForGlyph(at: layoutManager.glyphIndexForCharacter(at: characterIndex))
    }

    private func font(at location: Int, in storage: NSTextStorage) -> NSFont? {
        storage.attribute(.font, at: location, effectiveRange: nil) as? NSFont
    }

    // MARK: - Styling

    func testStorageStylesEachKindOfLine() throws {
        let markdown = "# Title\n\nSome **bold** text\n> quote\n```\ncode **x**\n```\n- item"
        let storage = WritingTextStorage(markdown: markdown, typography: typography)
        let text = markdown as NSString

        XCTAssertGreaterThan(try XCTUnwrap(font(at: 2, in: storage)).pointSize, typography.bodyFont.pointSize)
        XCTAssertNotNil(storage.attribute(.writingMarker, at: 0, effectiveRange: nil))
        let bold = text.range(of: "bold").location
        XCTAssertTrue(try XCTUnwrap(font(at: bold, in: storage)).fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertNotNil(storage.attribute(.writingMarker, at: bold - 1, effectiveRange: nil))
        XCTAssertEqual(storage.attribute(.writingQuoteDepth, at: text.range(of: "quote").location, effectiveRange: nil) as? Int, 1)
        let code = text.range(of: "code").location
        XCTAssertNotNil(storage.attribute(.writingCodeBlock, at: code, effectiveRange: nil))
        XCTAssertNil(storage.attribute(.writingMarker, at: code + 5, effectiveRange: nil))
        XCTAssertNotNil(storage.attribute(.writingBullet, at: text.range(of: "- item").location, effectiveRange: nil))
    }

    /// Fonts are fixed for edits when the storage processes them; text loaded from disk
    /// needs the same fallback fonts or CJK characters do not render at all.
    func testInitialCJKTextGetsAFontThatCanDrawIt() throws {
        for usesPaperAppearance in [false, true] {
            let storage = WritingTextStorage(
                markdown: "# 标题\n\n正文**加粗**",
                typography: WritingTypography(usesPaperAppearance: usesPaperAppearance)
            )
            for location in [2, 5, 9] {
                let font = try XCTUnwrap(self.font(at: location, in: storage))
                var character = (storage.string as NSString).character(at: location)
                var glyph: CGGlyph = 0
                XCTAssertTrue(
                    CTFontGetGlyphsForCharacters(font as CTFont, &character, &glyph, 1),
                    "\(font.fontName) cannot draw the character at \(location)"
                )
            }
        }
    }

    func testTypingAnOpeningFenceRestylesTheLinesBelowIt() {
        let storage = WritingTextStorage(markdown: "**a**\n**b**\n", typography: typography)
        _ = makeLayout(for: storage)
        XCTAssertNil(storage.attribute(.writingCodeBlock, at: 6, effectiveRange: nil))

        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "```\n")
        XCTAssertNotNil(storage.attribute(.writingCodeBlock, at: 4, effectiveRange: nil))
        XCTAssertNotNil(storage.attribute(.writingCodeBlock, at: 10, effectiveRange: nil))
        XCTAssertNil(storage.attribute(.writingMarker, at: 10, effectiveRange: nil))

        storage.replaceCharacters(in: NSRange(location: 0, length: 4), with: "")
        XCTAssertNil(storage.attribute(.writingCodeBlock, at: 6, effectiveRange: nil))
        XCTAssertNotNil(storage.attribute(.writingMarker, at: 6, effectiveRange: nil))
    }

    func testRestylingKeepsOtherAttributesSuchAsMarkedTextUnderlines() {
        let storage = WritingTextStorage(markdown: "text", typography: typography)
        storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: 0, length: 4))

        storage.replaceCharacters(in: NSRange(location: 4, length: 0), with: "!")

        XCTAssertNotNil(storage.attribute(.underlineStyle, at: 1, effectiveRange: nil))
    }

    // MARK: - Live preview

    func testSyntaxIsHiddenOutsideTheRevealedLines() {
        let storage = WritingTextStorage(markdown: "**bold** text\nsecond *line*", typography: typography)
        let layoutManager = makeLayout(for: storage)
        let secondLineMarker = (storage.string as NSString).range(of: "*line").location
        let everything = NSRange(location: 0, length: storage.length)

        XCTAssertEqual(glyphProperty(at: 0, in: layoutManager), .null)
        XCTAssertNotEqual(glyphProperty(at: 2, in: layoutManager), .null)
        XCTAssertEqual(glyphProperty(at: secondLineMarker, in: layoutManager), .null)

        layoutManager.revealedRange = NSRange(location: 0, length: 14)
        layoutManager.invalidateGlyphs(forCharacterRange: everything, changeInLength: 0, actualCharacterRange: nil)
        XCTAssertNotEqual(glyphProperty(at: 0, in: layoutManager), .null)
        XCTAssertEqual(glyphProperty(at: secondLineMarker, in: layoutManager), .null)
    }

    func testListMarkersAreDrawnAsBulletsWhenNotRevealed() {
        let storage = WritingTextStorage(markdown: "- item", typography: typography)
        let layoutManager = makeLayout(for: storage)
        layoutManager.ensureGlyphs(forCharacterRange: NSRange(location: 0, length: storage.length))
        let bullet = layoutManager.cgGlyph(at: 0)

        layoutManager.revealedRange = NSRange(location: 0, length: storage.length)
        layoutManager.invalidateGlyphs(forCharacterRange: NSRange(location: 0, length: storage.length), changeInLength: 0, actualCharacterRange: nil)
        layoutManager.ensureGlyphs(forCharacterRange: NSRange(location: 0, length: storage.length))

        XCTAssertNotEqual(layoutManager.cgGlyph(at: 0), bullet)
    }

    // MARK: - Documents

    func testEditsWithoutAnEditorAreUndoable() throws {
        let library = try makeLibrary()
        let writing = try library.createWriting(markdown: "Start")
        let document = WritingDocument(id: writing.id, markdown: "Start", typography: typography, library: library)

        document.apply(WritingInsertion.block("> Quote", in: "Start", at: 5))
        XCTAssertEqual(document.textStorage.string, "Start\n\n> Quote\n\n")
        XCTAssertEqual(document.selectedRange, NSRange(location: 14, length: 0))

        document.undoManager.undo()
        XCTAssertEqual(document.textStorage.string, "Start")
        document.undoManager.redo()
        XCTAssertEqual(document.textStorage.string, "Start\n\n> Quote\n\n")
    }

    func testQuotingCreatesAWritingWhenNoneIsOpenAndSavesIt() throws {
        let library = try makeLibrary()
        let center = WritingDocumentCenter(library: library)
        let paperID = UUID()
        let citation = PaperCitation(paperID: paperID, pageIndex: 4, quotePrefix: "Attention is all you need")

        let title = try center.insertCitation(citation, label: "Vaswani et al., 2017, p. 5", quote: "Attention is all you need")

        XCTAssertEqual(title, "Attention is all you need")
        let writing = try XCTUnwrap(library.currentWriting)
        XCTAssertEqual(writing.citedPaperIDs, [paperID])
        let saved = try library.markdown(for: writing.id)
        XCTAssertTrue(saved.hasPrefix("> Attention is all you need\n>\n> — [Vaswani et al., 2017, p. 5](readpaper://paper/\(paperID.uuidString)?p=5"), saved)

        _ = try center.insertCitation(citation, label: "Vaswani", quote: nil)
        XCTAssertTrue(try center.document(for: writing.id).textStorage.string.contains("[Vaswani](readpaper://"))
    }

    func testDocumentSavesAfterTypingStops() async throws {
        let library = try makeLibrary()
        let writing = try library.createWriting(markdown: "")
        let document = WritingDocument(id: writing.id, markdown: "", typography: typography, library: library)

        document.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "# Draft")
        XCTAssertTrue(document.hasUnsavedChanges)
        XCTAssertEqual(try library.markdown(for: writing.id), "")

        try await Task.sleep(for: WritingDocument.saveDelay + .milliseconds(400))
        XCTAssertFalse(document.hasUnsavedChanges)
        XCTAssertEqual(try library.markdown(for: writing.id), "# Draft")
        XCTAssertEqual(library.metadata(for: writing.id)?.title, "Draft")
    }

    // MARK: - Text view

    func testReturnAndCommandBInTheEditor() throws {
        let library = try makeLibrary()
        let writing = try library.createWriting(markdown: "- first")
        let document = WritingDocument(id: writing.id, markdown: "- first", typography: typography, library: library)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let editor = WritingEditorView(document: document, typography: typography, focusRequest: 0, onOpenLink: { _ in })
        let coordinator = editor.makeCoordinator()
        let layoutManager = WritingLayoutManager(typography: typography)
        let container = NSTextContainer(size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        layoutManager.addTextContainer(container)
        document.textStorage.addLayoutManager(layoutManager)
        let textView = WritingTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), textContainer: container)
        textView.delegate = coordinator
        textView.allowsUndo = true
        textView.isRichText = false
        window.contentView = textView
        coordinator.attach(textView: textView, layoutManager: layoutManager)
        XCTAssertTrue(window.makeFirstResponder(textView))

        textView.setSelectedRange(NSRange(location: 7, length: 0))
        textView.insertNewline(nil)
        XCTAssertEqual(textView.string, "- first\n- ")

        textView.insertText("second", replacementRange: textView.selectedRange())
        textView.setSelectedRange(NSRange(location: 10, length: 6))
        let commandB = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "b",
            charactersIgnoringModifiers: "b", isARepeat: false, keyCode: 11
        ))
        XCTAssertTrue(textView.performKeyEquivalent(with: commandB))
        XCTAssertEqual(textView.string, "- first\n- **second**")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 12, length: 6))

        XCTAssertTrue(textView.performKeyEquivalent(with: commandB))
        XCTAssertEqual(textView.string, "- first\n- second")

        textView.setSelectedRange(NSRange(location: 16, length: 0))
        textView.insertNewline(nil)
        textView.insertNewline(nil)
        XCTAssertEqual(textView.string, "- first\n- second\n\n")

        coordinator.detach()
        XCTAssertEqual(try library.markdown(for: writing.id), "- first\n- second\n\n")
    }

    func testInputMethodCompositionSurvivesRestyling() throws {
        let library = try makeLibrary()
        let writing = try library.createWriting(markdown: "")
        let document = WritingDocument(id: writing.id, markdown: "**粗**", typography: typography, library: library)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let layoutManager = WritingLayoutManager(typography: typography)
        let container = NSTextContainer(size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        layoutManager.addTextContainer(container)
        document.textStorage.addLayoutManager(layoutManager)
        let textView = WritingTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), textContainer: container)
        textView.isRichText = false
        window.contentView = textView
        XCTAssertTrue(window.makeFirstResponder(textView))
        textView.setSelectedRange(NSRange(location: 3, length: 0))

        textView.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(textView.hasMarkedText())
        XCTAssertEqual(textView.markedRange(), NSRange(location: 3, length: 5))
        let markedAttributes = document.textStorage.attributes(at: 4, effectiveRange: nil)
        let expectsUnderline = (textView.markedTextAttributes?[.underlineStyle]) != nil
        if expectsUnderline {
            XCTAssertNotNil(markedAttributes[.underlineStyle], "The composition keeps its underline")
        }

        textView.insertText("中", replacementRange: textView.markedRange())
        XCTAssertFalse(textView.hasMarkedText())
        XCTAssertEqual(textView.string, "**粗中**")
        XCTAssertTrue(try XCTUnwrap(font(at: 3, in: document.textStorage)).fontDescriptor.symbolicTraits.contains(.bold))
    }
}
