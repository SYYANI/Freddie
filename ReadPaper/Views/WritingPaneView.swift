import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Which view the inspector shows: the selected paper's details, or the writing that
/// stays open across papers.
enum InspectorMode: String {
    case paper
    case writing

    static let userDefaultsKey = "ReadPaper.Inspector.Mode"
}

enum WritingPanePresentation {
    /// The inspector's Writing tab.
    case inspector
    /// The separate writing window.
    case window
}

/// One long Markdown writing that can cite any paper, in the inspector's Writing tab or the
/// separate writing window.
struct WritingPaneView: View {
    @Environment(\.localizationBundle) private var bundle
    @Environment(\.pdfDisplayAppearance) private var displayAppearance
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    var center: WritingDocumentCenter = .shared
    var presentation: WritingPanePresentation = .inspector
    var windowState: WritingWindowState = .shared
    /// Changing it moves keyboard focus into the editor.
    var focusRequest: Int
    var onOpenCitation: (PaperCitation, String?) -> Void

    @State private var localFocusRequest = 0
    @State private var writingPendingDeletion: WritingMetadata?
    @State private var writingBeingRenamed: WritingMetadata?
    @State private var newTitle = ""
    @State private var errorMessage: String?

    private var library: WritingLibrary {
        center.library
    }

    private var typography: WritingTypography {
        WritingTypography(usesPaperAppearance: displayAppearance == .paper)
    }

    /// The inspector steps aside while the writing window is open.
    private var showsWindowPlaceholder: Bool {
        presentation == .inspector && windowState.isOpen
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsWindowPlaceholder {
                windowPlaceholder
            } else if let writing = library.currentWriting {
                // The writing window shows these controls in its title bar.
                if presentation == .inspector {
                    header(writing)
                    Divider()
                }
                if let document = try? center.document(for: writing.id) {
                    WritingEditorView(
                        document: document,
                        typography: typography,
                        focusRequest: focusRequest &+ localFocusRequest,
                        maximumTextWidth: presentation == .window ? WritingWindowScene.maximumTextWidth : nil,
                        onOpenLink: { link in
                            open(link, in: document)
                        },
                        onImageError: { error in
                            errorMessage = AppLocalization.format(
                                "Unable to add the image: %@",
                                bundle: bundle,
                                error.localizedDescription
                            )
                        }
                    )
                    .id(writing.id)
                } else {
                    unavailableWriting
                }
                Divider()
                footer(writing)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar {
            windowToolbar
        }
        .onAppear {
            library.loadIfNeeded()
            center.typography = typography
        }
        .onChange(of: displayAppearance) { _, _ in
            center.typography = typography
        }
        .confirmationDialog(
            String(localized: "Delete Writing?", bundle: bundle),
            isPresented: Binding(
                get: { writingPendingDeletion != nil },
                set: { isPresented in
                    if isPresented == false {
                        writingPendingDeletion = nil
                    }
                }
            ),
            presenting: writingPendingDeletion
        ) { writing in
            Button(String(localized: "Move to Trash", bundle: bundle), role: .destructive) {
                delete(writing)
            }
            Button(String(localized: "Cancel", bundle: bundle), role: .cancel) {}
        } message: { writing in
            Text(AppLocalization.format(
                "“%@” will be moved to the Trash.",
                bundle: bundle,
                displayTitle(of: writing)
            ))
        }
        .alert(
            String(localized: "Rename Writing", bundle: bundle),
            isPresented: Binding(
                get: { writingBeingRenamed != nil },
                set: { isPresented in
                    if isPresented == false {
                        writingBeingRenamed = nil
                    }
                }
            ),
            presenting: writingBeingRenamed
        ) { writing in
            TextField(String(localized: "Title", bundle: bundle), text: $newTitle)
            Button(String(localized: "Rename", bundle: bundle)) {
                rename(writing, to: newTitle)
            }
            .keyboardShortcut(.defaultAction)
            Button(String(localized: "Cancel", bundle: bundle), role: .cancel) {}
        } message: { _ in
            Text("The title is the writing’s first line, so renaming changes that line.", bundle: bundle)
        }
        .alert(
            String(localized: "Unable to Update Writing", bundle: bundle),
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { isPresented in
                    if isPresented == false {
                        errorMessage = nil
                    }
                }
            )
        ) {
            Button(String(localized: "OK", bundle: bundle), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func header(_ writing: WritingMetadata) -> some View {
        HStack(spacing: 8) {
            writingSwitcher(writing)

            Spacer(minLength: 8)

            newWritingButton
                .buttonStyle(.borderless)

            Button {
                openWindow(id: WritingWindowScene.id)
            } label: {
                Label(String(localized: "Open in Separate Window", bundle: bundle), systemImage: "macwindow")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help(String(localized: "Open in Separate Window", bundle: bundle))

            moreMenu(writing)
                .menuStyle(.borderlessButton)
                .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    /// The header's controls in the writing window's title bar, so the window has one
    /// translucent bar like the main window instead of a title bar above a header row.
    @ToolbarContentBuilder
    private var windowToolbar: some ToolbarContent {
        if presentation == .window {
            if let writing = library.currentWriting {
                ToolbarItem(placement: .navigation) {
                    writingSwitcher(writing)
                        .padding(.horizontal, 6)
                }
            }
            // Without a title, a window's toolbar packs its items at the leading edge.
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.flexible)
            }
            ToolbarItemGroup {
                newWritingButton
                if let writing = library.currentWriting {
                    moreMenu(writing)
                }
            }
        }
    }

    private func writingSwitcher(_ writing: WritingMetadata) -> some View {
        Menu {
            ForEach(library.writings) { item in
                Toggle(displayTitle(of: item), isOn: Binding(
                    get: { item.id == writing.id },
                    set: { isOn in
                        if isOn {
                            library.selectWriting(item.id)
                        }
                    }
                ))
            }
            Divider()
            Button(String(localized: "New Writing", bundle: bundle)) {
                createWriting()
            }
        } label: {
            HStack(spacing: 4) {
                Text(displayTitle(of: writing))
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help(String(localized: "Switch Writing", bundle: bundle))
    }

    private var newWritingButton: some View {
        Button {
            createWriting()
        } label: {
            Label(String(localized: "New Writing", bundle: bundle), systemImage: "square.and.pencil")
                .labelStyle(.iconOnly)
        }
        .help(String(localized: "New Writing", bundle: bundle))
    }

    private func moreMenu(_ writing: WritingMetadata) -> some View {
        Menu {
            Button(String(localized: "Rename…", bundle: bundle)) {
                newTitle = writing.title
                writingBeingRenamed = writing
            }
            Button(String(localized: "Insert Image…", bundle: bundle)) {
                chooseImages(for: writing)
            }
            Button(String(localized: "Show in Finder", bundle: bundle)) {
                showInFinder(writing)
            }
            Divider()
            Button(String(localized: "Delete Writing…", bundle: bundle), role: .destructive) {
                writingPendingDeletion = writing
            }
        } label: {
            Label(String(localized: "More", bundle: bundle), systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
        }
        .menuIndicator(.hidden)
        .help(String(localized: "More", bundle: bundle))
    }

    private func footer(_ writing: WritingMetadata) -> some View {
        HStack(spacing: 6) {
            if let lastErrorMessage = library.lastErrorMessage {
                Text(lastErrorMessage)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            } else {
                Text(AppLocalization.format("Words: %lld", bundle: bundle, writing.wordCount))
                if writing.citedPaperIDs.isEmpty == false {
                    Text(verbatim: "·")
                    Text(AppLocalization.format("Cited papers: %lld", bundle: bundle, writing.citedPaperIDs.count))
                }
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(String(localized: "No Writings Yet", bundle: bundle), systemImage: "square.and.pencil")
        } actions: {
            Button(String(localized: "New Writing", bundle: bundle)) {
                createWriting()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var windowPlaceholder: some View {
        ContentUnavailableView {
            // Only the icon: the buttons say what the placeholder is for.
            Image(systemName: "macwindow")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)
                .accessibilityLabel(String(localized: "Writing in a Separate Window", bundle: bundle))
        } actions: {
            HStack(spacing: 8) {
                Button(String(localized: "Show Window", bundle: bundle)) {
                    openWindow(id: WritingWindowScene.id)
                }
                Button(String(localized: "Move Back Here", bundle: bundle)) {
                    dismissWindow(id: WritingWindowScene.id)
                }
            }
            .fixedSize()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var unavailableWriting: some View {
        ContentUnavailableView {
            Label(String(localized: "Writing Unavailable", bundle: bundle), systemImage: "exclamationmark.triangle")
        } description: {
            Text("The writing’s file could not be read.", bundle: bundle)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func displayTitle(of writing: WritingMetadata) -> String {
        writing.title.isEmpty ? String(localized: "Untitled Writing", bundle: bundle) : writing.title
    }

    /// A new writing opens in the writing window.
    private func createWriting() {
        do {
            center.saveAll()
            try library.createWriting()
            if presentation == .inspector {
                windowState.focusEditorWhenShown()
                openWindow(id: WritingWindowScene.id)
            } else {
                localFocusRequest &+= 1
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func rename(_ writing: WritingMetadata, to title: String) {
        writingBeingRenamed = nil
        do {
            let document = try center.document(for: writing.id)
            guard let edit = WritingTitle.renaming(
                document.textStorage.string,
                to: title,
                selection: document.currentSelection
            ) else { return }
            document.apply(edit)
            // Saving updates the title in the list and the window's toolbar right away.
            document.save()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ writing: WritingMetadata) {
        writingPendingDeletion = nil
        do {
            try center.deleteWriting(writing.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func chooseImages(for writing: WritingMetadata) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = String(localized: "Insert", bundle: bundle)
        guard panel.runModal() == .OK, panel.urls.isEmpty == false else { return }
        do {
            let document = try center.document(for: writing.id)
            try document.insertImages(panel.urls.map { .file($0) }, at: NSMaxRange(document.currentSelection))
            localFocusRequest &+= 1
        } catch {
            errorMessage = AppLocalization.format("Unable to add the image: %@", bundle: bundle, error.localizedDescription)
        }
    }

    private func showInFinder(_ writing: WritingMetadata) {
        center.saveAll()
        guard let url = library.markdownURL(for: writing.id) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func open(_ link: WritingLinkActivation, in document: WritingDocument) {
        if let citation = PaperCitation(linkDestination: link.destination, title: link.title) {
            let quote = WritingCitationContext.quote(
                forCitationAt: link.location,
                in: document.textStorage.string,
                citation: citation
            )
            onOpenCitation(citation, quote)
            return
        }
        guard let url = URL(string: link.destination),
              ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
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
            HStack {
                Text("Writings", bundle: bundle)
                    .font(.headline)
                Spacer()
                Button {
                    onCreateWriting()
                } label: {
                    Label(String(localized: "New Writing About This Paper", bundle: bundle), systemImage: "square.and.pencil")
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
                    .help(
                        WritingWindowState.shared.isOpen
                            ? String(localized: "Open in the Writing Window", bundle: bundle)
                            : String(localized: "Open in the Writing Tab", bundle: bundle)
                    )
                }
            }
        }
        .onAppear {
            library.loadIfNeeded()
        }
    }
}

struct NewWritingAction {
    let perform: @MainActor () -> Void
}

struct QuoteInWritingAction {
    let perform: @MainActor () -> Void
}

private struct NewWritingActionKey: FocusedValueKey {
    typealias Value = NewWritingAction
}

private struct QuoteInWritingActionKey: FocusedValueKey {
    typealias Value = QuoteInWritingAction
}

extension FocusedValues {
    var newWritingAction: NewWritingAction? {
        get { self[NewWritingActionKey.self] }
        set { self[NewWritingActionKey.self] = newValue }
    }

    var quoteInWritingAction: QuoteInWritingAction? {
        get { self[QuoteInWritingActionKey.self] }
        set { self[QuoteInWritingActionKey.self] = newValue }
    }
}
