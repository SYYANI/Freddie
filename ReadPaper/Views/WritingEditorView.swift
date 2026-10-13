import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The writing editor: Markdown that is shown formatted as you type. The lines holding
/// the selection show their Markdown syntax; every other line hides it.
struct WritingEditorView: NSViewRepresentable {
    let document: WritingDocument
    var typography: WritingTypography
    /// Changing it moves keyboard focus into the editor.
    var focusRequest: Int
    /// Keeps lines readable in a wide window by centering a column of at most this width.
    var maximumTextWidth: CGFloat? = nil
    var onOpenLink: (WritingLinkActivation) -> Void
    /// Reports images that could not be added.
    var onImageError: (Error) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(document: document)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let layoutManager = WritingLayoutManager(typography: typography)
        layoutManager.allowsNonContiguousLayout = true
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        document.textStorage.addLayoutManager(layoutManager)

        let textView = WritingTextView(frame: .zero, textContainer: container)
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFontPanel = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 12, height: 14)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.smartInsertDeleteEnabled = false
        if #available(macOS 15.0, *) {
            textView.writingToolsBehavior = .none
        }
        textView.linkTextAttributes = [:]
        textView.typingAttributes = document.textStorage.typingAttributes(at: document.selectedRange.location)
        textView.maximumTextWidth = maximumTextWidth
        // Registers the image types added by `acceptableDragTypes`.
        textView.updateDragTypeRegistration()

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView

        context.coordinator.attach(textView: textView, layoutManager: layoutManager)
        context.coordinator.onOpenLink = onOpenLink
        context.coordinator.onImageError = onImageError
        context.coordinator.lastFocusRequest = focusRequest
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onOpenLink = onOpenLink
        coordinator.onImageError = onImageError
        if let textView = coordinator.textView, textView.maximumTextWidth != maximumTextWidth {
            textView.maximumTextWidth = maximumTextWidth
        }
        if let layoutManager = coordinator.layoutManager, layoutManager.typography != typography {
            layoutManager.typography = typography
            coordinator.textView?.needsDisplay = true
        }
        if coordinator.lastFocusRequest != focusRequest {
            coordinator.lastFocusRequest = focusRequest
            coordinator.focus()
        }
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let document: WritingDocument
        weak var textView: WritingTextView?
        var layoutManager: WritingLayoutManager?
        var onOpenLink: (WritingLinkActivation) -> Void = { _ in }
        var onImageError: (Error) -> Void = { _ in }
        var lastFocusRequest = 0
        /// Tracked from the text view: the window's first responder is not updated yet
        /// while `becomeFirstResponder` runs.
        private var isFocused = false

        init(document: WritingDocument) {
            self.document = document
        }

        func attach(textView: WritingTextView, layoutManager: WritingLayoutManager) {
            self.textView = textView
            self.layoutManager = layoutManager
            document.textView = textView
            document.onCharactersEdited = { [weak self] range, delta in
                self?.shiftRevealedRange(afterEditing: range, changeInLength: delta)
            }
            textView.onOpenLink = { [weak self] link in
                self?.onOpenLink(link)
            }
            textView.onFocusChange = { [weak self] isFocused in
                self?.isFocused = isFocused
                self?.updateRevealedRange()
            }
            textView.onInsertImages = { [weak self] sources, location in
                self?.insertImages(sources, at: location)
            }

            let length = (document.textStorage.string as NSString).length
            let selection = NSRange(
                location: min(document.selectedRange.location, length),
                length: min(document.selectedRange.length, length - min(document.selectedRange.location, length))
            )
            textView.setSelectedRange(selection)
            let indicatorRange = document.pendingIndicatorRange
            document.pendingIndicatorRange = nil
            Task { @MainActor [weak textView] in
                textView?.scrollRangeToVisible(selection)
                guard let indicatorRange else { return }
                // After the editor is on screen and laid out, or the indicator has no place to go.
                try? await Task.sleep(for: .milliseconds(150))
                guard let textView, textView.window != nil,
                      NSMaxRange(indicatorRange) <= (textView.string as NSString).length else { return }
                textView.scrollRangeToVisible(indicatorRange)
                textView.showFindIndicator(for: indicatorRange)
            }
        }

        private func insertImages(_ sources: [WritingImageSource], at location: Int) {
            do {
                try document.insertImages(sources, at: location)
            } catch {
                onImageError(error)
            }
        }

        func detach() {
            guard let textView else { return }
            document.selectedRange = textView.selectedRange()
            if document.textView === textView {
                document.textView = nil
                document.onCharactersEdited = nil
            }
            if let layoutManager {
                document.textStorage.removeLayoutManager(layoutManager)
            }
            document.save()
            self.textView = nil
            self.layoutManager = nil
        }

        func focus() {
            Task { @MainActor [weak self] in
                guard let textView = self?.textView, let window = textView.window else { return }
                window.makeFirstResponder(textView)
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            document.selectedRange = textView.selectedRange()
            textView.typingAttributes = document.textStorage.typingAttributes(at: textView.selectedRange().location)
            updateRevealedRange()
        }

        func undoManager(for view: NSTextView) -> UndoManager? {
            document.undoManager
        }

        /// The lines touched by the selection while the editor has focus.
        private func updateRevealedRange() {
            guard let textView, let layoutManager else { return }
            let text = document.textStorage.string as NSString
            var revealed: NSRange?
            if isFocused {
                let selection = textView.selectedRange()
                let location = min(selection.location, text.length)
                let end = min(NSMaxRange(selection), text.length)
                revealed = text.lineRange(for: NSRange(location: location, length: end - location))
            }
            guard revealed != layoutManager.revealedRange else { return }
            let previous = layoutManager.revealedRange
            layoutManager.revealedRange = revealed
            for range in [previous, revealed].compactMap({ $0 }) {
                invalidate(range)
            }
        }

        private func shiftRevealedRange(afterEditing editedRange: NSRange, changeInLength delta: Int) {
            guard let layoutManager, var revealed = layoutManager.revealedRange else { return }
            let editStart = editedRange.location
            if editStart <= revealed.location, NSMaxRange(editedRange) - delta <= revealed.location {
                revealed.location = max(0, revealed.location + delta)
            } else if editStart <= NSMaxRange(revealed) {
                revealed.length = max(0, revealed.length + delta)
            }
            layoutManager.revealedRange = revealed
        }

        private func invalidate(_ range: NSRange) {
            guard let layoutManager else { return }
            let length = document.textStorage.length
            let location = min(range.location, length)
            let clamped = NSRange(location: location, length: min(range.length, length - location))
            guard clamped.length > 0 else { return }
            layoutManager.invalidateGlyphs(forCharacterRange: clamped, changeInLength: 0, actualCharacterRange: nil)
            layoutManager.invalidateLayout(forCharacterRange: clamped, actualCharacterRange: nil)
            layoutManager.invalidateDisplay(forCharacterRange: clamped)
        }
    }
}

/// A click on a link label in the writing editor.
struct WritingLinkActivation: Equatable {
    var destination: String
    var title: String?
    /// Where the label is in the text.
    var location: Int
}

/// Editing behaviors of the writing editor on top of `NSTextView`.
final class WritingTextView: NSTextView {
    static let minimumHorizontalInset: CGFloat = 12

    var onOpenLink: ((WritingLinkActivation) -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    /// Images pasted or dropped, with the character index to add them at.
    var onInsertImages: (([WritingImageSource], Int) -> Void)?
    /// Centers a column of at most this width.
    var maximumTextWidth: CGFloat? {
        didSet {
            updateHorizontalInset()
        }
    }

    private var evaluatedDrag: (sequenceNumber: Int, sources: [WritingImageSource]?)?

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateHorizontalInset()
    }

    private func updateHorizontalInset() {
        var inset = Self.minimumHorizontalInset
        if let maximumTextWidth {
            inset = max(inset, ((frame.width - maximumTextWidth) / 2).rounded(.down))
        }
        guard textContainerInset.width != inset else { return }
        textContainerInset = NSSize(width: inset, height: textContainerInset.height)
        if let textContainer, textContainer.widthTracksTextView {
            textContainer.size = NSSize(width: max(0, frame.width - 2 * inset), height: textContainer.size.height)
        }
    }

    // MARK: - Images

    /// Image files, or image data such as a screenshot. Pasted image data is only used when
    /// there is no text to paste instead.
    static func imageSources(on pasteboard: NSPasteboard, allowsDataWithText: Bool) -> [WritingImageSource]? {
        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        if urls.isEmpty == false {
            let images = urls.filter { url in
                UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
            }
            return images.isEmpty ? nil : images.map { .file($0) }
        }
        guard allowsDataWithText || pasteboard.availableType(from: [.string]) == nil else { return nil }
        if let png = pasteboard.data(forType: .png) {
            return [.data(png, fileExtension: "png")]
        }
        if let tiff = pasteboard.data(forType: .tiff),
           let image = NSBitmapImageRep(data: tiff),
           let png = image.representation(using: .png, properties: [:]) {
            return [.data(png, fileExtension: "png")]
        }
        return nil
    }

    override func paste(_ sender: Any?) {
        if let onInsertImages, let sources = Self.imageSources(on: .general, allowsDataWithText: false) {
            onInsertImages(sources, NSMaxRange(selectedRange()))
            return
        }
        super.paste(sender)
    }

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        var types = super.acceptableDragTypes
        for type in [NSPasteboard.PasteboardType.fileURL, .png, .tiff] where types.contains(type) == false {
            types.append(type)
        }
        return types
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let operation = super.draggingEntered(sender)
        return draggedImages(sender) != nil ? .copy : operation
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let operation = super.draggingUpdated(sender)
        return draggedImages(sender) != nil ? .copy : operation
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        draggedImages(sender) != nil || super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let onInsertImages, let sources = draggedImages(sender) else {
            return super.performDragOperation(sender)
        }
        let location = characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil))
        onInsertImages(sources, location)
        return true
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        evaluatedDrag = nil
        super.draggingEnded(sender)
    }

    /// Reads the drag pasteboard once per drag session.
    private func draggedImages(_ sender: NSDraggingInfo) -> [WritingImageSource]? {
        guard onInsertImages != nil, isEditable else { return nil }
        if let evaluatedDrag, evaluatedDrag.sequenceNumber == sender.draggingSequenceNumber {
            return evaluatedDrag.sources
        }
        let sources = Self.imageSources(on: sender.draggingPasteboard, allowsDataWithText: true)
        evaluatedDrag = (sender.draggingSequenceNumber, sources)
        return sources
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            onFocusChange?(true)
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            onFocusChange?(false)
        }
        return resigned
    }

    /// A click on a link label opens it unless its line is being edited; Command-click
    /// always opens it.
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 1,
           let link = link(at: convert(event.locationInWindow, from: nil)) {
            let isRevealed = (layoutManager as? WritingLayoutManager)?.isRevealed(link.location) ?? false
            if event.modifierFlags.contains(.command) || isRevealed == false {
                onOpenLink?(link)
                return
            }
        }
        super.mouseDown(with: event)
    }

    /// Handled here, before window-level shortcuts such as the PDF annotation menu's
    /// Undo, so they always act on the writing.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        switch (modifiers, event.charactersIgnoringModifiers?.lowercased()) {
        case ([.command], "z"):
            breakUndoCoalescing()
            if undoManager?.canUndo == true {
                undoManager?.undo()
            } else {
                NSSound.beep()
            }
            return true
        case ([.command, .shift], "z"):
            if undoManager?.canRedo == true {
                undoManager?.redo()
            } else {
                NSSound.beep()
            }
            return true
        case ([.command], "b"):
            toggleEmphasis("**")
            return true
        case ([.command], "i"):
            toggleEmphasis("*")
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    override func insertNewline(_ sender: Any?) {
        let selection = selectedRange()
        let length = textStorage?.length ?? 0
        // At the very end there is no character under the caret; use the one before it.
        let probe = selection.location < length ? selection.location : selection.location - 1
        let isInCodeBlock = probe >= 0 && probe < length
            && textStorage?.attribute(.writingCodeBlock, at: probe, effectiveRange: nil) != nil
        guard hasMarkedText() == false,
              let edit = WritingContinuation.newline(in: string, selection: selection, isInCodeBlock: isInCodeBlock) else {
            super.insertNewline(sender)
            return
        }
        replace(edit)
    }

    /// Wraps the selection in `marker`, or removes the markers already around it.
    private func toggleEmphasis(_ marker: String) {
        let selection = selectedRange()
        let text = string as NSString
        let markerLength = (marker as NSString).length
        let before = NSRange(location: selection.location - markerLength, length: markerLength)
        let after = NSRange(location: NSMaxRange(selection), length: markerLength)
        if before.location >= 0, NSMaxRange(after) <= text.length,
           text.substring(with: before) == marker, text.substring(with: after) == marker {
            let inner = text.substring(with: selection)
            replace(WritingEdit(
                range: NSRange(location: before.location, length: NSMaxRange(after) - before.location),
                replacement: inner,
                selectionAfter: NSRange(location: before.location, length: selection.length)
            ))
            return
        }
        let inner = text.substring(with: selection)
        replace(WritingEdit(
            range: selection,
            replacement: marker + inner + marker,
            selectionAfter: NSRange(location: selection.location + markerLength, length: selection.length)
        ))
    }

    private func replace(_ edit: WritingEdit) {
        guard let textStorage, shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return }
        textStorage.replaceCharacters(in: edit.range, with: edit.replacement)
        didChangeText()
        setSelectedRange(edit.selectionAfter)
        scrollRangeToVisible(edit.selectionAfter)
    }

    private func link(at point: NSPoint) -> WritingLinkActivation? {
        guard let layoutManager, let textContainer, let textStorage, textStorage.length > 0 else { return nil }
        let containerPoint = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        var fraction: CGFloat = 0
        let glyphIndex = layoutManager.glyphIndex(
            for: containerPoint,
            in: textContainer,
            fractionOfDistanceThroughGlyph: &fraction
        )
        let glyphRect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyphIndex, length: 1), in: textContainer)
        guard glyphRect.contains(containerPoint) else { return nil }
        let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        guard characterIndex < textStorage.length,
              let destination = textStorage.attribute(.writingLink, at: characterIndex, effectiveRange: nil) as? String else {
            return nil
        }
        return WritingLinkActivation(
            destination: destination,
            title: textStorage.attribute(.writingLinkTitle, at: characterIndex, effectiveRange: nil) as? String,
            location: characterIndex
        )
    }
}
