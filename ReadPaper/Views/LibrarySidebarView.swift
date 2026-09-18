import SwiftUI

struct LibrarySidebarView: View {
    @Environment(\.localizationBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.pdfDisplayAppearance) private var displayAppearance
    var papers: [Paper]
    var selectedPaper: Paper?
    @Binding var selectedPaperID: UUID?
    @Binding var isAddingPaper: Bool
    var onDeleteOffsets: (IndexSet) -> Void
    var onDeletePaper: (Paper) -> Void

    private var isPaperAppearance: Bool {
        displayAppearance == .paper
    }

    var body: some View {
        ZStack {
            // The detail column sits underneath the floating sidebar on macOS 26.
            // Keep this in the sidebar's content layer so reader surfaces cannot
            // be composited above it.
            sidebarBackground
                .ignoresSafeArea()

            VStack(spacing: 0) {
                if papers.isEmpty {
                    emptyLibraryState
                } else {
                    List(selection: $selectedPaperID) {
                        ForEach(papers) { paper in
                            PaperRowView(paper: paper)
                                .tag(paper.id)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selectedPaperID = paper.id
                                }
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
                    .listStyle(.sidebar)
                    .modifier(SidebarListBackgroundModifier())
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

            if #available(macOS 26.0, *) {
                ToolbarSpacer(.fixed)
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

    private var emptyLibraryState: some View {
        VStack(spacing: 26) {
            VStack(spacing: 16) {
                ZStack {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 30, weight: .medium))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(
                            isPaperAppearance
                                ? ReadPaperTheme.accentColor
                                : Color.accentColor
                        )
                }
                .frame(width: 72, height: 60)

                Text("No papers yet", bundle: bundle)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .multilineTextAlignment(.center)
            }

            emptyStateActions
        }
        .frame(maxWidth: 360)
        .padding(.horizontal, 32)
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    @ViewBuilder
    private var sidebarBackground: some View {
        if isPaperAppearance {
            ReadPaperAppearanceSurface(role: .library, textureOpacity: 0.52)
        } else {
            Color.clear
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var emptyStateActions: some View {
        if #available(macOS 26.0, *) {
            ReadPaperGlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    SettingsLink {
                        emptyStateActionLabel(String(localized: "Settings", bundle: bundle), systemImage: "gearshape")
                    }
                    .readPaperGlassButtonStyle()
                    .frame(maxWidth: .infinity)
                    .controlSize(.mini)

                    Button {
                        isAddingPaper = true
                    } label: {
                        emptyStateActionLabel(String(localized: "Add Paper", bundle: bundle), systemImage: "plus")
                    }
                    .readPaperGlassButtonStyle(prominent: true)
                    .frame(maxWidth: .infinity)
                    .controlSize(.mini)
                }
            }
            .frame(maxWidth: .infinity)
        } else {
            HStack(spacing: 0) {
                SettingsLink {
                    emptyStateActionLabel(String(localized: "Settings", bundle: bundle), systemImage: "gearshape")
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)

                Divider()
                    .frame(height: 18)

                Button {
                    isAddingPaper = true
                } label: {
                    emptyStateActionLabel(String(localized: "Add Paper", bundle: bundle), systemImage: "plus")
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
            }
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08))
            }
            .frame(maxWidth: .infinity)
        }
    }
}

private struct SidebarListBackgroundModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.scrollContentBackground(.hidden)
    }
}

private func emptyStateActionLabel(_ title: String, systemImage: String) -> some View {
    Label(title, systemImage: systemImage)
        .font(.subheadline.weight(.medium))
        .lineLimit(1)
        .minimumScaleFactor(0.9)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
}

private struct PaperRowView: View {
    var paper: Paper
    @Environment(\.pdfDisplayAppearance) private var displayAppearance

    private var titleDesign: Font.Design {
        displayAppearance == .paper
            ? .serif
            : .default
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(paper.title)
                .font(.system(.headline, design: titleDesign).weight(.semibold))
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
