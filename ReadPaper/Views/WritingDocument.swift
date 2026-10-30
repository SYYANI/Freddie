import AppKit

/// An open writing: its text, undo history and last selection. It outlives the editor,
/// so a quote can be inserted at the caret while the Writing tab is hidden.
@MainActor
final class WritingDocument {
    static let saveDelay: Duration = .milliseconds(800)

    let id: UUID
    let textStorage: WritingTextStorage
    let undoManager = UndoManager()
    /// The selection to restore when an editor shows the document again.
    var selectedRange: NSRange
    weak var textView: WritingTextView?
    /// Lets the editor keep its revealed lines in place when text changes elsewhere.
    var onCharactersEdited: ((NSRange, Int) -> Void)?
    /// Text to point out once an editor shows the document, e.g. a citation revealed from
    /// the reader while the Writing tab was hidden.
    var pendingIndicatorRange: NSRange?

    private let library: WritingLibrary
    private var saveTask: Task<Void, Never>?
    private(set) var hasUnsavedChanges = false

    init(id: UUID, markdown: String, typography: WritingTypography, library: WritingLibrary) {
        self.id = id
        self.library = library
        textStorage = WritingTextStorage(
            markdown: markdown,
            typography: typography,
            baseURL: library.directoryURL(for: id)
        )
        selectedRange = NSRange(location: (markdown as NSString).length, length: 0)
        textStorage.onCharactersEdited = { [weak self] range, delta in
            MainActor.assumeIsolated {
                self?.charactersEdited(range, changeInLength: delta)
            }
        }
    }

    var currentSelection: NSRange {
        textView?.selectedRange() ?? selectedRange
    }

    /// Saves now, e.g. before the editor goes away or the app quits.
    func save() {
        saveTask?.cancel()
        saveTask = nil
        guard hasUnsavedChanges else { return }
        if library.save(markdown: textStorage.string, for: id) {
            hasUnsavedChanges = false
        }
    }

    func discardPendingSave() {
        saveTask?.cancel()
        saveTask = nil
        hasUnsavedChanges = false
    }

    func reloadAfterSync(markdown: String) {
        guard !hasUnsavedChanges, textView?.hasMarkedText() != true, markdown != textStorage.string else { return }
        let originalLength = textStorage.length
        let callback = textStorage.onCharactersEdited
        textStorage.onCharactersEdited = nil
        textStorage.replaceCharacters(in: NSRange(location: 0, length: originalLength), with: markdown)
        textStorage.onCharactersEdited = callback
        undoManager.removeAllActions()
        pendingIndicatorRange = nil
        selectedRange = NSRange(location: min(currentSelection.location, textStorage.length), length: 0)
        textView?.setSelectedRange(selectedRange)
        onCharactersEdited?(NSRange(location: 0, length: originalLength), textStorage.length - originalLength)
    }

    /// Applies an edit made by the app as one undoable step, through the editor when
    /// one is showing the document.
    func apply(_ edit: WritingEdit) {
        let length = (textStorage.string as NSString).length
        let range = NSRange(
            location: min(edit.range.location, length),
            length: min(edit.range.length, length - min(edit.range.location, length))
        )
        if let textView {
            if textView.hasMarkedText() {
                textView.unmarkText()
            }
            guard textView.shouldChangeText(in: range, replacementString: edit.replacement) else { return }
            textStorage.replaceCharacters(in: range, with: edit.replacement)
            textView.didChangeText()
            textView.setSelectedRange(edit.selectionAfter)
            textView.scrollRangeToVisible(edit.selectionAfter)
        } else {
            replace(range, with: edit.replacement, selectingAfter: edit.selectionAfter)
        }
        selectedRange = edit.selectionAfter
    }

    /// Copies images into the writing's folder and inserts each as its own paragraph after
    /// the paragraph at `location`. Images added before a failure are kept.
    func insertImages(_ sources: [WritingImageSource], at location: Int) throws {
        var images: [String] = []
        var failure: Error?
        for source in sources {
            do {
                let path = try library.importImage(source, into: id)
                var alt = ""
                if case let .file(url) = source {
                    alt = url.deletingPathExtension().lastPathComponent
                }
                images.append(WritingImagePath.markdown(alt: alt, relativePath: path))
            } catch {
                failure = error
                break
            }
        }
        if images.isEmpty == false {
            apply(WritingInsertion.block(images.joined(separator: "\n\n"), in: textStorage.string, at: location))
        }
        if let failure {
            throw failure
        }
    }

    /// Selects the label of the first link to `citation` and points it out: right away when
    /// an editor shows the document, otherwise when one does.
    @discardableResult
    func revealCitation(_ citation: PaperCitation) -> Bool {
        guard let occurrence = WritingCitationScanner.occurrences(in: textStorage.string)
            .first(where: { $0.citation == citation }) else {
            return false
        }
        let range = occurrence.labelRange
        selectedRange = range
        if let textView, textView.window != nil {
            textView.setSelectedRange(range)
            textView.scrollRangeToVisible(range)
            textView.showFindIndicator(for: range)
        } else {
            pendingIndicatorRange = range
        }
        return true
    }

    private func replace(_ range: NSRange, with replacement: String, selectingAfter selection: NSRange) {
        let original = textStorage.attributedSubstring(from: range).string
        let previousSelection = selectedRange
        textStorage.replaceCharacters(in: range, with: replacement)
        selectedRange = selection
        let inserted = NSRange(location: range.location, length: (replacement as NSString).length)
        undoManager.registerUndo(withTarget: self) { document in
            MainActor.assumeIsolated {
                document.replace(inserted, with: original, selectingAfter: previousSelection)
            }
        }
    }

    private func charactersEdited(_ range: NSRange, changeInLength delta: Int) {
        hasUnsavedChanges = true
        onCharactersEdited?(range, delta)
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDelay)
            guard Task.isCancelled == false else { return }
            self?.save()
        }
    }
}

/// Keeps one `WritingDocument` per writing for the whole session, shared by every
/// window's Writing tab and by the reader's "Quote in Writing".
@MainActor
final class WritingDocumentCenter {
    static let shared = WritingDocumentCenter(library: .shared)

    let library: WritingLibrary
    private var documents: [UUID: WritingDocument] = [:]

    var typography = WritingTypography(usesPaperAppearance: false) {
        didSet {
            guard typography != oldValue else { return }
            for document in documents.values {
                document.textStorage.typography = typography
            }
        }
    }

    init(library: WritingLibrary) {
        self.library = library
    }

    func document(for id: UUID) throws -> WritingDocument {
        if let document = documents[id] {
            return document
        }
        let document = WritingDocument(
            id: id,
            markdown: try library.markdown(for: id),
            typography: typography,
            library: library
        )
        documents[id] = document
        return document
    }

    func saveAll() {
        for document in documents.values {
            document.save()
        }
    }

    var syncBlockedWritingIDs: Set<UUID> {
        Set(documents.values.filter { $0.hasUnsavedChanges || $0.textView?.hasMarkedText() == true }.map(\.id))
    }

    func reloadAfterSync(_ ids: Set<UUID>) {
        for id in ids {
            guard let document = documents[id], !document.hasUnsavedChanges else { continue }
            if let markdown = try? library.markdown(for: id) { document.reloadAfterSync(markdown: markdown) }
            else { document.discardPendingSave(); documents[id] = nil }
        }
    }

    func deleteWriting(_ id: UUID) throws {
        documents[id]?.discardPendingSave()
        try library.deleteWriting(id)
        documents[id] = nil
    }

    /// Makes the writing the open one and selects the citation in it.
    func revealCitation(_ record: WritingCitationRecord, inWriting id: UUID) throws {
        saveAll()
        library.selectWriting(id)
        try document(for: id).revealCitation(record.citation)
    }

    /// Inserts a citation into the writing open in the Writing tab, creating a writing
    /// when there is none, and saves it. With a quote, the quote and its citation go in
    /// as a paragraph after the caret's; without one, just the citation at the caret.
    /// Returns the writing's title for the confirmation.
    func insertCitation(_ citation: PaperCitation, label: String, quote: String?) throws -> String {
        library.loadIfNeeded()
        let id = try library.currentWriting?.id ?? library.createWriting().id
        let document = try document(for: id)
        let text = document.textStorage.string
        let selection = document.currentSelection

        let edit: WritingEdit
        if let quote, quote.isEmpty == false {
            edit = WritingInsertion.block(
                PaperCitation.quoteMarkdown(quote: quote, label: label, citation: citation),
                in: text,
                at: NSMaxRange(selection)
            )
        } else {
            edit = WritingInsertion.inline(
                PaperCitation.inlineMarkdown(label: label, citation: citation),
                in: text,
                selection: selection
            )
        }
        document.apply(edit)
        document.save()
        return library.metadata(for: id)?.title ?? ""
    }
}
