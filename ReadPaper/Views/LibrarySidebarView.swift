import SwiftUI

struct LibrarySidebarView: View {
    var papers: [Paper]
    var selectedPaper: Paper?
    @Binding var selectedPaperID: UUID?
    @Binding var isAddingPaper: Bool
    var onDeleteOffsets: (IndexSet) -> Void
    var onDeletePaper: (Paper) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if papers.isEmpty {
                ContentUnavailableView {
                    Label("No papers yet", systemImage: "doc.text.magnifyingglass")
                } description: {
                    Text("Add an arXiv ID, arXiv URL, or a local PDF. Before using translation, open Settings and save at least one LLM provider API key and model profile.")
                } actions: {
                    HStack(spacing: 0) {
                        SettingsLink {
                            emptyStateActionLabel("Settings", systemImage: "gearshape")
                        }
                        .buttonStyle(.plain)

                        Divider()
                            .frame(height: 18)

                        Button {
                            isAddingPaper = true
                        } label: {
                            emptyStateActionLabel("First Paper", systemImage: "plus")
                        }
                        .buttonStyle(.plain)
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08))
                    }
                    .frame(minWidth: 280)
                }
                .padding()
            } else {
                List(selection: $selectedPaperID) {
                    ForEach(papers) { paper in
                        PaperRowView(paper: paper)
                            .tag(paper.id)
                            .contextMenu {
                                Button(role: .destructive) {
                                    onDeletePaper(paper)
                                } label: {
                                    Label("Delete Paper", systemImage: "trash")
                                }
                            }
                    }
                    .onDelete(perform: onDeleteOffsets)
                }
            }
        }
        .navigationTitle("Freddie")
        .toolbar {
            ToolbarItem {
                Button {
                    isAddingPaper = true
                } label: {
                    Label("Add Paper", systemImage: "plus")
                }
            }

            ToolbarItem {
                Button(role: .destructive) {
                    guard let selectedPaper else { return }
                    onDeletePaper(selectedPaper)
                } label: {
                    Label("Delete Paper", systemImage: "trash")
                }
                .disabled(selectedPaper == nil)
            }
        }
    }
}

private func emptyStateActionLabel(_ title: String, systemImage: String) -> some View {
    Label(title, systemImage: systemImage)
        .font(.subheadline.weight(.medium))
        .lineLimit(1)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
}

private struct PaperRowView: View {
    var paper: Paper

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(paper.title)
                .font(.headline)
                .lineLimit(2)
            Text(paper.displayAuthors)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let identifierText = paper.sidebarIdentifierText {
                Text(identifierText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
