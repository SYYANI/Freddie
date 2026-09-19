import AppKit
import SwiftData
import SwiftUI

struct InspectorPaneView: View {
    private enum MetadataField: Hashable {
        case authors
    }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.localizationBundle) private var bundle
    @Environment(\.pdfDisplayAppearance) private var displayAppearance
    @State private var notePendingDeletion: Note?
    @State private var noteDeletionErrorMessage: String?
    @State private var authorsSaveErrorMessage: String?
    @State private var isAbstractExpanded = false
    @State private var abstractTranslationState = AbstractTranslationPresentationState()
    @State private var abstractTranslationTask: Task<Void, Never>?
    @State private var isEditingAuthors = false
    @State private var authorsDraft = ""
    @FocusState private var focusedMetadataField: MetadataField?
    var paper: Paper?
    var notes: [Note]
    var isCollapsed: Bool
    var currentSelectionContext: NoteSelectionContext?
    @Binding var focusedNoteID: UUID?
    var onCreateNote: () -> Void
    var onOpenNoteAnchor: (Note) -> Void

    var body: some View {
        Group {
            if isCollapsed {
                Color.clear
            } else {
                expandedInspectorPane
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .readPaperInspectorBackground()
        .onAppear {
            syncMetadataEditorState(with: paper)
            synchronizeAbstractPresentation(with: paper?.id)
        }
        .onChange(of: paper?.id) { _, newPaperID in
            syncMetadataEditorState(with: paper)
            synchronizeAbstractPresentation(with: newPaperID)
        }
        .onDisappear {
            cancelAbstractTranslation()
        }
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
            Group {
                if let paper {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            metadataSection(paper)
                            notesSection()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                    }
                } else {
                    emptyInspectorState
                }
            }
        }
        .fontDesign(displayAppearance == .paper ? .serif : .default)
    }

    private func metadataSection(_ paper: Paper) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(paper.title)
                .font(.title3.weight(.semibold))
                .textSelection(.enabled)
            authorsView(for: paper)
            if let identifierText = paper.metadataIdentifierText {
                Text(identifierText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let authorsSaveErrorMessage {
                Text(authorsSaveErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if !paper.abstractText.isEmpty {
                abstractView(paper.abstractText)
            }
        }
    }

    @ViewBuilder
    private func authorsView(for paper: Paper) -> some View {
        if isEditingAuthors {
            TextField("", text: $authorsDraft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .foregroundStyle(.secondary)
                .lineLimit(1...3)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.22), lineWidth: 1)
                }
                .focused($focusedMetadataField, equals: .authors)
                .onSubmit {
                    commitAuthorsEdits(for: paper)
                }
                .onChange(of: focusedMetadataField) { _, newValue in
                    if newValue != .authors, isEditingAuthors {
                        commitAuthorsEdits(for: paper)
                    }
                }
                .onExitCommand {
                    cancelAuthorsEditing(for: paper)
                }
        } else {
            Button {
                beginAuthorsEditing(for: paper)
            } label: {
                Text(paper.displayAuthors)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
    
    private func abstractView(_ abstractText: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Abstract", bundle: bundle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                
                HStack(spacing: 8) {
                    if abstractTranslationState.translatedText != nil {
                        Button {
                            abstractTranslationState.showOriginal()
                        } label: {
                            HStack(spacing: 4) {
                                Text(String(localized: "Original", bundle: bundle))
                                    .font(.caption.weight(.medium))
                                    .fixedSize()
                                Image(systemName: "arrow.uturn.backward")
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
                    } else if !abstractTranslationState.isTranslating {
                        Button {
                            translateAbstract()
                        } label: {
                            HStack(spacing: 4) {
                                Text(String(localized: "Translate", bundle: bundle))
                                    .font(.caption.weight(.medium))
                                    .fixedSize()
                                Image(systemName: "character.book.closed")
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
                        .disabled(abstractTranslationState.isTranslating)
                    }
                    
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isAbstractExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(
                                isAbstractExpanded 
                                    ? String(localized: "Less", bundle: bundle)
                                    : String(localized: "More", bundle: bundle)
                            )
                            .font(.caption.weight(.medium))
                            .fixedSize()
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
            }
            
            if let error = abstractTranslationState.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.vertical, 4)
            }
            
            ZStack(alignment: .bottom) {
                if abstractTranslationState.isTranslating {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(String(localized: "Translating abstract...", bundle: bundle))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                } else {
                    Text(abstractTranslationState.translatedText ?? abstractText)
                        .font(.callout)
                        .textSelection(.enabled)
                        .lineLimit(isAbstractExpanded ? nil : 8)
                        .animation(.easeInOut(duration: 0.2), value: isAbstractExpanded)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                
                if !isAbstractExpanded && !abstractTranslationState.isTranslating {
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

    private func notesSection() -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Notes", bundle: bundle)
                    .font(.headline)
                Spacer()
                Button {
                    onCreateNote()
                } label: {
                    Label(
                        currentSelectionContext != nil
                            ? String(localized: "Add Note to Current Selection", bundle: bundle)
                            : String(localized: "Add Note", bundle: bundle),
                        systemImage: "plus"
                    )
                }
            }

            if currentSelectionContext != nil {
                Text("Selected text will be attached to the next note.", bundle: bundle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if notes.isEmpty {
                Text("No notes yet.", bundle: bundle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(notes) { note in
                    NoteEditor(
                        note: note,
                        shouldFocus: focusedNoteID == note.id,
                        onOpenAnchor: note.hasAnchor ? { onOpenNoteAnchor(note) } : nil
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

    private func syncMetadataEditorState(with paper: Paper?) {
        authorsSaveErrorMessage = nil
        isEditingAuthors = false
        focusedMetadataField = nil
        authorsDraft = paper.map { Paper.editableAuthorsText($0.authors) } ?? ""
    }

    private func beginAuthorsEditing(for paper: Paper) {
        authorsSaveErrorMessage = nil
        authorsDraft = Paper.editableAuthorsText(paper.authors)
        isEditingAuthors = true
        focusedMetadataField = .authors
    }

    private func cancelAuthorsEditing(for paper: Paper) {
        authorsSaveErrorMessage = nil
        authorsDraft = Paper.editableAuthorsText(paper.authors)
        isEditingAuthors = false
        focusedMetadataField = nil
    }

    private func commitAuthorsEdits(for paper: Paper) {
        let updatedAuthors = Paper.decodeEditableAuthors(authorsDraft)
        guard updatedAuthors != paper.authors else {
            authorsDraft = Paper.editableAuthorsText(updatedAuthors)
            isEditingAuthors = false
            focusedMetadataField = nil
            authorsSaveErrorMessage = nil
            return
        }

        let previousAuthors = paper.authors
        let previousModifiedAt = paper.modifiedAt
        paper.authors = updatedAuthors
        paper.modifiedAt = Date()

        do {
            try modelContext.save()
            authorsDraft = Paper.editableAuthorsText(updatedAuthors)
            isEditingAuthors = false
            focusedMetadataField = nil
            authorsSaveErrorMessage = nil
        } catch {
            modelContext.rollback()
            paper.authors = previousAuthors
            paper.modifiedAt = previousModifiedAt
            authorsDraft = Paper.editableAuthorsText(previousAuthors)
            authorsSaveErrorMessage = error.localizedDescription
            focusedMetadataField = .authors
        }
    }
    
    private func translateAbstract() {
        guard let paper = paper else { return }

        synchronizeAbstractPresentation(with: paper.id)
        abstractTranslationTask?.cancel()

        let paperID = paper.id
        let requestID = abstractTranslationState.beginTranslation(for: paperID)

        abstractTranslationTask = Task { @MainActor in
            do {
                let service = AbstractTranslationService()
                let settings = try modelContext.fetch(FetchDescriptor<AppSettings>()).first ?? AppSettings()
                
                let translated = try await service.translateAbstract(
                    paper: paper,
                    settings: settings,
                    modelContext: modelContext,
                    onProgress: nil
                )

                if abstractTranslationState.acceptTranslation(
                    translated,
                    paperID: paperID,
                    requestID: requestID
                ) {
                    abstractTranslationTask = nil
                }
            } catch {
                if abstractTranslationState.acceptFailure(
                    error.localizedDescription,
                    paperID: paperID,
                    requestID: requestID
                ) {
                    abstractTranslationTask = nil
                }
            }
        }
    }

    private func synchronizeAbstractPresentation(with paperID: UUID?) {
        guard abstractTranslationState.paperID != paperID else { return }

        abstractTranslationTask?.cancel()
        abstractTranslationTask = nil
        abstractTranslationState.selectPaper(paperID)
        isAbstractExpanded = false
    }

    private func cancelAbstractTranslation() {
        abstractTranslationTask?.cancel()
        abstractTranslationTask = nil
        abstractTranslationState.cancelActiveRequest()
    }

    private var emptyInspectorState: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {

                VStack(alignment: .leading, spacing: 8) {
                    Text("Paper details will appear here", bundle: bundle)
                        .font(.title3.weight(.semibold))
                    Text("Select or import a paper to view metadata, abstract, and notes in this panel.", bundle: bundle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
        }
        .scrollIndicators(.hidden)
        .fontDesign(displayAppearance == .paper ? .serif : .default)
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

struct AbstractTranslationPresentationState {
    private(set) var paperID: UUID?
    private(set) var activeRequestID: UUID?
    private(set) var isTranslating = false
    private(set) var translatedText: String?
    private(set) var errorMessage: String?

    mutating func selectPaper(_ paperID: UUID?) {
        self.paperID = paperID
        activeRequestID = nil
        isTranslating = false
        translatedText = nil
        errorMessage = nil
    }

    mutating func beginTranslation(for paperID: UUID) -> UUID {
        if self.paperID != paperID {
            selectPaper(paperID)
        }

        let requestID = UUID()
        activeRequestID = requestID
        isTranslating = true
        translatedText = nil
        errorMessage = nil
        return requestID
    }

    @discardableResult
    mutating func acceptTranslation(
        _ translatedText: String,
        paperID: UUID,
        requestID: UUID
    ) -> Bool {
        guard isCurrentRequest(paperID: paperID, requestID: requestID) else {
            return false
        }

        activeRequestID = nil
        isTranslating = false
        self.translatedText = translatedText
        errorMessage = nil
        return true
    }

    @discardableResult
    mutating func acceptFailure(
        _ errorMessage: String,
        paperID: UUID,
        requestID: UUID
    ) -> Bool {
        guard isCurrentRequest(paperID: paperID, requestID: requestID) else {
            return false
        }

        activeRequestID = nil
        isTranslating = false
        translatedText = nil
        self.errorMessage = errorMessage
        return true
    }

    mutating func showOriginal() {
        translatedText = nil
    }

    mutating func cancelActiveRequest() {
        activeRequestID = nil
        isTranslating = false
    }

    private func isCurrentRequest(paperID: UUID, requestID: UUID) -> Bool {
        self.paperID == paperID && activeRequestID == requestID
    }
}

private struct NoteEditor: View {
    @Environment(\.localizationBundle) private var bundle
    @Environment(\.pdfDisplayAppearance) private var displayAppearance
    @Bindable var note: Note
    let shouldFocus: Bool
    let onOpenAnchor: (() -> Void)?
    let onDelete: () -> Void
    let onFocusApplied: () -> Void
    @State private var isEditing = false
    @State private var isEditorFocusPending = false

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

            if let anchorSummary = noteAnchorSummary {
                HStack(spacing: 8) {
                    Label(anchorSummary, systemImage: note.pageIndex != nil ? "bookmark" : "text.alignleft")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let onOpenAnchor {
                        Button(action: onOpenAnchor) {
                            Text("Go to Selection", bundle: bundle)
                                .font(.caption.weight(.medium))
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            if let quote = note.trimmedQuote {
                Text(quote)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
            }

            if isEditing {
                InsetTextView(
                    text: Binding(
                        get: { note.body },
                        set: { newValue in
                            note.body = newValue
                            note.modifiedAt = Date()
                        }
                    ),
                    shouldFocus: shouldFocus || isEditorFocusPending,
                    onFocusApplied: handleEditorFocusApplied,
                    onEditingBegan: {
                        isEditing = true
                    },
                    onEditingEnded: {
                        isEditorFocusPending = false
                        isEditing = false
                    },
                    usesPaperTypography: displayAppearance == .paper
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

                if note.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                    notePreviewCard(isInteractive: false)
                }
            } else {
                notePreview
            }
        }
        .onAppear {
            if shouldFocus {
                beginEditing()
            }
        }
        .onChange(of: shouldFocus) { _, newValue in
            if newValue {
                beginEditing()
            }
        }
    }

    private var noteAnchorSummary: String? {
        if let pageIndex = note.pageIndex {
            return "\(String(localized: "Page", bundle: bundle)) \(pageIndex + 1)"
        }
        if note.normalizedHTMLSelector != nil {
            return String(localized: "HTML selection", bundle: bundle)
        }
        return nil
    }

    private var notePreview: some View {
        notePreviewCard(isInteractive: true)
    }

    private func notePreviewCard(isInteractive: Bool) -> some View {
        Group {
            notePreviewContent
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.08))
                .allowsHitTesting(false)
        }
        .modifier(NotePreviewInteractionModifier(isInteractive: isInteractive, beginEditing: beginEditing))
    }

    @ViewBuilder
    private var notePreviewContent: some View {
        if note.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            HStack {
                Text("Click to edit note", bundle: bundle)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 12)
        } else {
            NoteMarkdownPreviewView(markdown: note.body)
                .frame(minHeight: 72, maxHeight: 180)
        }
    }

    private func beginEditing() {
        isEditing = true
        isEditorFocusPending = true
    }

    private func handleEditorFocusApplied() {
        isEditorFocusPending = false
        onFocusApplied()
    }
}

private struct NotePreviewInteractionModifier: ViewModifier {
    let isInteractive: Bool
    let beginEditing: () -> Void

    func body(content: Content) -> some View {
        if isInteractive {
            content
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .onTapGesture {
                    beginEditing()
                }
        } else {
            content
        }
    }
}

private struct InsetTextView: NSViewRepresentable {
    @Binding var text: String
    var shouldFocus: Bool
    var onFocusApplied: () -> Void
    var onEditingBegan: () -> Void = {}
    var onEditingEnded: () -> Void = {}
    var usesPaperTypography = false

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            onFocusApplied: onFocusApplied,
            onEditingBegan: onEditingBegan,
            onEditingEnded: onEditingEnded
        )
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
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.smartInsertDeleteEnabled = false
        if #available(macOS 15.0, *) {
            textView.writingToolsBehavior = .none
        }
        textView.font = editorFont()
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
        context.coordinator.hostScrollView = nsView

        if textView.string != text {
            textView.string = text
        }

        textView.font = editorFont()

        context.coordinator.applyFocusIfNeeded(to: textView, shouldFocus: shouldFocus)
    }

    private func editorFont() -> NSFont {
        let size = NSFont.preferredFont(forTextStyle: .body).pointSize
        guard usesPaperTypography,
              let paperFont = NSFont(name: "New York", size: size) else {
            return .preferredFont(forTextStyle: .body)
        }
        return paperFont
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.stopOutsideClickMonitoring()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding private var text: String
        private let onFocusApplied: () -> Void
        private let onEditingBegan: () -> Void
        private let onEditingEnded: () -> Void
        private var hasAppliedFocus = false
        private var isFocusScheduled = false
        private var focusGeneration = 0
        weak var hostScrollView: NSScrollView?
        nonisolated(unsafe) private var outsideClickMonitor: Any?

        init(
            text: Binding<String>,
            onFocusApplied: @escaping () -> Void,
            onEditingBegan: @escaping () -> Void,
            onEditingEnded: @escaping () -> Void
        ) {
            _text = text
            self.onFocusApplied = onFocusApplied
            self.onEditingBegan = onEditingBegan
            self.onEditingEnded = onEditingEnded
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
        }

        func textDidBeginEditing(_ notification: Notification) {
            startOutsideClickMonitoring()
            onEditingBegan()
        }

        func textDidEndEditing(_ notification: Notification) {
            stopOutsideClickMonitoring()
            onEditingEnded()
        }

        func textShouldEndEditing(_ textObject: NSText) -> Bool {
            if let textView = textObject as? NSTextView {
                textView.unmarkText()
                textView.inputContext?.discardMarkedText()
            }
            return true
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
                    self.startOutsideClickMonitoring()
                    self.onFocusApplied()
                    return
                }

                if window.makeFirstResponder(textView) {
                    self.hasAppliedFocus = true
                    self.startOutsideClickMonitoring()
                    self.onFocusApplied()
                }
            }
        }

        private func startOutsideClickMonitoring() {
            guard outsideClickMonitor == nil else { return }

            outsideClickMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak self] event in
                let eventWindowNumber = event.windowNumber
                let pointInWindow = event.locationInWindow

                MainActor.assumeIsolated {
                    guard let self,
                          let scrollView = self.hostScrollView,
                          let window = scrollView.window,
                          eventWindowNumber == window.windowNumber else {
                        return
                    }

                    let pointInScrollView = scrollView.convert(pointInWindow, from: nil)
                    let isInsideEditor = scrollView.bounds.contains(pointInScrollView)

                    if !isInsideEditor {
                        window.makeFirstResponder(nil)
                    }
                }
                return event
            }
        }

        func stopOutsideClickMonitoring() {
            if let outsideClickMonitor {
                NSEvent.removeMonitor(outsideClickMonitor)
                self.outsideClickMonitor = nil
            }
        }

        deinit {
            if let outsideClickMonitor {
                NSEvent.removeMonitor(outsideClickMonitor)
            }
        }
    }
}
