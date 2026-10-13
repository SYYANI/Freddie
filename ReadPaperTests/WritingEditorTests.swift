import AppKit
import SwiftUI
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

    // MARK: - Formulas and images

    private func revealAll(_ layoutManager: WritingLayoutManager, in storage: NSTextStorage, _ range: NSRange?) {
        layoutManager.revealedRange = range
        let everything = NSRange(location: 0, length: storage.length)
        layoutManager.invalidateGlyphs(forCharacterRange: everything, changeInLength: 0, actualCharacterRange: nil)
        layoutManager.invalidateLayout(forCharacterRange: everything, actualCharacterRange: nil)
        layoutManager.ensureLayout(for: layoutManager.textContainers[0])
    }

    private func lineRect(at characterIndex: Int, in layoutManager: NSLayoutManager) -> NSRect {
        layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: characterIndex), effectiveRange: nil)
    }

    func testTypesetFormulaTakesThePlaceOfItsTeX() throws {
        let storage = WritingTextStorage(markdown: #"Area $\frac{a}{b}$ here"# + "\nplain", typography: typography)
        let layoutManager = makeLayout(for: storage)
        let text = storage.string as NSString
        let tex = text.range(of: #"\frac"#).location
        let box = try XCTUnwrap(storage.attribute(.writingMath, at: tex, effectiveRange: nil) as? WritingMathBox)
        XCTAssertGreaterThan(box.width, 6)

        XCTAssertEqual(glyphProperty(at: tex - 1, in: layoutManager), .null)
        XCTAssertEqual(glyphProperty(at: tex, in: layoutManager), .controlCharacter)
        XCTAssertEqual(glyphProperty(at: tex + 1, in: layoutManager), .null)
        let after = text.range(of: " here").location
        let formulaStart = layoutManager.location(forGlyphAt: layoutManager.glyphIndexForCharacter(at: tex)).x
        let textAfter = layoutManager.location(forGlyphAt: layoutManager.glyphIndexForCharacter(at: after)).x
        XCTAssertEqual(textAfter - formulaStart, box.width, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(lineRect(at: 0, in: layoutManager).height, lineRect(at: text.length - 1, in: layoutManager).height)

        // While the line is edited, the TeX shows as text.
        revealAll(layoutManager, in: storage, NSRange(location: 0, length: after))
        XCTAssertNotEqual(glyphProperty(at: tex, in: layoutManager), .controlCharacter)
        XCTAssertNotEqual(glyphProperty(at: tex + 1, in: layoutManager), .null)
    }

    func testTallFormulasMakeTheirLineTaller() throws {
        let storage = WritingTextStorage(markdown: #"$$\sum_{i=1}^{n} \frac{a_i}{b_i}$$"# + "\nplain", typography: typography)
        let layoutManager = makeLayout(for: storage)
        let text = storage.string as NSString
        let box = try XCTUnwrap(storage.attribute(.writingMath, at: 2, effectiveRange: nil) as? WritingMathBox)
        let mathLine = lineRect(at: 0, in: layoutManager)
        let plainLine = lineRect(at: text.length - 1, in: layoutManager)

        XCTAssertGreaterThan(mathLine.height, plainLine.height)
        XCTAssertGreaterThanOrEqual(mathLine.height, box.ascent + box.descent)
        let baseline = layoutManager.location(forGlyphAt: layoutManager.glyphIndexForCharacter(at: 2)).y
        XCTAssertGreaterThanOrEqual(baseline, box.ascent, "The formula fits above the baseline")
        XCTAssertGreaterThanOrEqual(mathLine.height - baseline, box.descent, "and below it")
    }

    func testTeXThatCannotBeTypesetStaysVisible() {
        let storage = WritingTextStorage(markdown: #"Bad $\notacommand{x}$ formula"#, typography: typography)
        let tex = (storage.string as NSString).range(of: #"\notacommand"#).location

        XCTAssertNil(storage.attribute(.writingMath, at: tex, effectiveRange: nil))
        XCTAssertNil(storage.attribute(.writingMarker, at: tex - 1, effectiveRange: nil))
        XCTAssertEqual(storage.attribute(.foregroundColor, at: tex, effectiveRange: nil) as? NSColor, typography.invalidMathColor)
    }

    private func writePNG(width: Int, height: Int, to url: URL) throws {
        let image = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: url)
    }

    func testImagesShowInPlaceOfTheirLineOrBelowIt() throws {
        try writePNG(width: 200, height: 100, to: root.appendingPathComponent("assets/pic.png"))
        let markdown = "Intro\n![Figure](assets/pic.png)\nText ![](assets/pic.png) end\n![](assets/missing.png)\nAfter"
        let storage = WritingTextStorage(markdown: markdown, typography: typography, baseURL: root)
        let layoutManager = makeLayout(for: storage)
        let text = storage.string as NSString
        let imageOnly = text.range(of: "![Figure]").location
        let mixed = text.range(of: "Text").location
        let missing = text.range(of: "missing").location
        let plainHeight = lineRect(at: 0, in: layoutManager).height
        let block = WritingImageLayout.topPadding + 100 + WritingImageLayout.bottomPadding

        XCTAssertNotNil(storage.attribute(.writingImage, at: imageOnly, effectiveRange: nil))
        XCTAssertEqual(glyphProperty(at: imageOnly + 3, in: layoutManager), .null, "The alt text is hidden too")
        XCTAssertEqual(lineRect(at: imageOnly, in: layoutManager).height, block, accuracy: 0.5)
        XCTAssertEqual(
            layoutManager.characterRange(forGlyphRange: layoutManager.glyphRange(forCharacterRange: NSRange(location: 0, length: 1), actualCharacterRange: nil), actualGlyphRange: nil).location,
            0
        )
        var introLine = NSRange(location: 0, length: 0)
        _ = layoutManager.lineFragmentRect(forGlyphAt: 0, effectiveRange: &introLine)
        XCTAssertEqual(layoutManager.characterRange(forGlyphRange: introLine, actualGlyphRange: nil), NSRange(location: 0, length: 6), "The image line does not join the line before it")
        XCTAssertEqual(lineRect(at: mixed, in: layoutManager).height, plainHeight + block, accuracy: 0.5)
        XCTAssertNil(storage.attribute(.writingImage, at: missing, effectiveRange: nil))
        XCTAssertNil(storage.attribute(.writingMarker, at: missing, effectiveRange: nil), "A missing image keeps its syntax")
        XCTAssertEqual(lineRect(at: missing, in: layoutManager).height, plainHeight, accuracy: 0.5)

        // Editing the image line shows its Markdown above the image.
        revealAll(layoutManager, in: storage, text.lineRange(for: NSRange(location: imageOnly, length: 0)))
        XCTAssertEqual(lineRect(at: imageOnly, in: layoutManager).height, plainHeight + block, accuracy: 0.5)
    }

    func testWideImagesShrinkToTheLine() throws {
        try writePNG(width: 2000, height: 1000, to: root.appendingPathComponent("assets/wide.png"))
        let storage = WritingTextStorage(markdown: "![](assets/wide.png)", typography: typography, baseURL: root)
        let layoutManager = makeLayout(for: storage)
        let layout = try XCTUnwrap(layoutManager.imageLayout(forLineFragmentGlyphRange: NSRange(location: 0, length: storage.length), lineWidth: 400))

        XCTAssertEqual(layout.items.first?.size, NSSize(width: 390, height: 195))
        XCTAssertTrue(layout.replacesText)
    }

    func testImageSourcesFromAPasteboard() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("WritingEditorTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let png = root.appendingPathComponent("shot.png")
        try writePNG(width: 4, height: 4, to: png)
        let notes = root.appendingPathComponent("notes.txt")
        try "x".write(to: notes, atomically: true, encoding: .utf8)

        pasteboard.clearContents()
        pasteboard.writeObjects([png as NSURL, notes as NSURL])
        XCTAssertEqual(WritingTextView.imageSources(on: pasteboard, allowsDataWithText: false), [.file(png)])

        pasteboard.clearContents()
        pasteboard.writeObjects([notes as NSURL])
        XCTAssertNil(WritingTextView.imageSources(on: pasteboard, allowsDataWithText: false))

        let data = try Data(contentsOf: png)
        pasteboard.clearContents()
        pasteboard.setData(data, forType: .png)
        XCTAssertEqual(WritingTextView.imageSources(on: pasteboard, allowsDataWithText: false), [.data(data, fileExtension: "png")])

        // Text that comes with an image, e.g. from a web page, is pasted as text.
        pasteboard.clearContents()
        pasteboard.setString("caption", forType: .string)
        pasteboard.setData(data, forType: .png)
        XCTAssertNil(WritingTextView.imageSources(on: pasteboard, allowsDataWithText: false))
        XCTAssertNotNil(WritingTextView.imageSources(on: pasteboard, allowsDataWithText: true))
    }

    func testInsertedImagesAreCopiedIntoTheWritingAndShown() throws {
        let library = try makeLibrary()
        let writing = try library.createWriting(markdown: "First paragraph")
        let document = WritingDocument(id: writing.id, markdown: "First paragraph", typography: typography, library: library)
        let source = root.appendingPathComponent("My Figure (1).PNG")
        try writePNG(width: 20, height: 10, to: source)

        try document.insertImages([.file(source)], at: 3)

        XCTAssertEqual(document.textStorage.string, "First paragraph\n\n![My Figure (1)](assets/My-Figure-1.png)\n\n")
        let copied = try XCTUnwrap(library.directoryURL(for: writing.id)).appendingPathComponent("assets/My-Figure-1.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copied.path))
        let imageLocation = (document.textStorage.string as NSString).range(of: "![").location
        XCTAssertNotNil(document.textStorage.attribute(.writingImage, at: imageLocation, effectiveRange: nil))
        document.undoManager.undo()
        XCTAssertEqual(document.textStorage.string, "First paragraph")
    }

    func testWideEditorCentersItsTextColumn() {
        let layoutManager = WritingLayoutManager(typography: typography)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        let textView = WritingTextView(frame: NSRect(x: 0, y: 0, width: 1000, height: 300), textContainer: container)
        textView.textContainerInset = NSSize(width: WritingTextView.minimumHorizontalInset, height: 14)

        textView.maximumTextWidth = 600
        XCTAssertEqual(textView.textContainerInset.width, 200)
        XCTAssertEqual(container.size.width, 600)

        textView.setFrameSize(NSSize(width: 500, height: 300))
        XCTAssertEqual(textView.textContainerInset.width, WritingTextView.minimumHorizontalInset)
        XCTAssertEqual(container.size.width, 500 - 2 * WritingTextView.minimumHorizontalInset)
    }

    /// One writing never has two editors: the inspector shows a placeholder while the
    /// writing window is open.
    func testInspectorStepsAsideWhileTheWritingWindowIsOpen() async throws {
        let library = try makeLibrary()
        _ = try library.createWriting(markdown: "Hello")
        let center = WritingDocumentCenter(library: library)
        let state = WritingWindowState()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSHostingView(rootView: WritingPaneView(
            center: center,
            presentation: .inspector,
            windowState: state,
            focusRequest: 0,
            onOpenCitation: { _, _ in }
        ).frame(width: 400, height: 500))
        window.makeKeyAndOrderFront(nil)
        func hasEditor(_ view: NSView) -> Bool {
            view is WritingTextView || view.subviews.contains(where: hasEditor)
        }
        let contentView = try XCTUnwrap(window.contentView)
        try await waitUntil { hasEditor(contentView) }

        state.windowDidAppear()
        try await waitUntil { hasEditor(contentView) == false }

        // Without a tracked window that is still visible, disappearing means closed.
        state.windowDidDisappear()
        try await waitUntil { hasEditor(contentView) }
    }

    private func waitUntil(timeout: Duration = .seconds(3), _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while condition() == false {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting for condition")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
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

    func testRevealingACitationSelectsItsLabelInTheOpenWriting() throws {
        let library = try makeLibrary()
        let center = WritingDocumentCenter(library: library)
        let citation = PaperCitation(paperID: UUID(), pageIndex: 1, quotePrefix: "Quoted text")
        let markdown = "Intro\n\n> Quoted text\n>\n> — " + PaperCitation.inlineMarkdown(label: "Vaswani", citation: citation)
        let cited = try library.createWriting(markdown: markdown)
        _ = try library.createWriting(markdown: "Another writing")

        try center.revealCitation(WritingCitationRecord(citation: citation, passage: "Quoted text"), inWriting: cited.id)

        XCTAssertEqual(library.currentWritingID, cited.id)
        let document = try center.document(for: cited.id)
        XCTAssertEqual((markdown as NSString).substring(with: document.selectedRange), "Vaswani")
        XCTAssertEqual(document.pendingIndicatorRange, document.selectedRange, "Pointed out once an editor shows it")
        XCTAssertFalse(document.revealCitation(PaperCitation(paperID: UUID())))
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
