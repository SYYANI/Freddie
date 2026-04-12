import SwiftUI

struct LibrarySidebarView: View {
    @Environment(\.localizationBundle) private var bundle
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
                    Label {
                        Text("No papers yet", bundle: bundle)
                    } icon: {
                        Image(systemName: "doc.text.magnifyingglass")
                    }
                } description: {
                    Text("Add an arXiv ID, arXiv URL, or a local PDF. Before using translation, open Settings and save at least one LLM provider API key and model profile.", bundle: bundle)
                } actions: {
                    HStack(spacing: 0) {
                        SettingsLink {
                            emptyStateActionLabel(String(localized: "Settings", bundle: bundle), systemImage: "gearshape")
                        }
                        .buttonStyle(.plain)

                        Divider()
                            .frame(height: 18)

                        Button {
                            isAddingPaper = true
                        } label: {
                            emptyStateActionLabel(String(localized: "First Paper", bundle: bundle), systemImage: "plus")
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
                                    Label(String(localized: "Delete Paper", bundle: bundle), systemImage: "trash")
                                }
                            }
                    }
                    .onDelete(perform: onDeleteOffsets)
                }
            }
        }
        .navigationTitle(String(localized: "Freddie", bundle: bundle))
        .toolbar {
            ToolbarItem {
                Button {
                    isAddingPaper = true
                } label: {
                    Label(String(localized: "Add Paper", bundle: bundle), systemImage: "plus")
                }
            }

            ToolbarItem {
                Button(role: .destructive) {
                    guard let selectedPaper else { return }
                    onDeletePaper(selectedPaper)
                } label: {
                    Label(String(localized: "Delete Paper", bundle: bundle), systemImage: "trash")
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
