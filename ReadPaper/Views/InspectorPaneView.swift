import SwiftData
import SwiftUI

struct InspectorPaneView: View {
    @Environment(\.modelContext) private var modelContext
    var paper: Paper?
    var notes: [Note]

    var body: some View {
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var paneHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("INSPECTOR")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(1.1)

            if let paper {
                Text(paper.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                Text("Paper details, abstract, and notes")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
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

    private var emptyInspectorState: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("INSPECTOR")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .tracking(1.1)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Paper details will appear here")
                        .font(.title3.weight(.semibold))
                    Text("Select or import a paper to view metadata, abstract, and notes in this panel.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 12) {
                    inspectorHintRow(
                        title: "Metadata",
                        systemImage: "text.document",
                        description: "Title, authors, arXiv ID, and abstract."
                    )
                    inspectorHintRow(
                        title: "Notes",
                        systemImage: "note.text",
                        description: "Quick reading notes stay attached to the current paper."
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
