import SwiftData
import SwiftUI

struct InspectorPaneView: View {
    @Environment(\.modelContext) private var modelContext
    var paper: Paper?
    var notes: [Note]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let paper {
                    metadataSection(paper)
                    notesSection(paper)
                } else {
                    ContentUnavailableView("No paper selected", systemImage: "sidebar.right")
                }
            }
            .padding(16)
        }
    }

    private func metadataSection(_ paper: Paper) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Metadata")
                .font(.headline)
            Text(paper.title)
                .font(.title3.weight(.semibold))
                .textSelection(.enabled)
            Text(paper.displayAuthors)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let arxivID = paper.arxivID {
                Text("arXiv: \(arxivID)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if !paper.abstractText.isEmpty {
                Text(paper.abstractText)
                    .font(.callout)
                    .textSelection(.enabled)
            }
        }
    }

    private func notesSection(_ paper: Paper) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Notes")
                    .font(.headline)
                Spacer()
                Button {
                    addNote(for: paper)
                } label: {
                    Label("Add Note", systemImage: "plus")
                }
            }

            if notes.isEmpty {
                Text("No notes yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(notes) { note in
                    NoteEditor(note: note)
                }
            }
        }
    }

    private func addNote(for paper: Paper) {
        modelContext.insert(Note(paperID: paper.id, body: ""))
        try? modelContext.save()
    }
}

private struct NoteEditor: View {
    @Bindable var note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: $note.body)
                .font(.body)
                .frame(minHeight: 90)
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.quaternary)
                }
            Text(note.modifiedAt, style: .date)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
