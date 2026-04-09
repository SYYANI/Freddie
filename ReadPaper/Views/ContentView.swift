import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Paper.modifiedAt, order: .reverse) private var papers: [Paper]
    @Query(sort: \PaperAttachment.createdAt) private var attachments: [PaperAttachment]
    @Query(sort: \Note.modifiedAt, order: .reverse) private var notes: [Note]
    @Query private var settingsRows: [AppSettings]

    @State private var selectedPaperID: UUID?
    @State private var readerMode: ReaderMode = .html
    @State private var displayMode: TranslationDisplayMode = .bilingual
    @State private var isAddingPaper = false
    @State private var paperPendingDeletion: Paper?
    @State private var deletionErrorMessage: String?

    private var selectedPaper: Paper? {
        if let selectedPaperID, let paper = papers.first(where: { $0.id == selectedPaperID }) {
            return paper
        }
        return papers.first
    }

    var body: some View {
        NavigationSplitView {
            LibrarySidebarView(
                papers: papers,
                selectedPaper: selectedPaper,
                selectedPaperID: $selectedPaperID,
                isAddingPaper: $isAddingPaper,
                onDeleteOffsets: confirmDeletion(at:),
                onDeletePaper: requestDeletion(of:)
            )
            .navigationSplitViewColumnWidth(min: 240, ideal: 260, max: 340)
        } content: {
            ReaderPaneView(
                paper: selectedPaper,
                attachments: attachments.filter { $0.paperID == selectedPaper?.id },
                settings: settingsRows.first,
                readerMode: $readerMode,
                displayMode: $displayMode
            )
        } detail: {
            InspectorPaneView(
                paper: selectedPaper,
                notes: notes.filter { $0.paperID == selectedPaper?.id }
            )
            .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 420)
        }
        .sheet(isPresented: $isAddingPaper) {
            AddPaperSheet(isPresented: $isAddingPaper, selectedPaperID: $selectedPaperID)
                .frame(width: 520)
        }
        .confirmationDialog(
            "Delete Paper?",
            isPresented: Binding(
                get: { paperPendingDeletion != nil },
                set: { isPresented in
                    if !isPresented {
                        paperPendingDeletion = nil
                    }
                }
            ),
            presenting: paperPendingDeletion
        ) { paper in
            Button("Delete", role: .destructive) {
                deletePaper(paper)
            }
            Button("Cancel", role: .cancel) {}
        } message: { paper in
            Text("“\(paper.title)” and all of its local files, notes, reading state, and translation cache will be removed.")
        }
        .alert("Unable to Delete Paper", isPresented: Binding(
            get: { deletionErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    deletionErrorMessage = nil
                }
            }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deletionErrorMessage ?? "")
        }
        .onAppear {
            ensureSettings()
            if selectedPaperID == nil {
                selectedPaperID = papers.first?.id
            }
        }
    }

    private func ensureSettings() {
        guard settingsRows.isEmpty else { return }
        modelContext.insert(AppSettings())
        try? modelContext.save()
    }

    private func confirmDeletion(at offsets: IndexSet) {
        guard let offset = offsets.first, papers.indices.contains(offset) else { return }
        requestDeletion(of: papers[offset])
    }

    private func requestDeletion(of paper: Paper) {
        paperPendingDeletion = paper
    }

    private func deletePaper(_ paper: Paper) {
        let nextSelection = nextSelectionAfterDeletingPaper(withID: paper.id)

        do {
            try PaperDeletionService().delete(paper, modelContext: modelContext)
            selectedPaperID = nextSelection
            paperPendingDeletion = nil
        } catch {
            paperPendingDeletion = nil
            deletionErrorMessage = error.localizedDescription
        }
    }

    private func nextSelectionAfterDeletingPaper(withID paperID: UUID) -> UUID? {
        let remainingPapers = papers.filter { $0.id != paperID }
        guard !remainingPapers.isEmpty else { return nil }

        guard let deletedIndex = papers.firstIndex(where: { $0.id == paperID }) else {
            return remainingPapers.first?.id
        }

        let nextIndex = min(deletedIndex, remainingPapers.count - 1)
        return remainingPapers[nextIndex].id
    }
}
