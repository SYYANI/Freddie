import SwiftUI

struct LibrarySidebarView: View {
    var papers: [Paper]
    @Binding var selectedPaperID: UUID?
    @Binding var isAddingPaper: Bool

    var body: some View {
        VStack(spacing: 0) {
            if papers.isEmpty {
                ContentUnavailableView(
                    "No papers yet",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Add an arXiv ID, arXiv URL, or a local PDF.")
                )
                .padding()
            } else {
                List(selection: $selectedPaperID) {
                    ForEach(papers) { paper in
                        PaperRowView(paper: paper)
                            .tag(paper.id)
                    }
                }
            }
        }
        .navigationTitle("ReadPaper")
        .toolbar {
            ToolbarItem {
                Button {
                    isAddingPaper = true
                } label: {
                    Label("Add Paper", systemImage: "plus")
                }
            }
        }
    }
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
            if let arxivID = paper.arxivID {
                Text("arXiv \(arxivID)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
