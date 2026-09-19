import SwiftData
import SwiftUI

struct IPadInspectorPaneView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.localizationBundle) private var bundle
    let paper: Paper?
    let notes: [Note]
    let currentSelectionContext: NoteSelectionContext?
    let onOpenNoteAnchor: (Note) -> Void

    @State private var selectedNoteID: UUID?
    @State private var notePendingDeletion: Note?
    @State private var errorMessage: String?

    private var selectedNote: Note? {
        if let selectedNoteID,
           let note = notes.first(where: { $0.id == selectedNoteID }) {
            return note
        }
        return notes.first
    }

    var body: some View {
        Group {
            if let paper {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        metadata(paper)
                        Divider()
                        noteSection(paper)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ContentUnavailableView {
                    Label {
                        Text("No paper selected", bundle: bundle)
                    } icon: {
                        Image(systemName: "sidebar.right")
                    }
                }
            }
        }
        .background(Color(uiColor: .systemBackground))
        .confirmationDialog(
            String(localized: "Delete Note?", bundle: bundle),
            isPresented: Binding(
                get: { notePendingDeletion != nil },
                set: { if !$0 { notePendingDeletion = nil } }
            ),
            presenting: notePendingDeletion
        ) { note in
            Button(String(localized: "Delete", bundle: bundle), role: .destructive) {
                deleteNote(note)
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
        .onChange(of: paper?.id) { _, _ in selectedNoteID = nil }
        .onChange(of: notes.map(\.id)) { _, ids in
            if let selectedNoteID, !ids.contains(selectedNoteID) {
                self.selectedNoteID = ids.first
            }
        }
    }

    private func metadata(_ paper: Paper) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Metadata", bundle: bundle)
                .font(.headline)
            Text(paper.title)
                .font(.title3.weight(.semibold))
                .textSelection(.enabled)
            Text(paper.displayAuthors)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let identifier = paper.metadataIdentifierText {
                Text(identifier)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if !paper.abstractText.isEmpty {
                DisclosureGroup(String(localized: "Abstract", bundle: bundle)) {
                    Text(paper.abstractText)
                        .font(.callout)
                        .textSelection(.enabled)
                        .padding(.top, 6)
                }
            }
        }
    }

    private func noteSection(_ paper: Paper) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Notes", bundle: bundle)
                    .font(.headline)
                Spacer()
                Button {
                    createNote(for: paper)
                } label: {
                    Label(String(localized: "New Note", bundle: bundle), systemImage: "square.and.pencil")
                }
                .buttonStyle(.bordered)
            }

            if notes.isEmpty {
                Text("Create a note from the current PDF or HTML selection, or start a blank note.", bundle: bundle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Picker(String(localized: "Notes", bundle: bundle), selection: selectedNoteBinding) {
                    ForEach(notes) { note in
                        Text(noteTitle(note)).tag(Optional(note.id))
                    }
                }
                .pickerStyle(.menu)

                if let selectedNote {
                    IPadNoteEditor(
                        note: selectedNote,
                        onSave: save,
                        onOpenAnchor: { onOpenNoteAnchor(selectedNote) },
                        onDelete: { notePendingDeletion = selectedNote }
                    )
                }
            }
        }
    }

    private var selectedNoteBinding: Binding<UUID?> {
        Binding(
            get: { selectedNote?.id },
            set: { selectedNoteID = $0 }
        )
    }

    private func noteTitle(_ note: Note) -> String {
        let body = note.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty { return String(body.prefix(48)) }
        if let quote = note.trimmedQuote { return String(quote.prefix(48)) }
        return String(localized: "Untitled Note", bundle: bundle)
    }

    private func createNote(for paper: Paper) {
        let note = Note(
            paperID: paper.id,
            attachmentID: currentSelectionContext?.attachmentID,
            quote: currentSelectionContext?.trimmedQuote ?? "",
            body: "",
            pageIndex: currentSelectionContext?.pageIndex,
            htmlSelector: currentSelectionContext?.htmlSelector
        )
        modelContext.insert(note)
        do {
            try modelContext.save()
            selectedNoteID = note.id
        } catch {
            modelContext.rollback()
            errorMessage = error.localizedDescription
        }
    }

    private func save() {
        do {
            try modelContext.save()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteNote(_ note: Note) {
        modelContext.delete(note)
        do {
            try modelContext.save()
            notePendingDeletion = nil
            selectedNoteID = notes.first(where: { $0.id != note.id })?.id
        } catch {
            modelContext.rollback()
            errorMessage = error.localizedDescription
        }
    }
}

private struct IPadNoteEditor: View {
    @Environment(\.localizationBundle) private var bundle
    @Bindable var note: Note
    let onSave: () -> Void
    let onOpenAnchor: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let quote = note.trimmedQuote {
                Text(quote)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                    .textSelection(.enabled)
            }

            TextEditor(text: $note.body)
                .frame(minHeight: 180)
                .padding(6)
                .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(.separator.opacity(0.35))
                }
                .onChange(of: note.body) { _, _ in
                    note.modifiedAt = Date()
                }

            HStack {
                if note.hasAnchor {
                    Button(action: onOpenAnchor) {
                        Label(String(localized: "Open Anchor", bundle: bundle), systemImage: "scope")
                    }
                }
                Spacer()
                Button(String(localized: "Delete", bundle: bundle), role: .destructive, action: onDelete)
                Button(String(localized: "Save", bundle: bundle), action: onSave)
                    .buttonStyle(.borderedProminent)
            }
        }
        .onDisappear(perform: onSave)
    }
}
