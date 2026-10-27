#if os(macOS)
import AppKit
#endif
import SwiftData
import SwiftUI

/// Keep metadata compact in the iPad's narrow inspector while retaining Dynamic Type.
private enum InspectorTypography {
    #if os(iOS)
    static let title: Font = .headline
    static let authors: Font = .subheadline
    static let abstract: Font = .footnote
    static let section: Font = .footnote.weight(.semibold)
    static let abstractPreviewLines = 5
    #else
    static let title: Font = .title3.weight(.semibold)
    static let authors: Font = .body
    static let abstract: Font = .callout
    static let section: Font = .subheadline.weight(.semibold)
    static let abstractPreviewLines = 8
    #endif
}

struct InspectorPaneView: View {
    private enum MetadataField: Hashable {
        case authors
    }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.localizationBundle) private var bundle
    @Environment(\.pdfDisplayAppearance) private var displayAppearance
    @Query private var summarySettings: [AppSettings]
    @State private var abstractContent: PaperAbstractContent = .hidden
    @State private var abstractContentRequest: SummaryRequest?
    @State private var notePendingDeletion: Note?
    @State private var authorsSaveErrorMessage: String?
    @State private var itemTypeSaveErrorMessage: String?
    @State private var isAbstractExpanded = false
    @State private var abstractTranslationState = AbstractTranslationPresentationState()
    @State private var abstractTranslationTask: Task<Void, Never>?
    @State private var isEditingAuthors = false
    @State private var authorsDraft = ""
    @FocusState private var focusedMetadataField: MetadataField?
    var paper: Paper?
    var itemType: PaperItemTypeSelection?
    var notes: [Note]
    var isCollapsed: Bool
    var currentSelectionContext: NoteSelectionContext?
    @Binding var focusedNoteID: UUID?
    @Binding var mode: InspectorMode
    #if os(macOS)
    var writingCenter: WritingDocumentCenter = .shared
    private var writingLibrary: WritingLibrary { writingCenter.library }
    #else
    var writingLibrary: WritingLibrary = .shared
    #endif
    var onCreateNote: () -> Void
    var onOpenNoteAnchor: (Note) -> Void
    var onOpenCitation: (PaperCitation, String?) -> Void
    var onOpenWriting: (UUID) -> Void
    var onCreateWritingAboutPaper: (Paper) -> Void
    var onQuoteInWriting: (() -> Void)? = nil

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
        .task(id: summaryRequest) {
            await prepareAbstract()
        }
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
        .noteDeletionConfirmation($notePendingDeletion) { note in
            if focusedNoteID == note.id {
                focusedNoteID = nil
            }
        }
    }

    private var expandedInspectorPane: some View {
        VStack(spacing: 0) {
            modePicker
            switch mode {
            case .paper:
                if let paper {
                    // Flat sections split by dividers, like the Writing tab: no cards.
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            metadataSection(paper)
                                .padding(16)
                            Divider()
                            notesSection()
                                .padding(16)
                            Divider()
                            PaperWritingsSection(
                                library: writingLibrary,
                                paperID: paper.id,
                                onOpenWriting: onOpenWriting,
                                onCreateWriting: { onCreateWritingAboutPaper(paper) }
                            )
                            .padding(16)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    emptyInspectorState
                }
            case .writing:
                #if os(macOS)
                WritingPaneView(
                    center: writingCenter,
                    focusRequest: 0,
                    onOpenCitation: onOpenCitation
                )
                #else
                IPadWritingPaneView(library: writingLibrary, onOpenCitation: onOpenCitation)
                #endif
            }
        }
        .fontDesign(displayAppearance == .paper ? .serif : .default)
    }

    private var modePicker: some View {
        ReadPaperSegmentedPicker(
            label: String(localized: "Inspector", bundle: bundle),
            selection: $mode,
            options: [
                .init(value: .paper, title: String(localized: "Paper", bundle: bundle)),
                .init(value: .writing, title: String(localized: "Writing", bundle: bundle)),
            ]
        )
        .frame(maxWidth: .infinity)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private func metadataSection(_ paper: Paper) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let itemType {
                PaperItemTypePicker(selection: itemType) { newItemType in
                    setItemType(newItemType, for: paper, selection: itemType)
                }
            }
            Text(paper.title)
                .font(InspectorTypography.title)
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
            if let itemTypeSaveErrorMessage {
                Text(itemTypeSaveErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if abstractContentRequest == summaryRequest {
                switch abstractContent {
                case .hidden:
                    EmptyView()
                case .original(let text):
                    abstractView(text)
                case .summary(let text):
                    abstractView(text, isSummary: true)
                }
            }
        }
    }

    @ViewBuilder
    private func authorsView(for paper: Paper) -> some View {
        if isEditingAuthors {
            TextField("", text: $authorsDraft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(InspectorTypography.authors)
                .foregroundStyle(.secondary)
                .lineLimit(1...3)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .readPaperFieldWell(isFocused: focusedMetadataField == .authors)
                .focused($focusedMetadataField, equals: .authors)
                .onSubmit {
                    commitAuthorsEdits(for: paper)
                }
                .onChange(of: focusedMetadataField) { _, newValue in
                    if newValue != .authors, isEditingAuthors {
                        commitAuthorsEdits(for: paper)
                    }
                }
                #if os(macOS)
                .onExitCommand {
                    cancelAuthorsEditing(for: paper)
                }
                #endif
        } else {
            Button {
                beginAuthorsEditing(for: paper)
            } label: {
                Text(paper.displayAuthors)
                    .font(InspectorTypography.authors)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
    
    private func abstractView(_ abstractText: String, isSummary: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            InspectorSectionHeader(title: String(localized: "Abstract", bundle: bundle)) {
                if !isSummary && abstractTranslationState.translatedText != nil {
                    InspectorIconButton(
                        title: String(localized: "Original", bundle: bundle),
                        systemImage: "arrow.uturn.backward"
                    ) {
                        abstractTranslationState.showOriginal()
                    }
                } else if !isSummary && !abstractTranslationState.isTranslating {
                    InspectorIconButton(
                        title: String(localized: "Translate", bundle: bundle),
                        systemImage: "character.book.closed"
                    ) {
                        translateAbstract()
                    }
                }

                InspectorIconButton(
                    title: isAbstractExpanded
                        ? String(localized: "Less", bundle: bundle)
                        : String(localized: "More", bundle: bundle),
                    systemImage: isAbstractExpanded ? "chevron.up" : "chevron.down"
                ) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isAbstractExpanded.toggle()
                    }
                }
            }

            if !isSummary, let error = abstractTranslationState.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if !isSummary && abstractTranslationState.isTranslating {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(String(localized: "Translating abstract...", bundle: bundle))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            } else {
                Text(isSummary ? abstractText : (abstractTranslationState.translatedText ?? abstractText))
                    .font(InspectorTypography.abstract)
                    .textSelection(.enabled)
                    .lineLimit(isAbstractExpanded ? nil : InspectorTypography.abstractPreviewLines)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // macOS can draw the full selectable text on double-click,
                    // even while lineLimit reserves only the collapsed preview's height.
                    .clipped()
            }
        }
        .padding(.top, 8)
    }

    private func notesSection() -> some View {
        VStack(alignment: .leading, spacing: 10) {
            InspectorSectionHeader(title: String(localized: "Notes", bundle: bundle)) {
                if currentSelectionContext != nil, let onQuoteInWriting {
                    InspectorIconButton(
                        title: String(localized: "Quote in Writing", bundle: bundle),
                        systemImage: "text.quote"
                    ) {
                        onQuoteInWriting()
                    }
                }
                InspectorIconButton(
                    title: currentSelectionContext != nil
                        ? String(localized: "Add Note to Current Selection", bundle: bundle)
                        : String(localized: "Add Note", bundle: bundle),
                    systemImage: "plus"
                ) {
                    onCreateNote()
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

    private func setItemType(_ newItemType: PaperItemType?, for paper: Paper, selection: PaperItemTypeSelection) {
        do {
            try PaperItemTypeService().setItemType(
                newItemType,
                for: paper.id,
                detectedType: selection.detectedType,
                modelContext: modelContext
            )
            itemTypeSaveErrorMessage = nil
        } catch {
            itemTypeSaveErrorMessage = error.localizedDescription
        }
    }

    private func syncMetadataEditorState(with paper: Paper?) {
        authorsSaveErrorMessage = nil
        itemTypeSaveErrorMessage = nil
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
    
    private struct SummaryRequest: Equatable {
        var paperID: UUID?
        var title: String?
        var abstractText: String?
        var targetLanguage: String?
        var htmlModelID: UUID?
        var pdfModelID: UUID?
        var settingsModifiedAt: Date?
        var isVisible: Bool
    }

    private var summaryRequest: SummaryRequest {
        let settings = summarySettings.first
        return SummaryRequest(
            paperID: paper?.id,
            title: paper?.title,
            abstractText: paper?.abstractText,
            targetLanguage: settings?.targetLanguage,
            htmlModelID: settings?.selectedHTMLModelProfileID,
            pdfModelID: settings?.selectedPDFModelProfileID,
            settingsModifiedAt: settings?.modifiedAt,
            isVisible: !isCollapsed && mode == .paper
        )
    }

    private func prepareAbstract() async {
        guard !Task.isCancelled else { return }
        abstractContent = .hidden
        abstractContentRequest = nil
        cancelAbstractTranslation()
        guard summaryRequest.isVisible, let paper else { return }
        let request = summaryRequest
        do {
            let content = try await PaperSummaryService().content(
                for: paper,
                settings: summarySettings.first ?? AppSettings(),
                modelContext: modelContext
            )
            guard !Task.isCancelled, summaryRequest == request else { return }
            abstractContent = content
            abstractContentRequest = request
        } catch {
            // Summaries are optional; unavailable models do not block reading.
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
        VStack(spacing: 14) {
            Image(systemName: "doc.text")
                .font(.system(size: 32, weight: .regular))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)

            Text("No Paper Selected", bundle: bundle)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

/// A section title in the inspector's Paper tab, with its actions as icon buttons on the
/// trailing edge, the way the Writing tab's header keeps its controls.
struct InspectorSectionHeader<Actions: View>: View {
    let title: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(InspectorTypography.section)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            actions
        }
        .frame(minHeight: 22)
    }
}

struct InspectorIconButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .help(title)
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

/// Confirms and performs deletion of a note; shared by the inspector and the HTML margin notes.
private struct NoteDeletionConfirmation: ViewModifier {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.localizationBundle) private var bundle
    @Binding var note: Note?
    let willDelete: (Note) -> Void
    @State private var errorMessage: String?

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                String(localized: "Delete Note?", bundle: bundle),
                isPresented: Binding(
                    get: { note != nil },
                    set: { isPresented in
                        if !isPresented {
                            note = nil
                        }
                    }
                ),
                presenting: note
            ) { note in
                Button(String(localized: "Delete", bundle: bundle), role: .destructive) {
                    delete(note)
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
                    get: { errorMessage != nil },
                    set: { isPresented in
                        if !isPresented {
                            errorMessage = nil
                        }
                    }
                )
            ) {
                Button(String(localized: "OK", bundle: bundle), role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
    }

    private func delete(_ note: Note) {
        willDelete(note)
        modelContext.delete(note)

        do {
            try modelContext.save()
            self.note = nil
        } catch {
            modelContext.rollback()
            self.note = nil
            errorMessage = error.localizedDescription
        }
    }
}

extension View {
    func noteDeletionConfirmation(
        _ note: Binding<Note?>,
        willDelete: @escaping (Note) -> Void = { _ in }
    ) -> some View {
        modifier(NoteDeletionConfirmation(note: note, willDelete: willDelete))
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
                    .padding(.leading, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(Color.secondary.opacity(0.35))
                            .frame(width: 2)
                    }
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
                    .readPaperFieldWell(isFocused: isEditing)

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

    private var noteBackground: Color {
        #if os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color(uiColor: .secondarySystemBackground)
        #endif
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
                .fill(noteBackground)
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

#if os(macOS)
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

#endif

/// The paper's item type above its title; choosing another type is the only
/// place to change it. Kept out of the library rows' context menus on purpose:
/// SwiftUI builds those menus for every visible row on every sidebar update,
/// and a 37-type submenu per row made each update about five times slower.
private struct PaperItemTypePicker: View {
    @Environment(\.localizationBundle) private var bundle
    var selection: PaperItemTypeSelection
    var onSelect: (PaperItemType?) -> Void

    var body: some View {
        let title = selection.itemType.title(bundle: bundle)

        Menu {
            ForEach(PaperItemType.common) { itemType in
                toggle(itemType, title: itemType.title(bundle: bundle))
            }

            Menu(String(localized: "More Types", bundle: bundle)) {
                let otherTypes = PaperItemType.allCases.filter { !PaperItemType.common.contains($0) }
                ForEach(PaperItemType.sortedByTitle(otherTypes, bundle: bundle), id: \.itemType) { entry in
                    toggle(entry.itemType, title: entry.title)
                }
            }

            if selection.isAssigned {
                Divider()

                Button(AppLocalization.format(
                    "Use Detected Type (%@)",
                    bundle: bundle,
                    selection.detectedType.title(bundle: bundle)
                )) {
                    onSelect(nil)
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(title)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(String(localized: "Item Type", bundle: bundle))
        .accessibilityLabel(String(localized: "Item Type", bundle: bundle))
        .accessibilityValue(title)
    }

    private func toggle(_ itemType: PaperItemType, title: String) -> some View {
        Toggle(title, isOn: Binding(
            get: { selection.itemType == itemType },
            set: { isOn in
                if isOn {
                    onSelect(itemType)
                }
            }
        ))
    }
}
