import SwiftUI
import UniformTypeIdentifiers

struct LibrarySidebarView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.localizationBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.pdfDisplayAppearance) private var displayAppearance
    @AppStorage(LibraryFolderExpansion.userDefaultsKey) private var collapsedFolderIDsStorage = ""
    var papers: [Paper]
    var grouping: PaperLibraryGrouping
    var selectedPaper: Paper?
    @Binding var selectedPaperID: UUID?
    @Binding var isAddingPaper: Bool
    var onDeletePaper: (Paper) -> Void

    @State private var folderNamePrompt: FolderNamePrompt?
    @State private var folderNameDraft = ""
    @State private var folderPendingDeletion: PaperFolder?
    @State private var folderErrorMessage: String?
    @State private var dropTarget: FolderDropTarget?

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
                        if grouping.hasFolders {
                            Section {
                                ForEach(grouping.folderSections) { section in
                                    folderGroup(section)
                                }
                            }

                            Section {
                                paperRows(grouping.unfiledPapers)
                            } header: {
                                unfiledHeader
                            }
                        } else {
                            paperRows(papers)
                        }
                    }
                    .listStyle(.sidebar)
                    .modifier(SidebarListBackgroundModifier())
                }
            }
        }
        // A third toolbar item would overflow the sidebar at its minimum width,
        // so New Folder lives in the File menu and the list's context menus.
        .focusedSceneValue(
            \.newLibraryFolderAction,
            papers.isEmpty ? nil : NewLibraryFolderAction { promptForNewFolder(containing: nil) }
        )
        .onAppear(perform: revealSelectedPaper)
        .onChange(of: selectedPaperID) { _, _ in
            revealSelectedPaper()
        }
        .alert(
            folderNamePrompt?.title(bundle: bundle) ?? "",
            isPresented: Binding(
                get: { folderNamePrompt != nil },
                set: { isPresented in
                    if !isPresented {
                        folderNamePrompt = nil
                    }
                }
            ),
            presenting: folderNamePrompt
        ) { prompt in
            TextField(String(localized: "Folder Name", bundle: bundle), text: $folderNameDraft)
            Button(prompt.confirmTitle(bundle: bundle)) {
                commitFolderName(for: prompt)
            }
            .keyboardShortcut(.defaultAction)
            Button(String(localized: "Cancel", bundle: bundle), role: .cancel) {}
        }
        .confirmationDialog(
            String(localized: "Delete Folder?", bundle: bundle),
            isPresented: Binding(
                get: { folderPendingDeletion != nil },
                set: { isPresented in
                    if !isPresented {
                        folderPendingDeletion = nil
                    }
                }
            ),
            presenting: folderPendingDeletion
        ) { folder in
            Button(String(localized: "Delete", bundle: bundle), role: .destructive) {
                performFolderChange {
                    try PaperFolderService().delete(folder, modelContext: modelContext)
                }
                folderPendingDeletion = nil
            }
            Button(String(localized: "Cancel", bundle: bundle), role: .cancel) {}
        } message: { folder in
            Text(AppLocalization.format(
                "Papers in “%@” will move to Unfiled. No papers are deleted.",
                bundle: bundle,
                folder.name
            ))
        }
        .alert(String(localized: "Unable to Update Folder", bundle: bundle), isPresented: Binding(
            get: { folderErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    folderErrorMessage = nil
                }
            }
        )) {
            Button(String(localized: "OK", bundle: bundle), role: .cancel) {}
        } message: {
            Text(folderErrorMessage ?? "")
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

    private func paperRows(_ rowPapers: [Paper]) -> some View {
        ForEach(rowPapers) { paper in
            PaperRowView(paper: paper)
                .tag(paper.id)
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedPaperID = paper.id
                }
                .draggable(PaperDragItem(paperID: paper.id)) {
                    PaperRowView(paper: paper)
                        .frame(width: 240, alignment: .leading)
                        .padding(.horizontal, 10)
                }
                .contextMenu {
                    paperContextMenu(for: paper)
                }
        }
        .onDelete { offsets in
            guard let offset = offsets.first, rowPapers.indices.contains(offset) else { return }
            onDeletePaper(rowPapers[offset])
        }
    }

    @ViewBuilder
    private func paperContextMenu(for paper: Paper) -> some View {
        let currentFolderID = grouping.folderID(containing: paper.id)

        Menu {
            ForEach(grouping.folderSections) { section in
                Toggle(section.folder.name, isOn: Binding(
                    get: { currentFolderID == section.folder.id },
                    set: { isOn in
                        if isOn {
                            movePaper(paper.id, to: section.folder.id)
                        }
                    }
                ))
            }

            if grouping.hasFolders {
                Divider()
            }

            Button(String(localized: "New Folder…", bundle: bundle)) {
                promptForNewFolder(containing: paper.id)
            }
        } label: {
            Label(String(localized: "Move to Folder", bundle: bundle), systemImage: "folder")
        }

        if currentFolderID != nil {
            Button {
                movePaper(paper.id, to: nil)
            } label: {
                Label(String(localized: "Remove from Folder", bundle: bundle), systemImage: "folder.badge.minus")
            }
        }

        Divider()

        Button(role: .destructive) {
            onDeletePaper(paper)
        } label: {
            Label(String(localized: "Delete Paper", bundle: bundle), systemImage: "trash")
        }
    }

    private func folderGroup(_ section: PaperLibraryGrouping.FolderSection) -> some View {
        DisclosureGroup(isExpanded: expansionBinding(for: section.folder.id)) {
            if section.papers.isEmpty {
                Text("No Papers", bundle: bundle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                paperRows(section.papers)
            }
        } label: {
            Label(section.folder.name, systemImage: "folder")
                .lineLimit(1)
                .badge(section.papers.count)
                .dropTargetHighlight(isActive: dropTarget == .folder(section.folder.id))
                .dropDestination(for: PaperDragItem.self) { items, _ in
                    movePapers(items, to: section.folder.id)
                } isTargeted: { isTargeted in
                    updateDropTarget(.folder(section.folder.id), isTargeted: isTargeted)
                }
                .contextMenu {
                    Button(String(localized: "New Folder…", bundle: bundle)) {
                        promptForNewFolder(containing: nil)
                    }

                    Button(String(localized: "Rename Folder…", bundle: bundle)) {
                        folderNameDraft = section.folder.name
                        folderNamePrompt = .rename(section.folder)
                    }

                    Divider()

                    Button(role: .destructive) {
                        folderPendingDeletion = section.folder
                    } label: {
                        Label(String(localized: "Delete Folder…", bundle: bundle), systemImage: "trash")
                    }
                }
        }
    }

    private var unfiledHeader: some View {
        Text("Unfiled", bundle: bundle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .dropTargetHighlight(isActive: dropTarget == .unfiled)
            .dropDestination(for: PaperDragItem.self) { items, _ in
                movePapers(items, to: nil)
            } isTargeted: { isTargeted in
                updateDropTarget(.unfiled, isTargeted: isTargeted)
            }
    }

    private var collapsedFolderIDs: Set<UUID> {
        LibraryFolderExpansion.decode(collapsedFolderIDsStorage)
    }

    private func expansionBinding(for folderID: UUID) -> Binding<Bool> {
        Binding(
            get: { !collapsedFolderIDs.contains(folderID) },
            set: { isExpanded in
                setFolder(folderID, expanded: isExpanded)
            }
        )
    }

    private func setFolder(_ folderID: UUID, expanded isExpanded: Bool) {
        var collapsed = collapsedFolderIDs
        if isExpanded {
            collapsed.remove(folderID)
        } else {
            collapsed.insert(folderID)
        }
        collapsedFolderIDsStorage = LibraryFolderExpansion.encode(collapsed)
    }

    /// Keeps the selected paper visible when it is selected from outside the
    /// list (restore on launch, import) while its folder is collapsed.
    private func revealSelectedPaper() {
        guard let selectedPaperID,
              let folderID = grouping.folderID(containing: selectedPaperID),
              collapsedFolderIDs.contains(folderID)
        else {
            return
        }
        setFolder(folderID, expanded: true)
    }

    private func updateDropTarget(_ target: FolderDropTarget, isTargeted: Bool) {
        if isTargeted {
            dropTarget = target
        } else if dropTarget == target {
            dropTarget = nil
        }
    }

    private func promptForNewFolder(containing paperID: UUID?) {
        folderNameDraft = ""
        folderNamePrompt = .create(paperID: paperID)
    }

    private func commitFolderName(for prompt: FolderNamePrompt) {
        let name = folderNameDraft
        folderNamePrompt = nil
        performFolderChange {
            switch prompt {
            case .create(let paperID):
                try PaperFolderService().createFolder(
                    named: name,
                    containing: paperID,
                    modelContext: modelContext
                )
            case .rename(let folder):
                try PaperFolderService().rename(folder, to: name, modelContext: modelContext)
            }
        }
    }

    private func movePaper(_ paperID: UUID, to folderID: UUID?) {
        performFolderChange {
            try PaperFolderService().move(paperID: paperID, to: folderID, modelContext: modelContext)
        }
    }

    private func movePapers(_ items: [PaperDragItem], to folderID: UUID?) -> Bool {
        dropTarget = nil
        guard !items.isEmpty else { return false }
        for item in items {
            movePaper(item.paperID, to: folderID)
        }
        return true
    }

    private func performFolderChange(_ change: () throws -> Void) {
        do {
            try change()
        } catch {
            folderErrorMessage = error.localizedDescription
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

private enum FolderNamePrompt {
    case create(paperID: UUID?)
    case rename(PaperFolder)

    func title(bundle: Bundle) -> String {
        switch self {
        case .create:
            return String(localized: "New Folder", bundle: bundle)
        case .rename:
            return String(localized: "Rename Folder", bundle: bundle)
        }
    }

    func confirmTitle(bundle: Bundle) -> String {
        switch self {
        case .create:
            return String(localized: "Create", bundle: bundle)
        case .rename:
            return String(localized: "Rename", bundle: bundle)
        }
    }
}

struct NewLibraryFolderAction {
    let perform: @MainActor () -> Void
}

private struct NewLibraryFolderActionKey: FocusedValueKey {
    typealias Value = NewLibraryFolderAction
}

extension FocusedValues {
    var newLibraryFolderAction: NewLibraryFolderAction? {
        get { self[NewLibraryFolderActionKey.self] }
        set { self[NewLibraryFolderActionKey.self] = newValue }
    }
}

private enum FolderDropTarget: Equatable {
    case folder(UUID)
    case unfiled
}

/// Collapsed folders, stored as view state in UserDefaults rather than SwiftData.
enum LibraryFolderExpansion {
    static let userDefaultsKey = "ReadPaper.Library.CollapsedFolderIDs"

    static func decode(_ storage: String) -> Set<UUID> {
        Set(storage.split(separator: "\n").compactMap { UUID(uuidString: String($0)) })
    }

    static func encode(_ folderIDs: Set<UUID>) -> String {
        folderIDs.map(\.uuidString).sorted().joined(separator: "\n")
    }
}

extension UTType {
    /// In-app drag of a library paper. Deliberately not a file URL, so the
    /// window-wide PDF drop catcher never claims it.
    static let readPaperPaperReference = UTType(exportedAs: "com.yiyan.ReadPaper.paper-reference")
}

struct PaperDragItem: Codable, Transferable {
    let paperID: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .readPaperPaperReference)
    }
}

private extension View {
    func dropTargetHighlight(isActive: Bool) -> some View {
        padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor.opacity(isActive ? 0.22 : 0))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(isActive ? 0.7 : 0), lineWidth: 1.5)
            }
            .padding(.horizontal, -4)
            .padding(.vertical, -2)
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
