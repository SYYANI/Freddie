import SwiftUI

/// Which view the inspector shows: the selected paper's details, or the writing that
/// stays open across papers.
enum InspectorMode: String {
    case paper
    case writing

    static let userDefaultsKey = "ReadPaper.Inspector.Mode"
}

/// The writings citing a paper, listed in the inspector's Paper tab.
struct PaperWritingsSection: View {
    @Environment(\.localizationBundle) private var bundle
    var library: WritingLibrary = .shared
    let paperID: UUID
    var onOpenWriting: (UUID) -> Void
    var onCreateWriting: () -> Void

    var body: some View {
        let writings = library.writings(citing: paperID)
        VStack(alignment: .leading, spacing: 10) {
            InspectorSectionHeader(title: String(localized: "Writings", bundle: bundle)) {
                InspectorIconButton(
                    title: String(localized: "New Writing About This Paper", bundle: bundle),
                    systemImage: "square.and.pencil"
                ) {
                    onCreateWriting()
                }
            }

            if writings.isEmpty {
                Text("No writings cite this paper yet.", bundle: bundle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(writings) { writing in
                    Button {
                        onOpenWriting(writing.id)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "doc.text")
                                .foregroundStyle(.secondary)
                            Text(writing.title.isEmpty ? String(localized: "Untitled Writing", bundle: bundle) : writing.title)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 8)
                            Text(writing.modifiedAt.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    #if os(macOS)
                    .help(
                        WritingWindowState.shared.isOpen
                            ? String(localized: "Open in the Writing Window", bundle: bundle)
                            : String(localized: "Open in the Writing Tab", bundle: bundle)
                    )
                    #endif
                }
            }
        }
        .onAppear {
            library.loadIfNeeded()
        }
    }
}

