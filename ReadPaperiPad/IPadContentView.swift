import SwiftData
import SwiftUI
import UIKit

struct IPadContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.localizationBundle) private var bundle
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.pdfDisplayAppearance) private var displayAppearance
    @Query(sort: \Paper.modifiedAt, order: .reverse) private var papers: [Paper]
    @Query(sort: \PaperAttachment.createdAt) private var attachments: [PaperAttachment]
    @Query(sort: \Note.modifiedAt, order: .reverse) private var notes: [Note]
    @Query private var folders: [PaperFolder]
    @Query private var folderMemberships: [PaperFolderMembership]
    @Query private var itemTypeAssignments: [PaperItemTypeAssignment]
    @AppStorage(InspectorMode.userDefaultsKey) private var inspectorModeRawValue = InspectorMode.paper.rawValue
    @Query private var settingsRows: [AppSettings]

    @State private var libraryFilter = PaperLibraryFilter()
    @State private var htmlTranslatedPaperIDs: Set<UUID> = []
    @State private var focusedNoteID: UUID?
    @State private var selectedPaperID: UUID?
    @State private var isAddingPaper = false
    @State private var isShowingSettings = false
    @AppStorage("ReadPaper.iPad.Sidebar.IsPresented") private var isShowingSidebar = true
    @AppStorage("ReadPaper.iPad.Inspector.IsPresented") private var isShowingInspector = true
    @State private var paperPendingDeletion: Paper?
    @State private var errorMessage: String?
    @State private var noteSelectionContext: NoteSelectionContext?
    @State private var noteNavigationRequest: NoteNavigationRequest?

    private var selectedPaper: Paper? {
        if let selectedPaperID,
           let paper = papers.first(where: { $0.id == selectedPaperID }) {
            return paper
        }
        return papers.first
    }

    private var selectedAttachments: [PaperAttachment] {
        attachments.filter { $0.paperID == selectedPaper?.id }
    }

    private var selectedNotes: [Note] {
        notes.filter { $0.paperID == selectedPaper?.id }
    }

    private var settings: AppSettings? { settingsRows.first }

    var body: some View {
        IPadSidebarContainer(
            isSidebarPresented: $isShowingSidebar,
            isInspectorPresented: $isShowingInspector,
            selection: selectedPaperID
        ) {
            NavigationStack { libraryColumn }
        } detail: {
            NavigationStack { reader }
        } inspector: {
            inspector
                .background(displayAppearance == .paper
                    ? ReadPaperTheme.surfaceColor(.inspector, scheme: .light)
                    : Color(uiColor: .secondarySystemBackground))
        }
        .sheet(isPresented: $isAddingPaper) {
            IPadAddPaperView(
                isPresented: $isAddingPaper,
                selectedPaperID: $selectedPaperID
            )
        }
        .fullScreenCover(isPresented: $isShowingSettings) {
            NavigationStack {
                IPadSettingsView()
            }
        }
        .confirmationDialog(
            String(localized: "Delete Paper?", bundle: bundle),
            isPresented: Binding(
                get: { paperPendingDeletion != nil },
                set: { if !$0 { paperPendingDeletion = nil } }
            ),
            presenting: paperPendingDeletion
        ) { paper in
            Button(String(localized: "Delete", bundle: bundle), role: .destructive) {
                deletePaper(paper)
            }
            Button(String(localized: "Cancel", bundle: bundle), role: .cancel) {}
        } message: { paper in
            let message = AppLocalization.format(
                "“%@” and all of its local files, notes, reading state, and translation cache will be removed.",
                bundle: bundle, paper.title
            )
            let count = WritingLibrary.shared.writings(citing: paper.id).count
            Text(count == 0 ? message : message + "\n\n" + AppLocalization.format(
                "Writings citing this paper: %lld. Their text stays, but its citations will no longer open the paper.",
                bundle: bundle, count
            ))
        }
        .alert(
            String(localized: "Error", bundle: bundle),
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button(String(localized: "OK", bundle: bundle), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .onAppear {
            _ = try? LLMConfigurationBootstrapper().ensureBootstrap(modelContext: modelContext)
            try? LLMDefaultProfileSeeder().ensureDefaults(modelContext: modelContext)
            WritingLibrary.shared.loadIfNeeded()
            restoreSelection()
            PaperSelectionStore.saveSelection(selectedPaperID)
        }
        .onChange(of: papers.map(\.id)) { _, _ in restoreSelection() }
        .onChange(of: selectedPaperID) { _, newValue in
            noteSelectionContext = nil
            focusedNoteID = nil
            if noteNavigationRequest?.paperID != newValue {
                noteNavigationRequest = nil
            }
            PaperSelectionStore.saveSelection(newValue)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                persistSelection(selectedPaperID)
                IPadWritingDocumentCenter.shared.saveAll()
            }
        }
    }

    private var itemTypes: PaperItemTypeResolution {
        PaperItemTypeResolution(papers: papers, attachments: attachments, assignments: itemTypeAssignments)
    }

    private var visibleGrouping: PaperLibraryGrouping {
        let grouping = PaperLibraryGrouping(papers: papers, folders: folders, memberships: folderMemberships)
        guard libraryFilter.isActive else { return grouping }
        let facts = PaperLibraryFilter.Facts(
            translatedPaperIDs: PaperLibraryFilter.translatedPaperIDs(
                attachments: attachments, htmlTranslatedPaperIDs: htmlTranslatedPaperIDs
            ),
            notedPaperIDs: Set(notes.map(\.paperID)),
            itemTypes: itemTypes
        )
        return grouping.filtered { $0.id == selectedPaper?.id || libraryFilter.matches($0, facts: facts) }
    }

    private var inspectorMode: Binding<InspectorMode> {
        Binding(
            get: { InspectorMode(rawValue: inspectorModeRawValue) ?? .paper },
            set: { inspectorModeRawValue = $0.rawValue }
        )
    }

    @ViewBuilder
    private var libraryColumn: some View {
        if #available(iOS 18.0, *), displayAppearance != .paper {
            sidebar.containerBackground(.ultraThinMaterial, for: .navigation)
        } else {
            sidebar
        }
    }

    private var sidebar: some View {
        LibrarySidebarView(
            papers: papers,
            grouping: visibleGrouping,
            itemTypes: itemTypes,
            filter: $libraryFilter,
            selectedPaper: selectedPaper,
            selectedPaperID: $selectedPaperID,
            isAddingPaper: $isAddingPaper,
            onDeletePaper: { paperPendingDeletion = $0 }
        )
        .equatable()
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { isShowingSettings = true } label: {
                    Label(String(localized: "Settings", bundle: bundle), systemImage: "gearshape")
                        .labelStyle(.iconOnly)
                }
            }
        }
        .task(id: HTMLTranslationLookupKey(
            isNeeded: libraryFilter.criteria.contains(.translated),
            selectedPaperID: selectedPaperID,
            paperCount: papers.count
        )) {
            guard libraryFilter.criteria.contains(.translated) else { return }
            do {
                htmlTranslatedPaperIDs = try PaperLibraryFilter.htmlTranslatedPaperIDs(modelContext: modelContext)
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private var reader: some View {
        IPadReaderPaneView(
            paper: selectedPaper,
            attachments: selectedAttachments,
            settings: settings,
            noteSelectionContext: $noteSelectionContext,
            noteNavigationRequest: $noteNavigationRequest,
            onToggleSidebar: { isShowingSidebar.toggle() },
            onToggleInspector: { isShowingInspector.toggle() }
        )
    }

    private var inspector: some View {
        InspectorPaneView(
            paper: selectedPaper,
            itemType: selectedPaper.map { itemTypes.selection(for: $0.id) },
            notes: selectedNotes,
            isCollapsed: false,
            currentSelectionContext: noteSelectionContext,
            focusedNoteID: $focusedNoteID,
            mode: inspectorMode,
            onCreateNote: createNote,
            onOpenNoteAnchor: { note in
                noteNavigationRequest = note.navigationRequest
                isShowingInspector = false
            },
            onOpenCitation: openCitation,
            onOpenWriting: { id in
                IPadWritingDocumentCenter.shared.saveAll()
                WritingLibrary.shared.selectWriting(id)
                inspectorMode.wrappedValue = .writing
            },
            onCreateWritingAboutPaper: createWriting,
            onQuoteInWriting: quoteInWriting
        )
    }

    private func createNote() {
        guard let paper = selectedPaper else { return }
        let note = Note(
            paperID: paper.id,
            attachmentID: noteSelectionContext?.attachmentID,
            quote: noteSelectionContext?.trimmedQuote ?? "",
            body: "",
            pageIndex: noteSelectionContext?.pageIndex,
            htmlSelector: noteSelectionContext?.htmlSelector
        )
        modelContext.insert(note)
        do {
            try modelContext.save()
            focusedNoteID = note.id
        } catch {
            modelContext.rollback()
            errorMessage = error.localizedDescription
        }
    }

    private func createWriting(about paper: Paper) {
        let label = PaperCitation.label(
            authors: paper.authors, title: paper.title,
            year: paper.publishedAt.map { Calendar(identifier: .gregorian).component(.year, from: $0) },
            pageIndex: nil
        )
        let heading = paper.title.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }.joined(separator: " ")
        do {
            IPadWritingDocumentCenter.shared.saveAll()
            try WritingLibrary.shared.createWriting(
                markdown: "# \(MarkdownEscaping.escapedInlineText(heading))\n\n"
                    + PaperCitation.inlineMarkdown(label: label, citation: PaperCitation(paperID: paper.id)) + "\n\n"
            )
            inspectorMode.wrappedValue = .writing
        } catch { errorMessage = error.localizedDescription }
    }

    private func openCitation(_ citation: PaperCitation, quote: String?) {
        guard papers.contains(where: { $0.id == citation.paperID }) else {
            errorMessage = String(localized: "The cited paper is no longer in your library.", bundle: bundle)
            return
        }
        selectedPaperID = citation.paperID
        noteNavigationRequest = citation.navigationRequest(quote: quote)
        isShowingInspector = false
    }

    private func quoteInWriting() {
        guard let paper = selectedPaper, let selection = noteSelectionContext,
              let quote = selection.trimmedQuote else { return }
        do {
            let center = IPadWritingDocumentCenter.shared
            center.saveAll()
            let library = center.library
            if library.currentWritingID == nil { try library.createWriting() }
            guard let id = library.currentWritingID else { return }
            let document = try center.document(for: id)
            let label = PaperCitation.label(
                authors: paper.authors, title: paper.title,
                year: paper.publishedAt.map { Calendar(identifier: .gregorian).component(.year, from: $0) },
                pageIndex: selection.pageIndex
            )
            let block = PaperCitation.quoteMarkdown(
                quote: quote, label: label, citation: PaperCitation(paperID: paper.id, selection: selection)
            )
            document.apply(WritingInsertion.block(block, in: document.markdown, at: document.selection.location))
            document.save()
            document.focusRequest += 1
            inspectorMode.wrappedValue = .writing
        } catch { errorMessage = error.localizedDescription }
    }

    private func restoreSelection() {
        let available = papers.map(\.id)
        let resolved = PaperSelectionStore.resolvedSelection(
            currentPaperID: selectedPaperID,
            savedPaperID: PaperSelectionStore.savedPaperID(settingsPaperID: settings?.lastOpenedPaperID),
            availablePaperIDs: available
        )
        if resolved != selectedPaperID { selectedPaperID = resolved }
    }

    private func persistSelection(_ paperID: UUID?) {
        guard let settings, settings.lastOpenedPaperID != paperID else { return }
        settings.lastOpenedPaperID = paperID
        settings.modifiedAt = Date()
        try? modelContext.save()
    }

    private func deletePaper(_ paper: Paper) {
        let orderedIDs = visibleGrouping.orderedPaperIDs
        let remainingIDs = orderedIDs.filter { $0 != paper.id }
        let index = min(orderedIDs.firstIndex(of: paper.id) ?? 0, max(0, remainingIDs.count - 1))
        let nextSelection = remainingIDs.isEmpty ? nil : remainingIDs[index]
        do {
            try PaperDeletionService().delete(paper, modelContext: modelContext)
            paperPendingDeletion = nil
            selectedPaperID = nextSelection
        } catch {
            paperPendingDeletion = nil
            errorMessage = error.localizedDescription
        }
    }
}

private struct HTMLTranslationLookupKey: Equatable {
    let isNeeded: Bool
    let selectedPaperID: UUID?
    let paperCount: Int
}
