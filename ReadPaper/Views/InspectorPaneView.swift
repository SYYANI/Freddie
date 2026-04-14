import AppKit
import SwiftData
import SwiftUI

struct InspectorPaneView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.localizationBundle) private var bundle
    @State private var notePendingDeletion: Note?
    @State private var noteDeletionErrorMessage: String?
    @State private var focusedNoteID: UUID?
    @State private var isAbstractExpanded = false
    var paper: Paper?
    var notes: [Note]
    var isCollapsed: Bool

    var body: some View {
        Group {
            if isCollapsed {
                Color.clear
            } else {
                expandedInspectorPane
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .confirmationDialog(
            String(localized: "Delete Note?", bundle: bundle),
            isPresented: Binding(
                get: { notePendingDeletion != nil },
                set: { isPresented in
                    if !isPresented {
                        notePendingDeletion = nil
                    }
                }
            ),
            presenting: notePendingDeletion
        ) { note in
            Button(String(localized: "Delete", bundle: bundle), role: .destructive) {
                deleteNote(note)
            }
            Button(String(localized: "Cancel", bundle: bundle), role: .cancel) {}
        } message: { note in
            Text(
                note.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? String(localized: "This empty note will be removed.", bundle: bundle)
                    : String(localized: "This note will be permanently removed.", bundle: bundle)
            )
        }
        .alert(
            String(localized: "Unable to Delete Note", bundle: bundle),
            isPresented: Binding(
                get: { noteDeletionErrorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        noteDeletionErrorMessage = nil
                    }
                }
            )
        ) {
            Button(String(localized: "OK", bundle: bundle), role: .cancel) {}
        } message: {
            Text(noteDeletionErrorMessage ?? "")
        }
    }

    private var expandedInspectorPane: some View {
        VStack(spacing: 0) {
            paneHeader
            Divider()

            Group {
                if let paper {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            metadataSection(paper)
                            notesSection(paper)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                    }
                } else {
                    emptyInspectorState
                }
            }
        }
    }

    private var paneHeader: some View {
        HStack(spacing: 12) {
            Text("INSPECTOR", bundle: bundle)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(1.1)

            if paper == nil {
                Text("Paper details, abstract, and notes", bundle: bundle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("Metadata, abstract, and notes", bundle: bundle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .frame(minHeight: 20)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func metadataSection(_ paper: Paper) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Metadata", bundle: bundle)
                .font(.headline)
            Text(paper.title)
                .font(.title3.weight(.semibold))
                .textSelection(.enabled)
            Text(paper.displayAuthors)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let identifierText = paper.metadataIdentifierText {
                Text(identifierText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if !paper.abstractText.isEmpty {
                abstractView(paper.abstractText)
            }
        }
    }
    
    private func abstractView(_ abstractText: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Abstract", bundle: bundle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isAbstractExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(
                            isAbstractExpanded 
                                ? String(localized: "Show Less", bundle: bundle)
                                : String(localized: "Show More", bundle: bundle)
                        )
                        .font(.caption.weight(.medium))
                        Image(systemName: isAbstractExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption2.weight(.semibold))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(Color.primary.opacity(0.05))
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            
            ZStack(alignment: .bottom) {
                Text(abstractText)
                    .font(.callout)
                    .textSelection(.enabled)
                    .lineLimit(isAbstractExpanded ? nil : 8)
                    .animation(.easeInOut(duration: 0.2), value: isAbstractExpanded)
                    .frame(maxWidth: .infinity, alignment: .leading)
                
                if !isAbstractExpanded {
                    LinearGradient(
                        gradient: Gradient(colors: [
                            .clear,
                            Color(nsColor: .controlBackgroundColor).opacity(0.9)
                        ]),
                        startPoint: .center,
                        endPoint: .bottom
                    )
                    .frame(height: 40)
                    .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private func notesSection(_ paper: Paper) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Notes", bundle: bundle)
                    .font(.headline)
                Spacer()
                Button {
                    addNote(for: paper)
                } label: {
                    Label(String(localized: "Add Note", bundle: bundle), systemImage: "plus")
                }
            }

            if notes.isEmpty {
                Text("No notes yet.", bundle: bundle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(notes) { note in
                    NoteEditor(
                        note: note,
                        shouldFocus: focusedNoteID == note.id
                    ) {
                        notePendingDeletion = note
                    } onFocusApplied: {
                        if focusedNoteID == note.id {
                            focusedNoteID = nil
                        }
                    }
                }
            }
        }
    }

    private func addNote(for paper: Paper) {
        let note = Note(paperID: paper.id, body: "")
        modelContext.insert(note)
        try? modelContext.save()
        focusedNoteID = note.id
    }

    private func deleteNote(_ note: Note) {
        if focusedNoteID == note.id {
            focusedNoteID = nil
        }
        modelContext.delete(note)

        do {
            try modelContext.save()
            notePendingDeletion = nil
        } catch {
            modelContext.rollback()
            notePendingDeletion = nil
            noteDeletionErrorMessage = error.localizedDescription
        }
    }

    private var emptyInspectorState: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("INSPECTOR", bundle: bundle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .tracking(1.1)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Paper details will appear here", bundle: bundle)
                        .font(.title3.weight(.semibold))
                    Text("Select or import a paper to view metadata, abstract, and notes in this panel.", bundle: bundle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 12) {
                    inspectorHintRow(
                        title: String(localized: "Metadata", bundle: bundle),
                        systemImage: "text.document",
                        description: String(localized: "Title, authors, arXiv ID, and abstract.", bundle: bundle)
                    )
                    inspectorHintRow(
                        title: String(localized: "Notes", bundle: bundle),
                        systemImage: "note.text",
                        description: String(localized: "Quick reading notes stay attached to the current paper.", bundle: bundle)
                    )
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06))
                }
            }
            .padding(16)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func inspectorHintRow(
        title: String,
        systemImage: String,
        description: String
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 30, height: 30)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(description)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct NoteEditor: View {
    @Environment(\.localizationBundle) private var bundle
    @Bindable var note: Note
    let shouldFocus: Bool
    let onDelete: () -> Void
    let onFocusApplied: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(note.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(role: .destructive, action: onDelete) {
                    Label(String(localized: "Delete Note", bundle: bundle), systemImage: "trash")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Delete note", bundle: bundle))
            }

            InsetTextView(
                text: Binding(
                    get: { note.body },
                    set: { newValue in
                        note.body = newValue
                        note.modifiedAt = Date()
                    }
                ),
                shouldFocus: shouldFocus,
                onFocusApplied: onFocusApplied
            )
                .frame(minHeight: 90)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(.quaternary)
                        .allowsHitTesting(false)
                }
        }
    }
}

private struct InsetTextView: NSViewRepresentable {
    @Binding var text: String
    var shouldFocus: Bool
    var onFocusApplied: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onFocusApplied: onFocusApplied)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.font = .preferredFont(forTextStyle: .body)
        textView.string = text
        textView.textContainerInset = NSSize(width: 10, height: 10)

        if let textContainer = textView.textContainer {
            textContainer.widthTracksTextView = true
            textContainer.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        }

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }

        context.coordinator.applyFocusIfNeeded(to: textView, shouldFocus: shouldFocus)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding private var text: String
        private let onFocusApplied: () -> Void
        private var hasAppliedFocus = false
        private var isFocusScheduled = false
        private var focusGeneration = 0

        init(text: Binding<String>, onFocusApplied: @escaping () -> Void) {
            _text = text
            self.onFocusApplied = onFocusApplied
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
        }

        @MainActor
        func applyFocusIfNeeded(to textView: NSTextView, shouldFocus: Bool) {
            guard shouldFocus else {
                focusGeneration += 1
                hasAppliedFocus = false
                isFocusScheduled = false
                return
            }

            guard !hasAppliedFocus, !isFocusScheduled else { return }
            isFocusScheduled = true
            let generation = focusGeneration

            Task { @MainActor [weak self, weak textView] in
                guard let self else { return }
                self.isFocusScheduled = false
                guard generation == self.focusGeneration,
                      let textView,
                      let window = textView.window else {
                    return
                }

                if window.firstResponder === textView {
                    self.hasAppliedFocus = true
                    self.onFocusApplied()
                    return
                }

                if window.makeFirstResponder(textView) {
                    self.hasAppliedFocus = true
                    self.onFocusApplied()
                }
            }
        }
    }
}
