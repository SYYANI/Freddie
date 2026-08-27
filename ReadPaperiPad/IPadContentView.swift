import SwiftData
import SwiftUI

struct IPadContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.localizationBundle) private var bundle
    @Query(sort: \Paper.modifiedAt, order: .reverse) private var papers: [Paper]
    @Query(sort: \PaperAttachment.createdAt) private var attachments: [PaperAttachment]
    @Query(sort: \Note.modifiedAt, order: .reverse) private var notes: [Note]
    @Query private var settingsRows: [AppSettings]

    @State private var selectedPaperID: UUID?
    @State private var isAddingPaper = false
    @State private var isShowingSettings = false
    @State private var isShowingInspector = false
    @State private var paperPendingDeletion: Paper?
    @State private var errorMessage: String?
    @State private var noteSelectionContext: NoteSelectionContext?
    @State private var noteNavigationRequest: NoteNavigationRequest?
    @State private var preferredCompactColumn: NavigationSplitViewColumn = .sidebar

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
        NavigationSplitView(preferredCompactColumn: $preferredCompactColumn) {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 270, max: 340)
        } detail: {
            reader
        }
        .navigationSplitViewStyle(.balanced)
        .inspector(isPresented: $isShowingInspector) {
            inspector
                .inspectorColumnWidth(min: 280, ideal: 340, max: 440)
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
            restoreSelection()
        }
        .onChange(of: papers.map(\.id)) { _, _ in restoreSelection() }
        .onChange(of: selectedPaperID) { _, newValue in
            noteSelectionContext = nil
            noteNavigationRequest = nil
            persistSelection(newValue)
            if newValue != nil {
                preferredCompactColumn = .detail
            }
        }
    }

    private var sidebar: some View {
        IPadLibrarySidebar(
            papers: papers,
            selectedPaperID: $selectedPaperID,
            onAdd: { isAddingPaper = true },
            onSettings: { isShowingSettings = true },
            onDelete: { paperPendingDeletion = $0 }
        )
    }

    private var reader: some View {
        IPadReaderPaneView(
            paper: selectedPaper,
            attachments: selectedAttachments,
            settings: settings,
            noteSelectionContext: $noteSelectionContext,
            noteNavigationRequest: $noteNavigationRequest,
            onToggleInspector: { isShowingInspector.toggle() }
        )
    }

    private var inspector: some View {
        IPadInspectorPaneView(
            paper: selectedPaper,
            notes: selectedNotes,
            currentSelectionContext: noteSelectionContext,
            onOpenNoteAnchor: { note in
                noteNavigationRequest = note.navigationRequest
                isShowingInspector = false
            }
        )
    }

    private func restoreSelection() {
        let available = papers.map(\.id)
        let resolved = PaperSelectionStore.resolvedSelection(
            currentPaperID: selectedPaperID,
            savedPaperID: settings?.lastOpenedPaperID,
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
        do {
            try PaperDeletionService().delete(paper, modelContext: modelContext)
            paperPendingDeletion = nil
            selectedPaperID = papers.first(where: { $0.id != paper.id })?.id
        } catch {
            paperPendingDeletion = nil
            errorMessage = error.localizedDescription
        }
    }
}

private struct IPadLibrarySidebar: View {
    @Environment(\.localizationBundle) private var bundle
    let papers: [Paper]
    @Binding var selectedPaperID: UUID?
    let onAdd: () -> Void
    let onSettings: () -> Void
    let onDelete: (Paper) -> Void

    var body: some View {
        Group {
            if papers.isEmpty {
                ContentUnavailableView {
                    Label {
                        Text("No papers yet", bundle: bundle)
                    } icon: {
                        Image(systemName: "doc.text.magnifyingglass")
                    }
                } description: {
                    Text("Add an arXiv ID, arXiv URL, web page URL, or a local PDF.", bundle: bundle)
                } actions: {
                    Button(action: onAdd) {
                        Label(String(localized: "First Paper", bundle: bundle), systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                List(papers, selection: $selectedPaperID) { paper in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(paper.title)
                            .font(.headline)
                            .lineLimit(2)
                        Text(paper.displayAuthors)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if let identifier = paper.sidebarIdentifierText {
                            Text(identifier)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .tag(paper.id)
                    .contextMenu {
                        Button(role: .destructive) { onDelete(paper) } label: {
                            Label(String(localized: "Delete Paper", bundle: bundle), systemImage: "trash")
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: onSettings) {
                    Label(String(localized: "Settings", bundle: bundle), systemImage: "gearshape")
                }
                Button(action: onAdd) {
                    Label(String(localized: "Add Paper", bundle: bundle), systemImage: "plus")
                }
            }
        }
    }
}
