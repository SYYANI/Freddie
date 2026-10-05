import AppKit
import SwiftUI

/// Margin notes beside a single PDF. Each card is aligned with its anchor in
/// the PDF view and pushed down when it would overlap the previous card.
struct PDFSidenoteRail: View {
    static let width: CGFloat = 280
    /// Narrowest PDF view that still leaves room for the rail.
    static let minimumReaderWidth: CGFloat = 480
    private static let cardSpacing: CGFloat = 10
    private static let anchorOffset: CGFloat = 6

    let notes: [Note]
    let layout: PDFSidenoteLayoutModel
    var focusRequest: SidenoteFocusRequest?
    var onFocusHandled: (SidenoteFocusRequest) -> Void
    var onCommit: () -> Void
    var onDelete: (Note) -> Void

    @State private var editingNoteID: UUID?
    @State private var railHeight: CGFloat = 0

    private struct PlacedNote: Identifiable {
        var note: Note
        var number: Int
        var desiredTop: CGFloat
        var id: UUID { note.id }
    }

    var body: some View {
        let placedNotes = visiblePlacedNotes
        SidenoteRailLayout(spacing: Self.cardSpacing) {
            ForEach(placedNotes) { placed in
                PDFSidenoteCard(
                    note: placed.note,
                    number: placed.number,
                    isEditing: editingNoteID == placed.note.id,
                    onBeginEditing: { beginEditing(placed.note.id) },
                    onEndEditing: { endEditing(placed.note.id) },
                    onDelete: { onDelete(placed.note) }
                )
                .layoutValue(key: SidenoteDesiredTopKey.self, value: placed.desiredTop)
            }
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .onTapGesture {
            if let editingNoteID {
                endEditing(editingNoteID)
            }
        }
        .background(ScrollWheelForwarder(target: layout.scrollView))
        .clipped()
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { railHeight = $0 }
        .onAppear(perform: applyFocusRequestIfPossible)
        .onChange(of: focusRequest) { _, _ in applyFocusRequestIfPossible() }
        .onChange(of: placedNotes.map(\.id)) { _, _ in applyFocusRequestIfPossible() }
    }

    /// Notes with a resolved anchor, numbered in reading order. Cards far outside
    /// the viewport are skipped so scrolling only measures nearby cards; the
    /// note being edited is always kept so its editor survives scrolling.
    private var visiblePlacedNotes: [PlacedNote] {
        let tops = layout.anchorTops
        let ordered = notes
            .compactMap { note in tops[note.id].map { (note, $0) } }
            .sorted { $0.1 < $1.1 }
        let visibleRange = (-railHeight * 1.5)...(railHeight * 2.5)
        return ordered.enumerated().compactMap { index, entry in
            let (note, top) = entry
            guard visibleRange.contains(top) || note.id == editingNoteID else { return nil }
            return PlacedNote(note: note, number: index + 1, desiredTop: top - Self.anchorOffset)
        }
    }

    private func beginEditing(_ noteID: UUID) {
        guard editingNoteID != noteID else { return }
        if editingNoteID != nil {
            onCommit()
        }
        editingNoteID = noteID
    }

    private func endEditing(_ noteID: UUID) {
        guard editingNoteID == noteID else { return }
        editingNoteID = nil
        onCommit()
    }

    private func applyFocusRequestIfPossible() {
        guard let focusRequest,
              notes.contains(where: { $0.id == focusRequest.noteID }),
              layout.anchorTops[focusRequest.noteID] != nil else {
            return
        }
        beginEditing(focusRequest.noteID)
        onFocusHandled(focusRequest)
    }
}

private struct SidenoteDesiredTopKey: LayoutValueKey {
    static let defaultValue: CGFloat = 0
}

/// Places cards at their desired tops, in order, without overlap.
private struct SidenoteRailLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? PDFSidenoteRail.width, height: proposal.height ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let widthProposal = ProposedViewSize(width: bounds.width, height: nil)
        let heights = subviews.map { $0.sizeThatFits(widthProposal).height }
        let tops = SidenoteStacking.tops(
            desired: subviews.map { $0[SidenoteDesiredTopKey.self] },
            heights: heights,
            spacing: spacing
        )
        for (index, subview) in subviews.enumerated() {
            subview.place(
                at: CGPoint(x: bounds.minX, y: bounds.minY + tops[index]),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: bounds.width, height: heights[index])
            )
        }
    }
}

private struct PDFSidenoteCard: View {
    @Environment(\.localizationBundle) private var bundle
    @Environment(\.pdfDisplayAppearance) private var displayAppearance
    @Bindable var note: Note
    let number: Int
    let isEditing: Bool
    let onBeginEditing: () -> Void
    let onEndEditing: () -> Void
    let onDelete: () -> Void
    @State private var isHovered = false

    private static let accentColor = Color(red: 0.71, green: 0.47, blue: 0.16)

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(verbatim: "\(number)")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(Self.accentColor)
                .padding(.top, 1)

            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 10)
        .padding(.trailing, 24)
        .padding(.vertical, 7)
        .background(cardBackground)
        .overlay(alignment: .topTrailing) {
            if isHovered || isEditing {
                Button(action: onDelete) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(String(localized: "Delete Note", bundle: bundle))
                .accessibilityLabel(String(localized: "Delete Note", bundle: bundle))
                .padding(4)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if !isEditing {
                onBeginEditing()
            }
        }
        .onHover { isHovered = $0 }
        .padding(.trailing, 12)
    }

    @ViewBuilder
    private var content: some View {
        if isEditing {
            SidenoteTextView(
                text: Binding(
                    get: { note.body },
                    set: { newValue in
                        guard note.body != newValue else { return }
                        note.body = newValue
                        note.modifiedAt = Date()
                    }
                ),
                usesPaperTypography: displayAppearance == .paper,
                onEndEditing: onEndEditing
            )
            .overlay(alignment: .topLeading) {
                if note.body.isEmpty {
                    Text("Write a note…", bundle: bundle)
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .allowsHitTesting(false)
                }
            }
        } else if note.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text("Click to edit note", bundle: bundle)
                .font(.system(size: 12).italic())
                .foregroundStyle(.tertiary)
        } else {
            ReadPaperMarkdownView(markdown: note.body, isCompact: true)
        }
    }

    @ViewBuilder
    private var cardBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        if isEditing {
            shape
                .fill(displayAppearance == .paper
                    ? Color(red: 0.98, green: 0.96, blue: 0.92)
                    : Color(nsColor: .textBackgroundColor).opacity(0.94))
                .overlay { shape.stroke(Color.primary.opacity(0.08)) }
                .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
        } else if isHovered {
            shape.fill(Color.primary.opacity(0.04))
        } else {
            Color.clear
        }
    }
}

/// A borderless, auto-growing plain-text editor. It applies the same input
/// settings as the inspector's note editor to keep system text services quiet.
private struct SidenoteTextView: NSViewRepresentable {
    @Binding var text: String
    var usesPaperTypography: Bool
    var onEndEditing: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onEndEditing: onEndEditing)
    }

    func makeNSView(context: Context) -> SidenoteNSTextView {
        let textView = SidenoteNSTextView(usingTextLayoutManager: false)
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.smartInsertDeleteEnabled = false
        if #available(macOS 15.0, *) {
            textView.writingToolsBehavior = .none
        }
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.font = font
        textView.string = text
        return textView
    }

    func updateNSView(_ textView: SidenoteNSTextView, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onEndEditing = onEndEditing
        if textView.string != text, textView.hasMarkedText() == false {
            textView.string = text
        }
        if textView.font != font {
            textView.font = font
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SidenoteNSTextView, context: Context) -> CGSize? {
        guard let width = proposal.width,
              let textContainer = nsView.textContainer,
              let layoutManager = nsView.layoutManager else {
            return nil
        }
        textContainer.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        let usedHeight = layoutManager.usedRect(for: textContainer).height
        let lineHeight = layoutManager.defaultLineHeight(for: font)
        return CGSize(width: width, height: ceil(max(usedHeight, lineHeight)))
    }

    private var font: NSFont {
        let size: CGFloat = 12
        if usesPaperTypography, let paperFont = NSFont(name: "New York", size: size) {
            return paperFont
        }
        return .systemFont(ofSize: size)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var onEndEditing: () -> Void

        init(text: Binding<String>, onEndEditing: @escaping () -> Void) {
            self.text = text
            self.onEndEditing = onEndEditing
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }

        func textShouldEndEditing(_ textObject: NSText) -> Bool {
            if let textView = textObject as? NSTextView {
                textView.unmarkText()
                textView.inputContext?.discardMarkedText()
            }
            return true
        }

        func textDidEndEditing(_ notification: Notification) {
            onEndEditing()
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            let endsEditing = commandSelector == #selector(NSResponder.cancelOperation(_:)) ||
                (commandSelector == #selector(NSResponder.insertNewline(_:)) &&
                    NSApp.currentEvent?.modifierFlags.contains(.command) == true)
            guard endsEditing else { return false }
            textView.window?.makeFirstResponder(nil)
            return true
        }
    }
}

/// Takes focus with the caret at the end once it is in a window.
final class SidenoteNSTextView: NSTextView {
    private var needsInitialFocus = true

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard needsInitialFocus, window != nil else { return }
        needsInitialFocus = false
        Task { @MainActor [weak self] in
            guard let self, let window = self.window else { return }
            if window.makeFirstResponder(self) {
                self.setSelectedRange(NSRange(location: (self.string as NSString).length, length: 0))
            }
        }
    }
}

/// Sends scroll wheel events over the rail to the PDF, so the rail never
/// becomes a dead zone while reading. It does not take part in hit testing.
private struct ScrollWheelForwarder: NSViewRepresentable {
    weak var target: NSScrollView?

    func makeNSView(context: Context) -> ScrollWheelForwardingView {
        ScrollWheelForwardingView()
    }

    func updateNSView(_ view: ScrollWheelForwardingView, context: Context) {
        view.target = target
    }

    static func dismantleNSView(_ view: ScrollWheelForwardingView, coordinator: ()) {
        view.stopMonitoring()
    }
}

final class ScrollWheelForwardingView: NSView {
    weak var target: NSScrollView?
    nonisolated(unsafe) private var monitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopMonitoring()
        } else if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                nonisolated(unsafe) let scrollEvent = event
                let isForwarded = MainActor.assumeIsolated {
                    guard let self,
                          let target = self.target,
                          let window = self.window,
                          scrollEvent.window === window,
                          self.bounds.contains(self.convert(scrollEvent.locationInWindow, from: nil)) else {
                        return false
                    }
                    target.scrollWheel(with: scrollEvent)
                    return true
                }
                return isForwarded ? nil : event
            }
        }
    }

    func stopMonitoring() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
