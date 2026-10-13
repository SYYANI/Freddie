import AppKit
import SwiftUI

/// The writing editor: Markdown that is shown formatted as you type. The lines holding
/// the selection show their Markdown syntax; every other line hides it.
struct WritingEditorView: NSViewRepresentable {
    let document: WritingDocument
    var typography: WritingTypography
    /// Changing it moves keyboard focus into the editor.
    var focusRequest: Int
    var onOpenLink: (WritingLinkActivation) -> Void

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

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView

        context.coordinator.attach(textView: textView, layoutManager: layoutManager)
        context.coordinator.onOpenLink = onOpenLink
        context.coordinator.lastFocusRequest = focusRequest
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onOpenLink = onOpenLink
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

            let length = (document.textStorage.string as NSString).length
            let selection = NSRange(
                location: min(document.selectedRange.location, length),
                length: min(document.selectedRange.length, length - min(document.selectedRange.location, length))
            )
            textView.setSelectedRange(selection)
            Task { @MainActor [weak textView] in
                textView?.scrollRangeToVisible(selection)
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
    var onOpenLink: ((WritingLinkActivation) -> Void)?
    var onFocusChange: ((Bool) -> Void)?

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
