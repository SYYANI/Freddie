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
                selectedPaperID: $selectedPaperID,
                isAddingPaper: $isAddingPaper
            )
        } detail: {
            HSplitView {
                ReaderPaneView(
                    paper: selectedPaper,
                    attachments: attachments.filter { $0.paperID == selectedPaper?.id },
                    settings: settingsRows.first,
                    readerMode: $readerMode,
                    displayMode: $displayMode
                )
                .frame(minWidth: 640)

                InspectorPaneView(
                    paper: selectedPaper,
                    notes: notes.filter { $0.paperID == selectedPaper?.id }
                )
                .frame(minWidth: 280, idealWidth: 340, maxWidth: 420)
            }
        }
        .sheet(isPresented: $isAddingPaper) {
            AddPaperSheet(isPresented: $isAddingPaper, selectedPaperID: $selectedPaperID)
                .frame(width: 520)
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
}
