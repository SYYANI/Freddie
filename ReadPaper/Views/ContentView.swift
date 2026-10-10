import AppKit
import SwiftData
import SwiftUI

private enum InspectorColumnMetrics {
    static let minWidth: CGFloat = 280
    static let idealWidth: CGFloat = 340
    static let maxWidth: CGFloat = 420
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.localizationBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.pdfDisplayAppearance) private var displayAppearance
    @Query(sort: \Paper.modifiedAt, order: .reverse) private var papers: [Paper]
    @Query(sort: \PaperAttachment.createdAt) private var attachments: [PaperAttachment]
    @Query(sort: \Note.modifiedAt, order: .reverse) private var notes: [Note]
    @Query private var settingsRows: [AppSettings]

    @State private var selectedPaperID: UUID?
    @State private var readerMode: ReaderMode = .pdf
    @State private var displayMode: TranslationDisplayMode = .bilingual
    @State private var noteSelectionContext: NoteSelectionContext?
    @State private var focusedNoteID: UUID?
    @State private var noteNavigationRequest: NoteNavigationRequest?
    @State private var sidenoteFocusRequest: SidenoteFocusRequest?
    @State private var isPDFSidenoteRailAvailable = false
    @State private var isPreparingInspectorReveal = false
    @State private var isAddingPaper = false
    @State private var paperPendingDeletion: Paper?
    @State private var deletionErrorMessage: String?
    @State private var pendingArxivLinkImport: ArxivLinkImportRequest?
    @State private var isShowingArxivLinkImport = false
    @State private var isImportingArxivLink = false
    @State private var arxivLinkImportProgress: ArxivImportProgress?
    @State private var arxivLinkImportErrorMessage: String?
    @State private var arxivLinkImportIdentifier = ""
    @State private var isPDFDropTargeted = false
    @State private var isImportingDroppedPDFs = false
    @State private var droppedPDFImportErrorMessage: String?

    private var settings: AppSettings? {
        settingsRows.first
    }

    private var isPaperAppearance: Bool {
        displayAppearance == .paper
    }

    private var selectedPaper: Paper? {
        if let selectedPaperID, let paper = papers.first(where: { $0.id == selectedPaperID }) {
            return paper
        }
        return papers.first
    }

    private var isInspectorCollapsed: Bool {
        settings?.resolvedInspectorCollapsed ?? false
    }

    private var inspectorCollapsedBinding: Binding<Bool> {
        Binding(
            get: { isInspectorCollapsed },
            set: { newValue, transaction in
                updateInspectorCollapsed(newValue, transaction: transaction)
            }
        )
    }

    private var inspectorPresentedBinding: Binding<Bool> {
        Binding(
            get: { !isInspectorCollapsed },
            set: { newValue, transaction in
                updateInspectorCollapsed(!newValue, transaction: transaction)
            }
        )
    }

    private var mainWindowMinWidth: CGFloat {
        isPreparingInspectorReveal
            ? MainWindowMetrics.minWidth - InspectorColumnMetrics.maxWidth
            : MainWindowMetrics.minWidth
    }

    private func updateInspectorCollapsed(_ isCollapsed: Bool, transaction: Transaction) {
        if #available(macOS 26.0, *), isCollapsed == false, isInspectorCollapsed {
            revealInspectorWithRelaxedWindowMinimum(transaction: transaction)
        } else {
            persistInspectorCollapsed(isCollapsed)
        }
    }

    /// On macOS 26 the `.inspector` reveal only shrinks the reader when the window is at
    /// least the root minimum width plus the inspector width. In narrower windows AppKit
    /// instead grows the split view past the window edge for the whole reveal animation and
    /// snaps back at the end, which shows up as a hitch. Lowering the minimum by the widest
    /// inspector for the run-loop turn in which the reveal starts keeps it on the shrinking
    /// path; the minimum is restored right after, so the window still cannot get narrower
    /// than `MainWindowMetrics.minWidth`.
    private func revealInspectorWithRelaxedWindowMinimum(transaction: Transaction) {
        guard isPreparingInspectorReveal == false else { return }
        isPreparingInspectorReveal = true

        // The reveal reads the minimum from the last layout pass, so present the inspector
        // only after the relaxed minimum has been applied.
        DispatchQueue.main.async {
            withTransaction(transaction) {
                persistInspectorCollapsed(false)
            }
            DispatchQueue.main.async {
                isPreparingInspectorReveal = false
            }
        }
    }

    private func persistInspectorCollapsed(_ isCollapsed: Bool) {
        if let settings = settings, settings.inspectorCollapsed != isCollapsed {
            settings.inspectorCollapsed = isCollapsed
            settings.modifiedAt = Date()
            do {
                try modelContext.save()
            } catch {
                assertionFailure("Failed to save inspector collapsed state: \(error.localizedDescription)")
            }
        }
    }

    private var sidebarColumn: some View {
        LibrarySidebarView(
            papers: papers,
            selectedPaper: selectedPaper,
            selectedPaperID: $selectedPaperID,
            isAddingPaper: $isAddingPaper,
            onDeleteOffsets: confirmDeletion(at:),
            onDeletePaper: requestDeletion(of:)
        )
        .navigationSplitViewColumnWidth(min: 240, ideal: 260, max: 340)
        .overlay(alignment: .trailing) {
            if #unavailable(macOS 26.0) {
                StableNavigationSplitDividerHandle()
                    .frame(width: 8)
                    .accessibilityHidden(true)
            }
        }
    }

    private var readerColumn: some View {
        ReaderPaneView(
            paper: selectedPaper,
            attachments: attachments.filter { $0.paperID == selectedPaper?.id },
            notes: notes.filter { $0.paperID == selectedPaper?.id },
            settings: settings,
            readerMode: $readerMode,
            displayMode: $displayMode,
            isInspectorCollapsed: inspectorCollapsedBinding,
            noteSelectionContext: $noteSelectionContext,
            noteNavigationRequest: $noteNavigationRequest,
            sidenoteFocusRequest: $sidenoteFocusRequest,
            isPDFSidenoteRailAvailable: $isPDFSidenoteRailAvailable,
            onCreateAnchoredNote: createNoteFromCurrentSelection,
            onSaveSelectionAssistantNote: saveSelectionAssistantResultAsNote,
            onArxivLinkActivated: handleArxivLinkActivation
        )
        .navigationSplitViewColumnWidth(min: 520, ideal: 760)
        .background {
            if !isPaperAppearance {
                ReadPaperReaderMaterialSurface()
                    .ignoresSafeArea()
            }
        }
    }

    private func inspectorColumn(isCollapsed: Bool) -> some View {
        InspectorPaneView(
            paper: selectedPaper,
            notes: notes.filter { $0.paperID == selectedPaper?.id },
            isCollapsed: isCollapsed,
            currentSelectionContext: noteSelectionContext,
            focusedNoteID: $focusedNoteID,
            onCreateNote: createNoteFromCurrentSelection,
            onOpenNoteAnchor: openNoteAnchor
        )
    }

    @ViewBuilder
    private var mainNavigation: some View {
        if #available(macOS 26.0, *) {
            NavigationSplitView {
                sidebarColumn
            } detail: {
                readerColumn
                    .inspector(isPresented: inspectorPresentedBinding) {
                        inspectorColumn(isCollapsed: false)
                            .inspectorColumnWidth(
                                min: InspectorColumnMetrics.minWidth,
                                ideal: InspectorColumnMetrics.idealWidth,
                                max: InspectorColumnMetrics.maxWidth
                            )
                    }
            }
        } else {
            NavigationSplitView {
                sidebarColumn
            } content: {
                readerColumn
            } detail: {
                inspectorColumn(isCollapsed: isInspectorCollapsed)
                    .navigationSplitViewColumnWidth(
                        min: isInspectorCollapsed ? 0 : InspectorColumnMetrics.minWidth,
                        ideal: isInspectorCollapsed ? 0 : InspectorColumnMetrics.idealWidth,
                        max: isInspectorCollapsed ? 0 : InspectorColumnMetrics.maxWidth
                    )
            }
        }
    }

    var body: some View {
        mainNavigation
        .frame(minWidth: mainWindowMinWidth, minHeight: MainWindowMetrics.minHeight)
        .background {
            ZStack {
                if isPaperAppearance {
                    ReadPaperSurface(role: .reader)
                } else {
                    Color.clear
                }
                ReadPaperWindowChrome(
                    colorScheme: colorScheme,
                    isPaperEnabled: isPaperAppearance
                )
                    .frame(width: 0, height: 0)
            }
            .ignoresSafeArea()
        }
        .pdfFileDropTarget(
            isTargeted: $isPDFDropTargeted,
            isImporting: isImportingDroppedPDFs,
            perform: importDroppedPDFs
        )
        // .tint(isPaperAppearance ? ReadPaperTheme.accentColor : nil)
        .sheet(isPresented: $isAddingPaper) {
            AddPaperSheet(isPresented: $isAddingPaper, selectedPaperID: $selectedPaperID)
                .frame(width: 520)
        }
        .sheet(isPresented: $isShowingArxivLinkImport) {
            ArxivLinkImportStatusSheet(
                identifier: arxivLinkImportIdentifier,
                progress: arxivLinkImportProgress,
                isImporting: isImportingArxivLink,
                errorMessage: arxivLinkImportErrorMessage,
                onClose: { isShowingArxivLinkImport = false }
            )
            .frame(width: 460)
            .interactiveDismissDisabled(isImportingArxivLink)
        }
        .alert(
            String(localized: "Import arXiv Paper?", bundle: bundle),
            isPresented: Binding(
                get: { pendingArxivLinkImport != nil },
                set: { isPresented in
                    if !isPresented {
                        pendingArxivLinkImport = nil
                    }
                }
            ),
            presenting: pendingArxivLinkImport
        ) { request in
            Button(String(localized: "Import", bundle: bundle)) {
                startArxivLinkImport(request)
            }
            Button(String(localized: "Open in Browser", bundle: bundle)) {
                NSWorkspace.shared.open(request.url)
            }
            Button(String(localized: "Cancel", bundle: bundle), role: .cancel) {}
        } message: { request in
            Text(AppLocalization.format(
                "This PDF links to arXiv %@. Would you like to import it into your library?",
                bundle: bundle,
                request.identifier.queryID
            ))
        }
        .confirmationDialog(
            String(localized: "Delete Paper?", bundle: bundle),
            isPresented: Binding(
                get: { paperPendingDeletion != nil },
                set: { isPresented in
                    if !isPresented {
                        paperPendingDeletion = nil
                    }
                }
            ),
            presenting: paperPendingDeletion
        ) { paper in
            Button(String(localized: "Delete", bundle: bundle), role: .destructive) {
                deletePaper(paper)
            }
            Button(String(localized: "Cancel", bundle: bundle), role: .cancel) {}
        } message: { paper in
            Text(
                String(
                    format: String(localized: "“%@” and all of its local files, notes, reading state, and translation cache will be removed.", bundle: bundle),
                    paper.title
                )
            )
        }
        .alert(String(localized: "Unable to Delete Paper", bundle: bundle), isPresented: Binding(
            get: { deletionErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    deletionErrorMessage = nil
                }
            }
        )) {
            Button(String(localized: "OK", bundle: bundle), role: .cancel) {}
        } message: {
            Text(deletionErrorMessage ?? "")
        }
        .alert(String(localized: "Unable to Import Paper", bundle: bundle), isPresented: Binding(
            get: { droppedPDFImportErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    droppedPDFImportErrorMessage = nil
                }
            }
        )) {
            Button(String(localized: "OK", bundle: bundle), role: .cancel) {}
        } message: {
            Text(droppedPDFImportErrorMessage ?? "")
        }
        .onAppear {
            let restoredSettings = ensureSettings()
            restoreSelection(preferredPaperID: restoredSettings?.lastOpenedPaperID)
            persistSelectedPaperIDIfNeeded(selectedPaperID, using: restoredSettings)
        }
        .onChange(of: papers.map(\.id)) { _, _ in
            syncSelectionWithAvailablePapers()
        }
        .onChange(of: selectedPaperID) { _, newValue in
            noteSelectionContext = nil
            focusedNoteID = nil
            noteNavigationRequest = nil
            sidenoteFocusRequest = nil
            persistSelectedPaperIDIfNeeded(newValue)
        }
    }

    private func ensureSettings() -> AppSettings? {
        do {
            let settings = try LLMConfigurationBootstrapper().ensureBootstrap(modelContext: modelContext)
            try LLMDefaultProfileSeeder().ensureDefaults(modelContext: modelContext)
            return settings
        } catch {
            return nil
        }
    }

    private func confirmDeletion(at offsets: IndexSet) {
        guard let offset = offsets.first, papers.indices.contains(offset) else { return }
        requestDeletion(of: papers[offset])
    }

    private func requestDeletion(of paper: Paper) {
        paperPendingDeletion = paper
    }

    private func deletePaper(_ paper: Paper) {
        let nextSelection = nextSelectionAfterDeletingPaper(withID: paper.id)

        do {
            try PaperDeletionService().delete(paper, modelContext: modelContext)
            selectedPaperID = nextSelection
            paperPendingDeletion = nil
        } catch {
            paperPendingDeletion = nil
            deletionErrorMessage = error.localizedDescription
        }
    }

    private func nextSelectionAfterDeletingPaper(withID paperID: UUID) -> UUID? {
        let remainingPapers = papers.filter { $0.id != paperID }
        guard !remainingPapers.isEmpty else { return nil }

        guard let deletedIndex = papers.firstIndex(where: { $0.id == paperID }) else {
            return remainingPapers.first?.id
        }

        let nextIndex = min(deletedIndex, remainingPapers.count - 1)
        return remainingPapers[nextIndex].id
    }

    private func restoreSelection(preferredPaperID: UUID?) {
        selectedPaperID = PaperSelectionStore.resolvedSelection(
            currentPaperID: nil,
            savedPaperID: preferredPaperID,
            availablePaperIDs: papers.map(\.id)
        )
    }

    private func syncSelectionWithAvailablePapers() {
        let resolvedSelection = PaperSelectionStore.resolvedSelection(
            currentPaperID: selectedPaperID,
            savedPaperID: settings?.lastOpenedPaperID,
            availablePaperIDs: papers.map(\.id)
        )

        guard resolvedSelection != selectedPaperID else { return }
        selectedPaperID = resolvedSelection
    }

    private func persistSelectedPaperIDIfNeeded(
        _ paperID: UUID?,
        using settingsOverride: AppSettings? = nil
    ) {
        guard let settings = settingsOverride ?? settings else { return }
        guard settings.lastOpenedPaperID != paperID else { return }

        settings.lastOpenedPaperID = paperID
        settings.modifiedAt = Date()

        do {
            try modelContext.save()
        } catch {
            assertionFailure("Failed to save selected paper: \(error.localizedDescription)")
        }
    }

    private func createNoteFromCurrentSelection() {
        guard let paper = selectedPaper else { return }

        let note = Note(
            paperID: paper.id,
            attachmentID: noteSelectionContext?.attachmentID,
            quote: noteSelectionContext?.trimmedQuote ?? "",
            body: "",
            pageIndex: noteSelectionContext?.pageIndex,
            htmlSelector: noteSelectionContext?.htmlSelector
        )
        modelContext.insert(note)

        do {
            try modelContext.save()
            if isShownAsSidenote(note) {
                sidenoteFocusRequest = SidenoteFocusRequest(noteID: note.id)
            } else {
                revealInInspector(note)
            }
        } catch {
            modelContext.rollback()
            assertionFailure("Failed to save note: \(error.localizedDescription)")
        }
    }

    /// Anchored notes appear in the reader's margin, so they are edited there
    /// instead of opening the inspector.
    private func isShownAsSidenote(_ note: Note) -> Bool {
        switch readerMode {
        case .html:
            return note.normalizedHTMLSelector != nil
        case .pdf, .translatedPDF:
            return note.pageIndex != nil && isPDFSidenoteRailAvailable
        case .bilingualPDF:
            return false
        }
    }

    private func revealInInspector(_ note: Note) {
        if isInspectorCollapsed {
            inspectorCollapsedBinding.wrappedValue = false
        }
        focusedNoteID = note.id
    }

    private func saveSelectionAssistantResultAsNote(
        selection: NoteSelectionContext,
        result: String,
        existingNoteID: UUID?
    ) throws -> UUID {
        guard let paper = selectedPaper else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        do {
            let note: Note
            if let existingNoteID,
               let existingNote = try modelContext.fetch(FetchDescriptor<Note>())
                .first(where: { $0.id == existingNoteID }) {
                existingNote.body = result
                existingNote.modifiedAt = Date()
                note = existingNote
            } else {
                let newNote = Note.selectionAssistantNote(
                    paperID: paper.id,
                    selection: selection,
                    result: result
                )
                modelContext.insert(newNote)
                note = newNote
            }

            try modelContext.save()
            if !isShownAsSidenote(note) {
                revealInInspector(note)
            }
            return note.id
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private func openNoteAnchor(_ note: Note) {
        noteNavigationRequest = note.navigationRequest
    }

    private func handleArxivLinkActivation(_ url: URL) {
        guard !isImportingArxivLink,
              let request = ArxivLinkImportRequest(url: url)
        else {
            return
        }
        pendingArxivLinkImport = request
    }

    private func startArxivLinkImport(_ request: ArxivLinkImportRequest) {
        pendingArxivLinkImport = nil
        arxivLinkImportIdentifier = request.identifier.queryID
        arxivLinkImportProgress = .resolvingInput(identifier: request.identifier.queryID)
        arxivLinkImportErrorMessage = nil
        isImportingArxivLink = true
        isShowingArxivLinkImport = true

        Task {
            do {
                let importedPaper = try await PaperImporter().importArxiv(
                    request.importValue,
                    modelContext: modelContext
                ) { progress in
                    arxivLinkImportProgress = progress
                }
                selectedPaperID = importedPaper.id
                isShowingArxivLinkImport = false
            } catch {
                arxivLinkImportErrorMessage = error.localizedDescription
            }
            isImportingArxivLink = false
        }
    }

    private func importDroppedPDFs(_ urls: [URL]) -> Bool {
        guard !isImportingDroppedPDFs else { return false }

        let pdfURLs = PaperImporter.supportedLocalPDFs(from: urls)
        guard !pdfURLs.isEmpty else { return false }

        let scopedURLs = pdfURLs.map { url in
            (url: url, isSecurityScoped: url.startAccessingSecurityScopedResource())
        }
        isPDFDropTargeted = false
        isImportingDroppedPDFs = true
        droppedPDFImportErrorMessage = nil

        Task { @MainActor in
            await Task.yield()

            defer {
                for scopedURL in scopedURLs where scopedURL.isSecurityScoped {
                    scopedURL.url.stopAccessingSecurityScopedResource()
                }
                isImportingDroppedPDFs = false
            }

            var lastImportedPaperID: UUID?
            var failures: [String] = []

            let importer = PaperImporter()
            for scopedURL in scopedURLs {
                do {
                    let paper = try importer.importLocalPDF(
                        scopedURL.url,
                        modelContext: modelContext
                    )
                    lastImportedPaperID = paper.id
                } catch {
                    modelContext.rollback()
                    failures.append("\(scopedURL.url.lastPathComponent): \(error.localizedDescription)")
                }
            }

            if let lastImportedPaperID {
                selectedPaperID = lastImportedPaperID
            }
            if !failures.isEmpty {
                droppedPDFImportErrorMessage = failures.joined(separator: "\n")
            }
        }

        return true
    }

}

private struct ArxivLinkImportStatusSheet: View {
    @Environment(\.localizationBundle) private var bundle

    let identifier: String
    let progress: ArxivImportProgress?
    let isImporting: Bool
    let errorMessage: String?
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Importing from arXiv", bundle: bundle)
                .font(.title2.weight(.semibold))

            Text(AppLocalization.format("arXiv %@", bundle: bundle, identifier))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let progress {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(progress.stepLabel)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(round(progress.fractionCompleted * 100)))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    ProgressView(value: progress.fractionCompleted)
                        .progressViewStyle(.linear)

                    Text(progress.title)
                        .font(.subheadline.weight(.semibold))

                    if let detail = progress.detail {
                        Text(detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(14)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.quaternary.opacity(0.35))
                }
            } else if isImporting {
                ProgressView()
            }

            if let errorMessage {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Unable to Import Paper", bundle: bundle)
                        .font(.headline)
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }

            HStack {
                Spacer()
                Button(String(localized: "Close", bundle: bundle), action: onClose)
                    .disabled(isImporting)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
    }
}
