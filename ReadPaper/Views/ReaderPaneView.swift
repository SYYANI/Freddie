import AppKit
import CoreGraphics
import OSLog
import PDFKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct ReaderPaneView: View {
    private struct PDFPageCountRequest: Hashable, Sendable {
        var attachmentID: UUID
        var fileURL: URL
    }

    private struct ReadingStatePersistenceSnapshot: Equatable {
        var paperID: UUID
        var attachmentID: UUID?
        var readerMode: ReaderMode
        var pageIndex: Int
        var scrollRatio: Double
    }

    private static let readingStatePersistenceDelay: Duration = .milliseconds(600)
    private static let performanceLog = OSLog(
        subsystem: "com.yiyan.ReadPaper",
        category: .pointsOfInterest
    )

    private enum PrimaryReaderMode: String, CaseIterable, Identifiable {
        case html
        case pdf

        var id: String { rawValue }
    }

    private struct ReaderAvailability: Equatable {
        var paperID: UUID?
        var hasHTML: Bool
        var hasPDF: Bool
        var hasTranslatedPDF: Bool
    }

    private struct TranslationProgressStatus: Equatable {
        var completed: Double
        var total: Double
        var summary: String
    }

    /// How a finished translation is shown in the activity capsule before it fades.
    private struct TranslationActivityOutcome: Equatable {
        var phase: TranslationActivityCapsule.Phase
        var message: String?
    }

    private enum PDFTranslationScope {
        case firstPages(Int)
        case allPages
    }

    /// A pending offer to translate the PDF as a scan, shown before any page image is sent.
    private struct ScannedPDFTranslationOffer: Equatable {
        var pageCount: Int
        /// Set when the offer replaces a refused text translation.
        var hasNoTextLayer: Bool
        /// The last page of an earlier scanned translation of the first pages, or 0.
        var translatedLastPage: Int = 0
    }

    private struct PendingHTMLRegionChanges {
        var fileURL: URL
        /// Each change sets an element's final state, so the latest one per element wins.
        var changesByPath: [String: HTMLRegionChange] = [:]
    }

    private static let htmlRegionSaveDelay: Duration = .milliseconds(400)

    @Environment(\.modelContext) private var modelContext
    @Environment(\.localizationBundle) private var bundle
    @Environment(\.pdfDisplayAppearance) private var pdfDisplayAppearance
    @Environment(\.openSettings) private var openSettings
    @Query(sort: \ReadingState.modifiedAt, order: .reverse) private var readingStates: [ReadingState]
    @AppStorage(TranslationSetupNavigation.didHandleReaderNoticeKey)
    private var didHandleTranslationSetupNotice = false
    @AppStorage(PDFTranslationBatchPreference.userDefaultsKey)
    private var pdfTranslationBatchSizeRawValue = PDFTranslationBatchPreference.defaultValue
    @AppStorage(HTMLReaderTypography.fontSizeUserDefaultsKey)
    private var htmlReaderFontSize = HTMLReaderTypography.defaultFontSize
    @AppStorage(PDFReaderControlPreferences.handToolEnabledKey)
    private var pdfHandToolEnabled = PDFReaderControlPreferences.defaultHandToolEnabled
    @AppStorage(PDFReaderControlPreferences.showZoomButtonsKey)
    private var showPDFZoomButtons = PDFReaderControlPreferences.defaultShowZoomButtons
    @AppStorage(BabelDocSemanticHintPreference.userDefaultsKey)
    private var babelDocSemanticHintsEnabled = BabelDocSemanticHintPreference.defaultValue
    @AppStorage(LaTeXIntegrationPreferences.translationEnabledKey)
    private var latexTranslationEnabled = false
    @AppStorage(ScannedPDFTranslationPreferences.didConfirmTranslationKey)
    private var didConfirmScannedPDFTranslation = false
    @AppStorage(ScannedPDFTranscription.displayedPaperIDsKey)
    private var transcriptionPaperIDsStorage = ""

    var paper: Paper?
    var attachments: [PaperAttachment]
    var notes: [Note]
    var settings: AppSettings?
    /// The reader mode of the current paper. Read `readerMode`, which also covers the update
    /// in which another paper arrives before its reading state is restored.
    @Binding var storedReaderMode: ReaderMode
    @Binding var displayMode: TranslationDisplayMode
    @Binding var isInspectorCollapsed: Bool
    @Binding var noteSelectionContext: NoteSelectionContext?
    @Binding var noteNavigationRequest: NoteNavigationRequest?
    @Binding var sidenoteFocusRequest: SidenoteFocusRequest?
    /// Whether the single-PDF reader is wide enough to show margin notes.
    @Binding var isPDFSidenoteRailAvailable: Bool
    var onCreateAnchoredNote: () -> Void
    var onSaveSelectionAssistantNote: @MainActor @Sendable (
        NoteSelectionContext,
        String,
        UUID?
    ) throws -> UUID
    var onArxivLinkActivated: (URL) -> Void
    /// Opens the writing that cites a passage marked in the reader.
    var onRevealCitation: (WritingCitationMark) -> Void = { _ in }
    var writingLibrary: WritingLibrary = .shared
    /// Whether the library has no papers yet, for the empty reader's call to action.
    var isLibraryEmpty = false
    var onAddPaper: () -> Void = {}

    /// Read `pdfPageIndex`, for the same reason as `storedReaderMode`.
    @State private var storedPDFPageIndex = 0
    /// The paper whose reading state `storedReaderMode` and `storedPDFPageIndex` hold.
    @State private var readingStatePaperID: UUID?
    @State private var htmlScrollRatio = 0.0
    @State private var htmlReloadToken = 0
    @State private var pdfReloadToken = 0
    @State private var htmlSegmentUpdate: HTMLTranslationSegmentUpdate?
    @State private var isWorking = false
    @State private var isCancelling = false
    @State private var statusMessage: String?
    @State private var translationProgress: TranslationProgressStatus?
    @State private var translationTask: Task<Void, Never>?
    @State private var translationActivityOutcome: TranslationActivityOutcome?
    @State private var translationActivityDismissTask: Task<Void, Never>?
    @State private var pdfTranslationErrorLogURL: URL?
    @State private var pdfTranslationDiagnosticsNoticeID: String?
    @State private var latexTranslationErrorLogURL: URL?
    /// The status message of a translation that stopped because no usable model is
    /// set up. The status row offers the setup only while it still shows that message.
    @State private var translationSetupErrorMessage: String?
    @State private var needsTranslationSetup = false
    @State private var lastPDFReaderMode: ReaderMode = .pdf
    @State private var suspendReadingStatePersistence = false
    @State private var pendingReadingStatePersistence: ReadingStatePersistenceSnapshot?
    @State private var readingStatePersistenceTask: Task<Void, Never>?
    @State private var showPDFTranslationScopeDialog = false
    @State private var pdfTranslationTotalPages: Int = 0
    @State private var scannedPDFTranslationOffer: ScannedPDFTranslationOffer?
    @State private var digestNoticeMessage: String?
    @State private var digestNoticeTitle: String?
    @State private var digestErrorMessage: String?
    @State private var writingQuoteErrorMessage: String?
    @State private var isExportingHTMLPDF = false
    @State private var htmlPDFExportError: String?
    @State private var copyToastMessage: String?
    @State private var copyToastDismissTask: Task<Void, Never>?
    @State private var pdfDebugModeEnabled = false
    @State private var pdfDebugExportDirectoryURL: URL?
    @State private var pdfDebugDirectoryHasSecurityScope = false
    @StateObject private var pdfAnnotationSession = PDFAnnotationSession()
    @State private var isHoveringPDFZoomControls = false
    @State private var pdfAnnotationNoteText = ""
    @State private var selectionAssistantSelection: NoteSelectionContext?
    @State private var isSelectionAssistantPinned = false
    @State private var selectionAssistantDismissTask: Task<Void, Never>?
    @State private var selectionAssistantProgress: SelectionAssistantProgress?
    @State private var selectionAssistantInitialConversation: SelectionAssistantConversationSnapshot?
    @State private var selectionAssistantHistoryAnchors: [SelectionAssistantHistoryAnchor] = []
    @State private var htmlSelectionHighlightResetToken = 0
    @State private var htmlNativeSelectionClearToken = 0
    @State private var sidenotePendingDeletion: Note?
    @State private var pdfSidenoteLayout = PDFSidenoteLayoutModel()
    @State private var originalPDFPageCount: Int?
    /// Enable ordinary PDF translation only after inspecting this exact attachment.
    @State private var extractablePDFRequest: PDFPageCountRequest?
    @State private var isFindBarVisible = false
    @State private var findQuery = ""
    @State private var committedFindQuery = ""
    @State private var findOptions = DocumentSearchOptions()
    @State private var findNavigationToken = 0
    @State private var findNavigationDirection: DocumentFindDirection = .forward
    @State private var findStatus: DocumentFindStatus?
    @State private var findFocusToken = 0
    @State private var bilingualFindTarget: DualPDFSelectionSource = .original
    @State private var isEditingHTMLRegions = false
    @State private var htmlRegionEditUpdate: HTMLRegionEditUpdate?
    /// Hidden regions on the page shown, reported on every load and edit.
    @State private var htmlHiddenRegionCount = 0
    @State private var htmlRegionEditCommand: HTMLRegionEditCommand?
    @State private var pendingHTMLRegionChanges: PendingHTMLRegionChanges?
    @State private var htmlRegionSaveTask: Task<Void, Never>?

    private var pdfAttachment: PaperAttachment? {
        attachments.first { $0.kind == .pdf }
    }

    private var htmlAttachment: PaperAttachment? {
        attachments.first { $0.kind == .html }
    }

    private var translatedPDFAttachment: PaperAttachment? {
        attachments
            .filter { $0.kind == .translatedPDF }
            .max { $0.createdAt < $1.createdAt }
    }

    private var translatedLaTeXSourceAttachment: PaperAttachment? {
        attachments
            .filter { $0.kind == .resource && $0.source == .latexTrans }
            .max { $0.createdAt < $1.createdAt }
    }

    /// The corrected transcription of a scanned PDF: an alternative original with real text.
    private var scanTranscriptionAttachment: PaperAttachment? {
        ScannedPDFTranscription.attachment(in: attachments)
    }

    private var showsScanTranscription: Bool {
        guard let paper, scanTranscriptionAttachment != nil else { return false }
        return ScannedPDFTranscription.decode(transcriptionPaperIDsStorage).contains(paper.id)
    }

    /// The original as read: the PDF, or its corrected transcription when the reader chose it.
    private var originalPDFAttachment: PaperAttachment? {
        showsScanTranscription ? scanTranscriptionAttachment : pdfAttachment
    }

    private var originalPDFPageCountRequest: PDFPageCountRequest? {
        guard let attachment = pdfAttachment else { return nil }
        return PDFPageCountRequest(
            attachmentID: attachment.id,
            fileURL: attachment.fileURL
        )
    }

    private var isPartialPDFTranslation: Bool {
        guard let attachment = translatedPDFAttachment,
              let total = originalPDFPageCount
        else { return false }
        return PDFTranslationCoverage.isPartial(
            translatedLastPage: attachment.translatedLastPage,
            originalPageCount: total
        )
    }

    private var isNearTranslationEdge: Bool {
        guard isPartialPDFTranslation,
              let lastPage = translatedPDFAttachment?.translatedLastPage
        else { return false }
        return pdfPageIndex >= max(0, lastPage - 2)
    }

    private var canTranslateHTML: Bool {
        htmlAttachment != nil && settings != nil
    }

    private var canTranslatePDF: Bool {
        pdfAttachment != nil && settings != nil
    }

    private var canTranslateTextPDF: Bool {
        canTranslatePDF && extractablePDFRequest == originalPDFPageCountRequest
    }

    /// The shown translation was rebuilt from page images rather than translated by BabelDOC.
    private var isScanRebuildTranslation: Bool {
        translatedPDFAttachment?.source == .scanRebuild
    }

    /// A partial translation continues on the route that made it.
    private var canContinuePDFTranslation: Bool {
        isScanRebuildTranslation ? canTranslatePDF : canTranslateTextPDF
    }

    private var canTranslateLaTeX: Bool {
        latexTranslationEnabled && paper?.arxivID?.isEmpty == false && settings != nil
    }

    private var isFullPDFTranslationComplete: Bool {
        guard let attachment = translatedPDFAttachment else { return false }
        guard let lastPage = attachment.translatedLastPage else { return true }
        guard let total = originalPDFPageCount else { return true }
        return lastPage >= total
    }

    private var translationControlsDisabled: Bool {
        // Translation rewrites paper.html, so it waits until region editing ends.
        isWorking || isEditingHTMLRegions || (!canTranslateHTML && !canTranslatePDF && !canTranslateLaTeX)
    }

    private var readerAvailability: ReaderAvailability {
        ReaderAvailability(
            paperID: paper?.id,
            hasHTML: htmlAttachment != nil,
            hasPDF: pdfAttachment != nil,
            hasTranslatedPDF: translatedPDFAttachment != nil
        )
    }

    private var readingState: ReadingState? {
        guard let paperID = paper?.id else { return nil }
        return readingStates.first { $0.paperID == paperID }
    }

    private var restoredHTMLScrollRatio: Double {
        ReadingStateStore.clampedScrollRatio(readingState?.scrollRatio ?? 0)
    }

    /// The saved reader mode and page of the current paper, resolved against its attachments.
    private var restoredReadingPosition: (readerMode: ReaderMode, pageIndex: Int) {
        let state = readingState
        let readerMode = ReadingStateStore.resolvedReaderMode(
            preferredMode: state?.readerMode,
            hasHTML: htmlAttachment != nil,
            hasPDF: pdfAttachment != nil,
            hasTranslatedPDF: translatedPDFAttachment != nil
        )
        return (readerMode, max(0, state?.pageIndex ?? 0))
    }

    /// SwiftUI renders a newly selected paper once before `onChange(of: paper?.id)` restores
    /// its reading state. Until then the stored mode and page are the previous paper's, so
    /// the reader shows the restored ones instead; otherwise it would open the paper in the
    /// previous paper's reader or at its page and then open it again.
    private var isAwaitingReadingStateRestore: Bool {
        guard let paper else { return false }
        return readingStatePaperID != paper.id
    }

    private var readerMode: ReaderMode {
        get { isAwaitingReadingStateRestore ? restoredReadingPosition.readerMode : storedReaderMode }
        nonmutating set { storedReaderMode = newValue }
    }

    private var pdfPageIndex: Int {
        get { isAwaitingReadingStateRestore ? restoredReadingPosition.pageIndex : storedPDFPageIndex }
        nonmutating set { storedPDFPageIndex = newValue }
    }

    private var pdfPageIndexBinding: Binding<Int> {
        Binding(
            get: { pdfPageIndex },
            set: { pdfPageIndex = $0 }
        )
    }

    private var pdfTranslationBatchSize: Int {
        PDFTranslationBatchPreference.normalized(pdfTranslationBatchSizeRawValue)
    }

    private var primaryReaderMode: Binding<PrimaryReaderMode> {
        Binding(
            get: {
                readerMode == .html ? .html : .pdf
            },
            set: { newValue in
                switch newValue {
                case .html:
                    if readerMode != .html {
                        lastPDFReaderMode = normalizedPDFReaderMode(readerMode)
                    }
                    readerMode = .html
                case .pdf:
                    readerMode = normalizedPDFReaderMode(lastPDFReaderMode)
                }
            }
        )
    }

    private var pdfReaderModeSelection: Binding<ReaderMode> {
        Binding(
            get: {
                normalizedPDFReaderMode(readerMode == .html ? lastPDFReaderMode : readerMode)
            },
            set: { newValue in
                let normalizedMode = normalizedPDFReaderMode(newValue)
                lastPDFReaderMode = normalizedMode
                readerMode = normalizedMode
            }
        )
    }

    private var isFindAvailable: Bool {
        switch readerMode {
        case .html:
            htmlAttachment?.fileURL != nil
        case .pdf:
            pdfAttachment?.fileURL != nil
        case .bilingualPDF, .translatedPDF:
            translatedPDFAttachment?.fileURL != nil
        }
    }

    private var findRequest: DocumentFindRequest? {
        guard isFindBarVisible,
              isFindAvailable,
              committedFindQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else {
            return nil
        }
        return DocumentFindRequest(
            query: committedFindQuery,
            options: findOptions,
            navigationToken: findNavigationToken,
            navigationDirection: findNavigationDirection
        )
    }

    private var visibleFindStatus: DocumentFindStatus? {
        guard let findRequest else { return nil }
        guard let findStatus,
              findStatus.query == findRequest.query,
              findStatus.options == findRequest.options
        else {
            return .searching(findRequest)
        }
        return findStatus
    }

    private var readerBody: some View {
        readerSurface
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                ReadPaperAppearanceSurface(role: .reader)
                    .ignoresSafeArea()
            }
            .overlay(alignment: .bottom) {
                VStack(spacing: 10) {
                    if needsTranslationSetup, !didHandleTranslationSetupNotice {
                        translationSetupNotice
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    if let copyToastMessage {
                        copyToast(message: copyToastMessage)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    translationActivityCapsule
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
                .zIndex(20)
                .animation(.spring(duration: 0.4, bounce: 0.15), value: translationActivityPhase == nil)
            }
            .animation(.easeOut(duration: 0.18), value: copyToastMessage != nil)
            .animation(.easeOut(duration: 0.2), value: needsTranslationSetup && !didHandleTranslationSetupNotice)
            .task(id: TranslationSetupCheck(settings: settings)) {
                refreshTranslationSetupNeed()
            }
            .toolbar {
                readerToolbar
            }
            .onAppear {
                restoreReadingStateForCurrentPaper()
                restorePDFTranslationDiagnostics()
                refreshSelectionAssistantHistoryAnchors()
            }
            .task(id: originalPDFPageCountRequest) {
                await refreshOriginalPDFPageCount(for: originalPDFPageCountRequest)
            }
            .onChange(of: paper?.id) { _, _ in
                dismissTranslationActivityOutcome()
                finishHTMLRegionEditing()
                htmlHiddenRegionCount = 0
                flushPendingReadingStatePersistence()
                deactivatePDFTranslationDebugMode()
                pdfAnnotationSession.resetForDocumentChange()
                noteSelectionContext = nil
                clearSelectionAssistant()
                restoreReadingStateForCurrentPaper()
                revealNavigationArrivingWithPaper()
                refreshSelectionAssistantHistoryAnchors()
            }
            .onChange(of: readerAvailability) { _, newValue in
                if newValue.hasHTML == false {
                    finishHTMLRegionEditing()
                }
                syncReaderModeWithAvailableContent()
                restorePDFTranslationDiagnostics()
            }
            .onChange(of: readerMode) { _, newValue in
                noteSelectionContext = nil
                clearSelectionAssistant()
                if newValue != .html {
                    finishHTMLRegionEditing()
                    lastPDFReaderMode = normalizedPDFReaderMode(newValue)
                }
                persistReadingStateImmediatelyIfNeeded()
            }
            .onChange(of: pdfPageIndex) { _, _ in
                scheduleReadingStatePersistence()
            }
            .onChange(of: noteNavigationRequest?.id) { _, _ in
                revealNoteAnchorIfNeeded()
            }
            .onChange(of: htmlScrollRatio) { _, _ in
                scheduleReadingStatePersistence()
            }
            .onChange(of: pdfAnnotationSession.pendingTextNote?.id) { _, newValue in
                if newValue != nil {
                    pdfAnnotationNoteText = ""
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                flushHTMLRegionChanges()
                HTMLRegionWriter.shared.finishBeforeTermination()
            }
            .onDisappear {
                finishHTMLRegionEditing()
                flushReadingStatePersistence()
                deactivatePDFTranslationDebugMode()
                clearSelectionAssistant()
                dismissCopyToast()
                dismissTranslationActivityOutcome()
            }
            .confirmationDialog(
                String(localized: "Choose Translation Scope", bundle: bundle),
                isPresented: $showPDFTranslationScopeDialog,
                titleVisibility: .visible
            ) {
                Button(AppLocalization.format("First %d Pages", bundle: bundle, pdfTranslationBatchSize)) {
                    startPDFTranslation(scope: .firstPages(pdfTranslationBatchSize))
                }
                Button(String(localized: "All Pages", bundle: bundle)) {
                    startPDFTranslation(scope: .allPages)
                }
                Button(String(localized: "Cancel", bundle: bundle), role: .cancel) {}
            } message: {
                Text(AppLocalization.format(
                    "This PDF has %d pages. Translating the first %d pages is faster.",
                    bundle: bundle,
                    pdfTranslationTotalPages,
                    pdfTranslationBatchSize
                ))
            }
            .alert(
                digestNoticeTitle ?? String(localized: "Digest Ready", bundle: bundle),
                isPresented: Binding(
                    get: { digestNoticeMessage != nil },
                    set: { isPresented in
                        if !isPresented {
                            digestNoticeMessage = nil
                            digestNoticeTitle = nil
                        }
                    }
                )
            ) {
                Button(String(localized: "OK", bundle: bundle), role: .cancel) {}
            } message: {
                Text(digestNoticeMessage ?? "")
            }
            .alert(
                String(localized: "Unable to Create Digest", bundle: bundle),
                isPresented: Binding(
                    get: { digestErrorMessage != nil },
                    set: { isPresented in
                        if !isPresented {
                            digestErrorMessage = nil
                        }
                    }
                )
            ) {
                Button(String(localized: "OK", bundle: bundle), role: .cancel) {}
            } message: {
                Text(digestErrorMessage ?? "")
            }
    }

    private var scannedPDFTranslationDialogTitle: String {
        if didConfirmScannedPDFTranslation {
            return String(localized: "Choose Translation Scope", bundle: bundle)
        }
        return scannedPDFTranslationOffer?.hasNoTextLayer == true
            ? String(localized: "This PDF Has No Text Layer", bundle: bundle)
            : String(localized: "Translate Scanned PDF", bundle: bundle)
    }

    /// Shows the page-image notice once; later dialogs only choose the page range.
    private func scannedPDFTranslationDialog<Content: View>(_ content: Content) -> some View {
        content
            .confirmationDialog(
                scannedPDFTranslationDialogTitle,
                isPresented: Binding(
                    get: { scannedPDFTranslationOffer != nil },
                    set: { if !$0 { scannedPDFTranslationOffer = nil } }
                ),
                titleVisibility: .visible,
                presenting: scannedPDFTranslationOffer
            ) { offer in
                let nextLastPage = offer.translatedLastPage + pdfTranslationBatchSize
                if offer.pageCount > nextLastPage {
                    if offer.translatedLastPage > 0 {
                        Button(AppLocalization.format(
                            "Translate pages %@–%@",
                            bundle: bundle,
                            "\(offer.translatedLastPage + 1)",
                            "\(nextLastPage)"
                        )) {
                            startScannedPDFTranslation(pages: Array(1...nextLastPage))
                        }
                    } else {
                        Button(AppLocalization.format("Translate First %d Pages", bundle: bundle, pdfTranslationBatchSize)) {
                            startScannedPDFTranslation(pages: Array(1...pdfTranslationBatchSize))
                        }
                    }
                    Button(AppLocalization.format("Translate All %d Pages", bundle: bundle, offer.pageCount)) {
                        startScannedPDFTranslation(pages: nil)
                    }
                } else {
                    Button(String(localized: "Translate", bundle: bundle)) {
                        startScannedPDFTranslation(pages: nil)
                    }
                }
                Button(String(localized: "Cancel", bundle: bundle), role: .cancel) {}
            } message: { offer in
                Text(scannedPDFTranslationOfferMessage(offer))
            }
    }

    var body: some View {
        scannedPDFTranslationDialog(readerBody)
            .modifier(WritingQuoteSupport(
                errorMessage: $writingQuoteErrorMessage,
                action: quoteInWritingAction
            ))
            .task(id: findQuery) {
                await commitFindQueryAfterTyping()
            }
            .onChange(of: readerMode) { _, _ in
                findStatus = nil
            }
            .onChange(of: bilingualFindTarget) { _, _ in
                findStatus = nil
            }
            .alert(
                String(localized: "Add PDF Note", bundle: bundle),
                isPresented: pdfTextNoteAlertPresented
            ) {
                TextField(String(localized: "Note", bundle: bundle), text: $pdfAnnotationNoteText)
                Button(String(localized: "Cancel", bundle: bundle), role: .cancel) {
                    pdfAnnotationSession.cancelPendingTextNote()
                }
                Button(String(localized: "Save", bundle: bundle)) {
                    pdfAnnotationSession.commitPendingTextNote(contents: pdfAnnotationNoteText)
                }
                .disabled(pdfAnnotationNoteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } message: {
                Text("Enter the note to attach at this PDF position.", bundle: bundle)
            }
            .alert(
                String(localized: "PDF Annotation Error", bundle: bundle),
                isPresented: pdfAnnotationErrorAlertPresented
            ) {
                Button(String(localized: "OK", bundle: bundle), role: .cancel) {}
            } message: {
                Text(pdfAnnotationSession.errorMessage ?? "")
            }
            .alert(
                String(localized: "Unable to Export PDF", bundle: bundle),
                isPresented: Binding(
                    get: { htmlPDFExportError != nil },
                    set: { if !$0 { htmlPDFExportError = nil } }
                )
            ) {
                Button(String(localized: "OK", bundle: bundle), role: .cancel) {}
            } message: {
                Text(htmlPDFExportError ?? "")
            }
            .noteDeletionConfirmation($sidenotePendingDeletion)
    }

    private var sidenoteLabels: HTMLSidenoteLabels {
        HTMLSidenoteLabels(
            placeholder: String(localized: "Click to edit note", bundle: bundle),
            editorPlaceholder: String(localized: "Write a note…", bundle: bundle),
            delete: String(localized: "Delete Note", bundle: bundle)
        )
    }

    private func handleSidenoteEvent(_ event: HTMLSidenoteEvent) {
        switch event {
        case let .bodyChanged(noteID, body, isFinal):
            guard let note = notes.first(where: { $0.id == noteID }) else { return }
            if note.body != body {
                note.body = body
                note.modifiedAt = Date()
            }
            if isFinal {
                saveSidenoteEdits()
            }
        case let .deleteRequested(noteID):
            sidenotePendingDeletion = notes.first { $0.id == noteID }
        }
    }

    private func saveSidenoteEdits() {
        guard modelContext.hasChanges else { return }
        do {
            try modelContext.save()
        } catch {
            assertionFailure("Failed to save margin note: \(error.localizedDescription)")
        }
    }

    private func handleSidenoteFocusHandled(_ request: SidenoteFocusRequest) {
        if sidenoteFocusRequest == request {
            sidenoteFocusRequest = nil
        }
    }

    private var pdfTextNoteAlertPresented: Binding<Bool> {
        Binding(
            get: { pdfAnnotationSession.pendingTextNote != nil },
            set: { isPresented in
                if isPresented == false {
                    pdfAnnotationSession.cancelPendingTextNote()
                }
            }
        )
    }

    private var pdfAnnotationErrorAlertPresented: Binding<Bool> {
        Binding(
            get: { pdfAnnotationSession.errorMessage != nil },
            set: { isPresented in
                if isPresented == false {
                    pdfAnnotationSession.errorMessage = nil
                }
            }
        )
    }

    private var readerSurface: some View {
        VStack(spacing: 0) {
            if paper != nil {
                Divider()
                paneHeader
                Divider()

                if isFindBarVisible {
                    DocumentFindBar(
                        query: $findQuery,
                        options: $findOptions,
                        bilingualTarget: readerMode == .bilingualPDF ? $bilingualFindTarget : nil,
                        status: visibleFindStatus,
                        focusToken: findFocusToken,
                        onNext: { moveToFindMatch(.forward) },
                        onPrevious: { moveToFindMatch(.backward) },
                        onClose: closeFindBar
                    )
                    Divider()
                }

                if isEditingHTMLRegions {
                    HTMLRegionEditBar(
                        hiddenRegionCount: htmlRegionEditUpdate?.hiddenRegionCount ?? 0,
                        hiddenRegions: htmlRegionEditUpdate?.hiddenRegions ?? [],
                        canUndo: htmlRegionEditUpdate?.canUndo ?? false,
                        canRedo: htmlRegionEditUpdate?.canRedo ?? false,
                        onReveal: { path in htmlRegionEditCommand = HTMLRegionEditCommand(action: .reveal(path: path)) },
                        onUndo: { htmlRegionEditCommand = HTMLRegionEditCommand(action: .undo) },
                        onRedo: { htmlRegionEditCommand = HTMLRegionEditCommand(action: .redo) },
                        onRestoreAll: { htmlRegionEditCommand = HTMLRegionEditCommand(action: .restoreAll) },
                        onDone: finishHTMLRegionEditing
                    )
                    Divider()
                }
            }

            // A running translation shows in the floating activity capsule; this row
            // keeps what is left afterwards and needs attention, such as errors.
            if !isWorking, statusMessage != nil {
                statusRow
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(ReadPaperAppearanceHeaderSurface(role: .reader))

                Divider()
            }

            content

            if isNearTranslationEdge && !isWorking {
                translateMoreBanner
                Divider()
            }
        }
    }

    private var paneHeader: some View {
        HStack {
            if let paper {
                Text(paper.title)
                    .font(.system(
                        .subheadline,
                        design: pdfDisplayAppearance == .paper ? .serif : .default
                    ).weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)
        }
        .frame(minHeight: 20)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(ReadPaperAppearanceHeaderSurface(role: .reader))
    }

    @ToolbarContentBuilder
    private var readerToolbar: some ToolbarContent {
        if paper != nil {
            segmentedPickerToolbarItem {
                readerModePicker
            }

            // The HTML and PDF readers share these items, and each keeps the same kind of
            // control in both. When the toolbar changes otherwise, SwiftUI replaces items and
            // AppKit rebuilds the whole toolbar, which took nearly half of switching between
            // an HTML and a PDF paper.
            segmentedPickerToolbarItem {
                displayPicker
            }
            ToolbarItem(placement: .primaryAction) {
                readerToolsMenu
            }
            ToolbarItem(placement: .primaryAction) {
                pdfZoomControls
            }
            if readerMode == .html {
                ToolbarItem(placement: .primaryAction) {
                    htmlRegionEditButton
                }
            }

            ToolbarItemGroup(placement: .primaryAction) {
                findButton
                noteSelectionButton
                translationMenu
                #if DEBUG
                pdfTranslationDebugButton
                #endif
                exportMenu
            }

            if #available(macOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .primaryAction)
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    toggleInspectorCollapsed()
                } label: {
                    Label(
                        isInspectorCollapsed
                            ? String(localized: "Show Inspector", bundle: bundle)
                            : String(localized: "Hide Inspector", bundle: bundle),
                        systemImage: "sidebar.trailing"
                    )
                }
                .labelStyle(.iconOnly)
                .help(
                    isInspectorCollapsed
                        ? String(localized: "Show Inspector", bundle: bundle)
                        : String(localized: "Hide Inspector", bundle: bundle)
                )
            }
        }
    }

    private var findButton: some View {
        Button {
            showFindBar()
        } label: {
            Label(String(localized: "Find", bundle: bundle), systemImage: "magnifyingglass")
        }
        .labelStyle(.iconOnly)
        .keyboardShortcut("f", modifiers: .command)
        .disabled(isFindAvailable == false)
        .help(String(localized: "Find in Document", bundle: bundle))
    }

    /// Zooms the PDF, or steps the font size in HTML mode, so that the toolbar item keeps the
    /// same control when the mode changes.
    @ViewBuilder
    private var pdfZoomControls: some View {
        if showPDFZoomButtons {
            let isHTML = readerMode == .html
            ControlGroup {
                Button {
                    if isHTML {
                        decreaseHTMLReaderFontSize()
                    } else {
                        pdfAnnotationSession.zoomOut()
                    }
                } label: {
                    Label(String(localized: "Zoom Out", bundle: bundle), systemImage: "minus")
                }
                .labelStyle(.iconOnly)
                .disabled(isHTML && htmlReaderFontSize <= HTMLReaderTypography.fontSizeRange.lowerBound)
                .help(isHTML
                    ? String(localized: "Decrease Font Size", bundle: bundle)
                    : String(localized: "Zoom Out", bundle: bundle))

                Button {
                    if isHTML {
                        increaseHTMLReaderFontSize()
                    } else {
                        pdfAnnotationSession.zoomIn()
                    }
                } label: {
                    Label(String(localized: "Zoom In", bundle: bundle), systemImage: "plus")
                }
                .labelStyle(.iconOnly)
                .disabled(isHTML && htmlReaderFontSize >= HTMLReaderTypography.fontSizeRange.upperBound)
                .help(isHTML
                    ? String(localized: "Increase Font Size", bundle: bundle)
                    : String(localized: "Zoom In", bundle: bundle))
            }
            .onHover { isHovering in
                isHoveringPDFZoomControls = isHovering
            }
            // A control removed under the pointer never receives the hover exit.
            .onDisappear {
                isHoveringPDFZoomControls = false
            }
        }
    }

    private var pdfZoomHighlightAttachmentID: UUID? {
        guard readerMode == .bilingualPDF,
              showPDFZoomButtons,
              isHoveringPDFZoomControls
        else {
            return nil
        }
        return pdfAnnotationSession.activeAttachmentID ?? originalPDFAttachment?.id
    }

    private func showFindBar() {
        isFindBarVisible = true
        findFocusToken &+= 1
    }

    private func closeFindBar() {
        isFindBarVisible = false
        findStatus = nil
    }

    private func moveToFindMatch(_ direction: DocumentFindDirection) {
        // Return right after typing starts the search instead of skipping its first match.
        if committedFindQuery != findQuery {
            committedFindQuery = findQuery
            return
        }
        findNavigationDirection = direction
        findNavigationToken &+= 1
    }

    private func commitFindQueryAfterTyping() async {
        guard committedFindQuery != findQuery else { return }
        if findQuery.isEmpty == false {
            try? await Task.sleep(for: .milliseconds(200))
            guard Task.isCancelled == false else { return }
        }
        committedFindQuery = findQuery
    }

    private func handleFindStatusChange(_ status: DocumentFindStatus) {
        findStatus = status
    }

    private var noteSelectionButton: some View {
        Button {
            onCreateAnchoredNote()
        } label: {
            Label(String(localized: "Add Note", bundle: bundle), systemImage: "plus.circle")
                .labelStyle(.iconOnly)
        }
        .disabled(noteSelectionContext == nil)
        .help(noteSelectionButtonHelpText)
    }

    private var noteSelectionButtonHelpText: String {
        if noteSelectionContext != nil {
            return String(localized: "Add Note to Current Selection", bundle: bundle)
        }
        return String(localized: "Select text in PDF or HTML to attach a note.", bundle: bundle)
    }

    private var readerModePicker: some View {
        ReadPaperSegmentedPicker(
            label: String(localized: "Reader", bundle: bundle),
            selection: primaryReaderMode,
            options: [
                .init(value: .html, title: String(localized: "HTML", bundle: bundle)),
                .init(value: .pdf, title: String(localized: "PDF", bundle: bundle)),
            ],
            placement: .toolbar
        )
        .help(String(localized: "Switch between HTML and PDF reading", bundle: bundle))
    }

    /// Original, bilingual or translated: the HTML page's display mode, or the PDF reader.
    private var displayPicker: some View {
        let isHTML = readerMode == .html
        return ReadPaperSegmentedPicker(
            label: isHTML
                ? String(localized: "Display", bundle: bundle)
                : String(localized: "PDF Display", bundle: bundle),
            selection: displayChoice,
            options: [
                .init(value: .original, title: String(localized: "Original", bundle: bundle)),
                .init(value: .bilingual, title: String(localized: "Bilingual", bundle: bundle)),
                .init(value: .translated, title: String(localized: "Translated", bundle: bundle)),
            ],
            placement: .toolbar
        )
        .help(isHTML
            ? String(localized: "HTML Display Mode", bundle: bundle)
            : String(localized: "PDF Display Mode", bundle: bundle))
    }

    private var displayChoice: Binding<TranslationDisplayMode> {
        Binding(
            get: {
                readerMode == .html
                    ? displayMode
                    : TranslationDisplayMode(pdfReaderMode: pdfReaderModeSelection.wrappedValue)
            },
            set: { choice in
                if readerMode == .html {
                    displayMode = choice
                } else {
                    pdfReaderModeSelection.wrappedValue = choice.pdfReaderMode
                }
            }
        )
    }

    /// The typography menu in HTML mode and the annotation menu otherwise, as one menu so
    /// that its toolbar item is not replaced when the mode changes.
    private var readerToolsMenu: some View {
        let isHTML = readerMode == .html
        let fontSize = Int(HTMLReaderTypography.clampFontSize(htmlReaderFontSize).rounded())
        return Menu {
            if isHTML {
                htmlTypographyMenuItems
            } else {
                pdfAnnotationMenuItems
            }
        } label: {
            Label(
                isHTML
                    ? String(format: String(localized: "Font Size: %d", bundle: bundle), fontSize)
                    : String(localized: "PDF Annotations", bundle: bundle),
                systemImage: isHTML ? "textformat.size" : pdfAnnotationToolSystemImage
            )
            .labelStyle(.iconOnly)
            .foregroundStyle(
                isHTML || pdfAnnotationSession.interactionMode == .browse
                    ? Color.primary
                    : Color.accentColor
            )
        }
        .menuIndicator(isHTML ? .automatic : .hidden)
        .disabled(isHTML ? false : pdfAnnotationSession.isDebugInteractionActive)
        .help(isHTML
            ? String(format: String(localized: "HTML Font Size: %d", bundle: bundle), fontSize)
            : String(localized: "PDF Annotations", bundle: bundle))
    }

    @ViewBuilder
    private var htmlTypographyMenuItems: some View {
        Button {
            decreaseHTMLReaderFontSize()
        } label: {
            Label(String(localized: "Decrease Font Size", bundle: bundle), systemImage: "minus")
        }
        .disabled(htmlReaderFontSize <= HTMLReaderTypography.fontSizeRange.lowerBound)

        Button {
            increaseHTMLReaderFontSize()
        } label: {
            Label(String(localized: "Increase Font Size", bundle: bundle), systemImage: "plus")
        }
        .disabled(htmlReaderFontSize >= HTMLReaderTypography.fontSizeRange.upperBound)

        Divider()

        Button {
            resetHTMLReaderFontSize()
        } label: {
            Label(String(localized: "Reset Font Size", bundle: bundle), systemImage: "arrow.counterclockwise")
        }
        .disabled(htmlReaderFontSize == HTMLReaderTypography.defaultFontSize)
    }

    private var htmlRegionEditButton: some View {
        Button {
            toggleHTMLRegionEditing()
        } label: {
            Label(
                String(localized: "Edit Regions", bundle: bundle),
                systemImage: "rectangle.and.pencil.and.ellipsis"
            )
                .labelStyle(.iconOnly)
                .foregroundStyle(isEditingHTMLRegions ? Color.accentColor : Color.primary)
        }
        .disabled(htmlAttachment == nil || (isWorking && isEditingHTMLRegions == false))
        .help(htmlRegionEditHelpText)
    }

    private var htmlRegionEditHelpText: String {
        if isEditingHTMLRegions {
            return String(localized: "Finish Editing Regions", bundle: bundle)
        }
        if isWorking {
            return String(localized: "Regions can't be edited while a translation is running.", bundle: bundle)
        }
        if htmlHiddenRegionCount > 0 {
            return AppLocalization.format("Hide or restore parts of this page (%lld hidden)", bundle: bundle, htmlHiddenRegionCount)
        }
        return String(localized: "Hide or restore parts of this page", bundle: bundle)
    }

    private var htmlRegionEditLabels: HTMLRegionEditLabels {
        HTMLRegionEditLabels(
            hide: String(localized: "Hide", bundle: bundle),
            restore: String(localized: "Restore", bundle: bundle),
            kinds: [
                "paragraph": String(localized: "Paragraph", bundle: bundle),
                "heading": String(localized: "Heading", bundle: bundle),
                "list": String(localized: "List", bundle: bundle),
                "listItem": String(localized: "List Item", bundle: bundle),
                "quote": String(localized: "Quote", bundle: bundle),
                "code": String(localized: "Code", bundle: bundle),
                "formula": String(localized: "Formula", bundle: bundle),
                "table": String(localized: "Table", bundle: bundle),
                "image": String(localized: "Image", bundle: bundle),
                "media": String(localized: "Media", bundle: bundle),
                "link": String(localized: "Link", bundle: bundle),
                "text": String(localized: "Text", bundle: bundle),
                "block": String(localized: "Block", bundle: bundle),
            ],
            // The page script fills in the placeholders.
            regions: AppLocalization.format("%@ regions", bundle: bundle, "{count}")
        )
    }

    private func toggleHTMLRegionEditing() {
        if isEditingHTMLRegions {
            finishHTMLRegionEditing()
            return
        }
        guard readerMode == .html, htmlAttachment != nil, isWorking == false else { return }
        noteSelectionContext = nil
        clearSelectionAssistant()
        htmlRegionEditUpdate = nil
        htmlRegionEditCommand = nil
        isEditingHTMLRegions = true
    }

    private func finishHTMLRegionEditing() {
        isEditingHTMLRegions = false
        htmlRegionEditUpdate = nil
        // A recreated reader would otherwise replay the last bar command in the next session.
        htmlRegionEditCommand = nil
        flushHTMLRegionChanges()
    }

    private func handleHTMLRegionEditEvent(_ event: HTMLRegionEditEvent) {
        switch event {
        case .exitRequested:
            finishHTMLRegionEditing()
        case let .loaded(documentURL, hiddenRegionCount):
            guard let fileURL = htmlAttachment?.fileURL,
                  Self.isFile(fileURL, sameAs: documentURL) else { return }
            htmlHiddenRegionCount = hiddenRegionCount
        case let .updated(update):
            // Only the page currently shown may change its own file.
            guard let fileURL = htmlAttachment?.fileURL,
                  Self.isFile(fileURL, sameAs: update.documentURL) else { return }
            htmlHiddenRegionCount = update.hiddenRegionCount
            if isEditingHTMLRegions {
                htmlRegionEditUpdate = update
            }
            if update.changes.isEmpty == false {
                queueHTMLRegionChanges(update.changes, for: fileURL)
            }
        }
    }

    private func queueHTMLRegionChanges(_ changes: [HTMLRegionChange], for fileURL: URL) {
        if let pending = pendingHTMLRegionChanges, pending.fileURL != fileURL {
            flushHTMLRegionChanges()
        }
        var pending = pendingHTMLRegionChanges ?? PendingHTMLRegionChanges(fileURL: fileURL)
        for change in changes {
            pending.changesByPath[change.path] = change
        }
        pendingHTMLRegionChanges = pending
        // Rewriting paper.html parses the whole page, so quick successive edits are saved together.
        htmlRegionSaveTask?.cancel()
        htmlRegionSaveTask = Task { @MainActor in
            try? await Task.sleep(for: Self.htmlRegionSaveDelay)
            guard Task.isCancelled == false else { return }
            flushHTMLRegionChanges()
        }
    }

    private func flushHTMLRegionChanges() {
        htmlRegionSaveTask?.cancel()
        htmlRegionSaveTask = nil
        guard let pending = pendingHTMLRegionChanges else { return }
        pendingHTMLRegionChanges = nil
        let fileURL = pending.fileURL
        HTMLRegionWriter.shared.write(Array(pending.changesByPath.values), toFileAt: fileURL) { result in
            switch result {
            case let .success(update):
                guard update.unmatchedChanges.isEmpty == false else { return }
                statusMessage = AppLocalization.format(
                    "%lld region changes could not be matched to the saved page and were not saved.",
                    bundle: bundle,
                    update.unmatchedChanges.count
                )
            case let .failure(error):
                statusMessage = AppLocalization.errorMessage(error, bundle: bundle)
            }
            // Show what was actually saved.
            if htmlAttachment?.fileURL == fileURL {
                htmlReloadToken += 1
            }
        }
    }

    private static func isFile(_ fileURL: URL, sameAs documentURLString: String?) -> Bool {
        guard let documentURLString,
              let documentURL = URL(string: documentURLString),
              documentURL.isFileURL else {
            return false
        }
        return documentURL.standardizedFileURL.path == fileURL.standardizedFileURL.path
    }

    private func decreaseHTMLReaderFontSize() {
        htmlReaderFontSize = HTMLReaderTypography.clampFontSize(htmlReaderFontSize - 1)
    }

    private func increaseHTMLReaderFontSize() {
        htmlReaderFontSize = HTMLReaderTypography.clampFontSize(htmlReaderFontSize + 1)
    }

    private func resetHTMLReaderFontSize() {
        htmlReaderFontSize = HTMLReaderTypography.defaultFontSize
    }

    private func toggleInspectorCollapsed() {
        withAnimation(.easeInOut(duration: 0.18)) {
            isInspectorCollapsed.toggle()
        }
    }

    @ViewBuilder
    private var pdfAnnotationMenuItems: some View {
        annotationModeButton(
            .browse,
            title: String(localized: "Browse", bundle: bundle),
            systemImage: "cursorarrow"
        )
        annotationModeButton(
            .ink,
            title: String(localized: "Freehand Draw", bundle: bundle),
            systemImage: "pencil.tip"
        )
        annotationModeButton(
            .textNote,
            title: String(localized: "Place PDF Note", bundle: bundle),
            systemImage: "note.text.badge.plus"
        )
        annotationModeButton(
            .erase,
            title: String(localized: "Erase Annotation", bundle: bundle),
            systemImage: "eraser"
        )

        Divider()

        Button {
            pdfAnnotationSession.applyTextMarkup(.highlight)
        } label: {
            Label(String(localized: "Highlight Selection", bundle: bundle), systemImage: "highlighter")
        }
        .disabled(pdfAnnotationSession.hasTextSelection == false)

        Button {
            pdfAnnotationSession.applyTextMarkup(.underline)
        } label: {
            Label(String(localized: "Underline Selection", bundle: bundle), systemImage: "underline")
        }
        .disabled(pdfAnnotationSession.hasTextSelection == false)

        Button {
            pdfAnnotationSession.applyTextMarkup(.strikeOut)
        } label: {
            Label(String(localized: "Strike Through Selection", bundle: bundle), systemImage: "strikethrough")
        }
        .disabled(pdfAnnotationSession.hasTextSelection == false)

        Divider()

        Menu(String(localized: "Annotation Color", bundle: bundle)) {
            annotationColorButton(.yellow, title: String(localized: "Yellow", bundle: bundle))
            annotationColorButton(.green, title: String(localized: "Green", bundle: bundle))
            annotationColorButton(.blue, title: String(localized: "Blue", bundle: bundle))
            annotationColorButton(.red, title: String(localized: "Red", bundle: bundle))
            annotationColorButton(.purple, title: String(localized: "Purple", bundle: bundle))
        }

        Menu(String(localized: "Drawing Width", bundle: bundle)) {
            annotationLineWidthButton(
                PDFAnnotationLineWidthPreset.thin,
                title: String(localized: "Thin", bundle: bundle)
            )
            annotationLineWidthButton(
                PDFAnnotationLineWidthPreset.medium,
                title: String(localized: "Medium", bundle: bundle)
            )
            annotationLineWidthButton(
                PDFAnnotationLineWidthPreset.thick,
                title: String(localized: "Thick", bundle: bundle)
            )
        }

        Divider()

        Button {
            pdfAnnotationSession.undo()
        } label: {
            Label(String(localized: "Undo PDF Annotation", bundle: bundle), systemImage: "arrow.uturn.backward")
        }
        .keyboardShortcut("z", modifiers: .command)
        .disabled(pdfAnnotationSession.canUndo == false)

        Button {
            pdfAnnotationSession.redo()
        } label: {
            Label(String(localized: "Redo PDF Annotation", bundle: bundle), systemImage: "arrow.uturn.forward")
        }
        .keyboardShortcut("z", modifiers: [.command, .shift])
        .disabled(pdfAnnotationSession.canRedo == false)
    }

    private var pdfAnnotationToolSystemImage: String {
        switch pdfAnnotationSession.interactionMode {
        case .browse: return "pencil.tip.crop.circle"
        case .ink: return "pencil.tip"
        case .textNote: return "note.text.badge.plus"
        case .erase: return "eraser.fill"
        case .debugRegion: return "ladybug"
        }
    }

    private func annotationModeButton(
        _ mode: PDFInteractionMode,
        title: String,
        systemImage: String
    ) -> some View {
        Button {
            pdfAnnotationSession.selectInteractionMode(mode)
        } label: {
            Label(
                title,
                systemImage: pdfAnnotationSession.interactionMode == mode
                    ? "checkmark.circle.fill"
                    : systemImage
            )
        }
    }

    private func annotationColorButton(
        _ preset: PDFAnnotationColorPreset,
        title: String
    ) -> some View {
        Button {
            pdfAnnotationSession.colorPreset = preset
        } label: {
            Label(
                title,
                systemImage: pdfAnnotationSession.colorPreset == preset
                    ? "checkmark.circle.fill"
                    : "circle.fill"
            )
        }
    }

    private func annotationLineWidthButton(_ width: Double, title: String) -> some View {
        Button {
            pdfAnnotationSession.lineWidth = width
        } label: {
            Label(
                title,
                systemImage: pdfAnnotationSession.lineWidth == width
                    ? "checkmark.circle.fill"
                    : "line.diagonal"
            )
        }
    }

    private var translationMenu: some View {
        Menu {
            Button {
                translateHTML()
            } label: {
                Label(String(localized: "Translate HTML", bundle: bundle), systemImage: "globe")
                    .labelStyle(.titleAndIcon)
            }
            .disabled(canTranslateHTML == false)

            Button {
                translatePDF()
            } label: {
                if isPartialPDFTranslation && !isScanRebuildTranslation {
                    Label(String(localized: "Translate More PDF Pages", bundle: bundle), systemImage: "doc")
                        .labelStyle(.titleAndIcon)
                } else if isFullPDFTranslationComplete {
                    Label(String(localized: "Retranslate PDF", bundle: bundle), systemImage: "arrow.clockwise")
                        .labelStyle(.titleAndIcon)
                } else {
                    Label(String(localized: "Translate PDF", bundle: bundle), systemImage: "doc")
                        .labelStyle(.titleAndIcon)
                }
            }
            .disabled(canTranslateTextPDF == false)

            Button {
                offerScannedPDFTranslation(hasNoTextLayer: false)
            } label: {
                Label(String(localized: "Translate Scanned PDF…", bundle: bundle), systemImage: "doc.viewfinder")
                    .labelStyle(.titleAndIcon)
            }
            .disabled(canTranslatePDF == false)

            if latexTranslationEnabled {
                Button {
                    translateLaTeX()
                } label: {
                    Label(String(localized: "Translate arXiv LaTeX", bundle: bundle), systemImage: "text.document")
                        .labelStyle(.titleAndIcon)
                }
                .disabled(canTranslateLaTeX == false)
            }
        } label: {
            Label(String(localized: "Translate", bundle: bundle), systemImage: "translate")
                .labelStyle(.iconOnly)
        }
        .menuIndicator(.hidden)
        .disabled(translationControlsDisabled)
        .help(translationMenuHelpText)
    }

    #if DEBUG
    private var pdfTranslationDebugButton: some View {
        Button {
            togglePDFTranslationDebugMode()
        } label: {
            Label(
                String(localized: "PDF Translation Debug Export", bundle: bundle),
                systemImage: pdfDebugModeEnabled ? "ladybug.fill" : "ladybug"
            )
            .labelStyle(.iconOnly)
            .foregroundStyle(pdfDebugModeEnabled ? Color.accentColor : Color.primary)
        }
        .disabled(translatedPDFAttachment == nil || isWorking)
        .help(
            pdfDebugModeEnabled
                ? String(localized: "Disable PDF translation debug export", bundle: bundle)
                : String(localized: "Enable PDF translation debug export", bundle: bundle)
        )
    }

    private func togglePDFTranslationDebugMode() {
        if pdfDebugModeEnabled {
            deactivatePDFTranslationDebugMode()
            statusMessage = String(localized: "PDF translation debug export disabled.", bundle: bundle)
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose", bundle: bundle)
        panel.message = String(
            localized: "Choose a folder, then drag a rectangle over an issue in the translated PDF. Each selection is exported automatically.",
            bundle: bundle
        )
        panel.directoryURL = pdfDebugExportDirectoryURL

        guard panel.runModal() == .OK, let directoryURL = panel.url else { return }

        deactivatePDFTranslationDebugMode()
        pdfDebugExportDirectoryURL = directoryURL
        pdfDebugDirectoryHasSecurityScope = directoryURL.startAccessingSecurityScopedResource()
        pdfDebugModeEnabled = true
        pdfAnnotationSession.beginDebugInteraction()
        if readerMode != .bilingualPDF && readerMode != .translatedPDF {
            readerMode = .translatedPDF
        }
        statusMessage = String(
            localized: "PDF debug export is active. Drag over an issue in the translated PDF.",
            bundle: bundle
        )
    }
    #endif

    private func deactivatePDFTranslationDebugMode() {
        if pdfDebugDirectoryHasSecurityScope {
            pdfDebugExportDirectoryURL?.stopAccessingSecurityScopedResource()
        }
        pdfDebugDirectoryHasSecurityScope = false
        pdfDebugModeEnabled = false
        pdfDebugExportDirectoryURL = nil
        pdfAnnotationSession.endDebugInteraction()
    }

    private func handlePDFDebugRegionSelection(_ selection: PDFDebugRegionSelection) {
        #if DEBUG
        guard pdfDebugModeEnabled,
              let directoryURL = pdfDebugExportDirectoryURL,
              let paper,
              let translatedAttachment = translatedPDFAttachment
        else {
            return
        }

        let translatedURL = translatedAttachment.fileURL
        let request = PDFTranslationDebugExportRequest(
            paperID: paper.id,
            paperTitle: paper.title,
            arxivID: paper.arxivID,
            doi: paper.doi,
            originalAttachmentID: pdfAttachment?.id,
            translatedAttachmentID: translatedAttachment.id,
            originalPDFURL: pdfAttachment?.fileURL,
            translatedPDFURL: translatedURL,
            diagnosticsURL: BabelDocRunner.diagnosticsURL(for: translatedURL),
            translatedLastPage: translatedAttachment.translatedLastPage,
            selection: selection
        )

        do {
            let exportURL = try PDFTranslationDebugExporter().export(request, to: directoryURL)
            statusMessage = AppLocalization.format(
                "PDF debug bundle exported to %@.",
                bundle: bundle,
                exportURL.path
            )
        } catch {
            statusMessage = AppLocalization.errorMessage(error, bundle: bundle)
        }
        #else
        _ = selection
        #endif
    }

    private var exportMenu: some View {
        Menu {
            Button {
                copyLink()
            } label: {
                Label(String(localized: "Copy Link", bundle: bundle), systemImage: "link")
                    .labelStyle(.titleAndIcon)
            }
            .disabled(sourceLinkURL == nil)

            Button {
                copyDigest()
            } label: {
                Label(String(localized: "Copy Digest", bundle: bundle), systemImage: "doc.on.doc")
                    .labelStyle(.titleAndIcon)
            }

            Button {
                exportDigest()
            } label: {
                Label(String(localized: "Export Markdown", bundle: bundle), systemImage: "square.and.arrow.up")
                    .labelStyle(.titleAndIcon)
            }

            if readerMode == .html {
                Divider()

                Button {
                    exportHTMLPDF()
                } label: {
                    Label(String(localized: "Export HTML as PDF", bundle: bundle), systemImage: "doc.badge.arrow.up")
                        .labelStyle(.titleAndIcon)
                }
                .disabled(htmlAttachment == nil || isExportingHTMLPDF)
            } else {
                Divider()

                Button {
                    exportAnnotatedPDF()
                } label: {
                    Label(String(localized: "Export Annotated PDF", bundle: bundle), systemImage: "doc.badge.arrow.up")
                        .labelStyle(.titleAndIcon)
                }
                .disabled(currentPDFAnnotationExportAttachment == nil)
            }
        } label: {
            if isExportingHTMLPDF {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(Text("Exporting PDF…", bundle: bundle))
            } else {
                Label(String(localized: "Share", bundle: bundle), systemImage: "square.and.arrow.up")
                    .labelStyle(.iconOnly)
            }
        }
        .menuIndicator(.hidden)
        .help(isExportingHTMLPDF
              ? String(localized: "Exporting PDF…", bundle: bundle)
              : String(localized: "Share Paper", bundle: bundle))
    }

    private func exportHTMLPDF() {
        guard let paper, let attachment = htmlAttachment, !isExportingHTMLPDF else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let title = paper.title.components(separatedBy: CharacterSet(charactersIn: "/:\n\r"))
            .filter { !$0.isEmpty }.joined(separator: "-")
        panel.nameFieldStringValue = (title.isEmpty ? "paper" : String(title.prefix(120))) + ".pdf"
        panel.prompt = String(localized: "Export", bundle: bundle)
        panel.message = String(localized: "Export the HTML using the current original, bilingual, or translated display mode.", bundle: bundle)
        guard panel.runModal() == .OK, let destinationURL = panel.url else { return }

        flushHTMLRegionChanges()
        let sourceURL = attachment.fileURL
        let exportDisplayMode = displayMode
        let exportFontSize = htmlReaderFontSize
        isExportingHTMLPDF = true
        Task { @MainActor in
            defer { isExportingHTMLPDF = false }
            await HTMLRegionWriter.shared.waitForQueuedWrites()
            do {
                try await HTMLPDFExporter().export(
                    sourceURL: sourceURL,
                    displayMode: exportDisplayMode,
                    fontSize: exportFontSize,
                    destinationURL: destinationURL
                )
                showCopyToast(message: AppLocalization.format(
                    "PDF exported to %@.",
                    bundle: bundle,
                    destinationURL.lastPathComponent
                ))
            } catch {
                htmlPDFExportError = AppLocalization.errorMessage(error, bundle: bundle)
            }
        }
    }

    private var currentPDFAnnotationExportAttachment: PaperAttachment? {
        let visibleAttachments: [PaperAttachment]
        switch readerMode {
        case .html:
            return nil
        case .pdf:
            visibleAttachments = [pdfAttachment].compactMap { $0 }
        case .translatedPDF:
            visibleAttachments = [translatedPDFAttachment].compactMap { $0 }
        case .bilingualPDF:
            visibleAttachments = [pdfAttachment, translatedPDFAttachment].compactMap { $0 }
        }

        if let activeAttachmentID = pdfAnnotationSession.activeAttachmentID,
           let activeAttachment = visibleAttachments.first(where: { $0.id == activeAttachmentID }) {
            return activeAttachment
        }
        return visibleAttachments.first
    }

    private func exportAnnotatedPDF() {
        guard let paper, let attachment = currentPDFAnnotationExportAttachment else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = attachment.fileURL
            .deletingPathExtension()
            .lastPathComponent + "-annotated.pdf"
        panel.prompt = String(localized: "Export", bundle: bundle)

        guard panel.runModal() == .OK, let destinationURL = panel.url else { return }

        do {
            let annotationCount = try PDFAnnotationExporter().export(
                sourcePDFURL: attachment.fileURL,
                paperID: paper.id,
                attachmentID: attachment.id,
                destinationURL: destinationURL
            )
            digestNoticeTitle = String(localized: "PDF Exported", bundle: bundle)
            digestNoticeMessage = AppLocalization.format(
                "%d PDF annotations exported to %@.",
                bundle: bundle,
                annotationCount,
                destinationURL.lastPathComponent
            )
        } catch {
            pdfAnnotationSession.report(error)
        }
    }

    private var sourceLinkURL: URL? {
        guard let paper else { return nil }
        return PaperDigestExportPolicy.makeSourceURL(paper: paper)
    }

    private func copyLink() {
        digestErrorMessage = nil
        guard let sourceLinkURL else { return }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sourceLinkURL.absoluteString, forType: .string)
        showCopyToast(message: String(localized: "Link copied to the clipboard.", bundle: bundle))
    }

    private var quoteInWritingAction: QuoteInWritingAction? {
        guard paper != nil, let selection = noteSelectionContext, selection.trimmedQuote != nil else {
            return nil
        }
        return QuoteInWritingAction {
            quoteInWriting(selection, citeOnly: false)
        }
    }

    /// Adds the selected passage to the writing open in the inspector's Writing tab, as
    /// a block quote with a citation linking back here, or with `citeOnly` just the citation.
    @MainActor
    private func quoteInWriting(_ selection: NoteSelectionContext, citeOnly: Bool) {
        guard let paper, let quote = selection.trimmedQuote else { return }
        let label = PaperCitation.label(
            authors: paper.authors,
            title: paper.title,
            year: paper.publishedAt.map { Calendar(identifier: .gregorian).component(.year, from: $0) },
            pageIndex: selection.pageIndex
        )
        do {
            let title = try WritingDocumentCenter.shared.insertCitation(
                PaperCitation(paperID: paper.id, selection: selection),
                label: label,
                quote: citeOnly ? nil : quote
            )
            clearSelectionAssistant()
            showCopyToast(message: AppLocalization.format(
                citeOnly ? "Cited in “%@”." : "Quoted in “%@”.",
                bundle: bundle,
                title.isEmpty ? String(localized: "Untitled Writing", bundle: bundle) : title
            ))
        } catch {
            writingQuoteErrorMessage = error.localizedDescription
        }
    }

    /// Passages of this paper cited in writings.
    private var citationMarks: [WritingCitationMark] {
        guard let paper else { return [] }
        return writingLibrary.citationMarks(for: paper.id)
    }

    /// A click on a cited passage opens the writing citing it, or offers a menu when
    /// several writings cite it.
    @MainActor
    private func handleCitationMarksActivated(_ ids: [String]) {
        let marks = citationMarks.filter { ids.contains($0.id) }
        var seenWritings = Set<UUID>()
        let writingOrder = writingLibrary.writings.map(\.id)
        let choices = marks
            .filter { seenWritings.insert($0.writingID).inserted }
            .sorted { (writingOrder.firstIndex(of: $0.writingID) ?? .max) < (writingOrder.firstIndex(of: $1.writingID) ?? .max) }
        guard let first = choices.first else { return }
        guard choices.count > 1 else {
            onRevealCitation(first)
            return
        }

        let menu = NSMenu()
        let heading = NSMenuItem(title: String(localized: "Cited In", bundle: bundle), action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        let target = CitationMenuTarget(onSelect: onRevealCitation)
        for mark in choices {
            let title = writingLibrary.metadata(for: mark.writingID)?.title ?? ""
            let item = NSMenuItem(
                title: title.isEmpty ? String(localized: "Untitled Writing", bundle: bundle) : title,
                action: #selector(CitationMenuTarget.select(_:)),
                keyEquivalent: ""
            )
            item.target = target
            item.representedObject = mark.id
            target.marks[mark.id] = mark
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private func showCopyToast(message: String) {
        copyToastDismissTask?.cancel()
        copyToastMessage = message
        copyToastDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard Task.isCancelled == false else { return }
            withAnimation(.easeIn(duration: 0.18)) {
                copyToastMessage = nil
            }
            copyToastDismissTask = nil
        }
    }

    private func dismissCopyToast() {
        copyToastDismissTask?.cancel()
        copyToastDismissTask = nil
        copyToastMessage = nil
    }

    private func copyToast(message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(message)
                .font(.callout.weight(.medium))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .readPaperGlassEffect(in: Capsule())
        .shadow(color: .black.opacity(0.14), radius: 10, y: 4)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }

    private func copyDigest() {
        digestErrorMessage = nil
        guard let content = makeDigestContent() else { return }

        let markdown = PaperDigestExportPolicy.makeMarkdown(
            content: content,
            bundle: bundle,
            template: PaperDigestExportConfiguration().template
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown, forType: .string)
        showCopyToast(message: String(localized: "Digest copied to the clipboard.", bundle: bundle))
    }

    private func exportDigest() {
        digestErrorMessage = nil
        guard let content = makeDigestContent() else { return }

        do {
            let targetURL = try PaperDigestExporter().export(content: content, bundle: bundle)
            digestNoticeTitle = String(localized: "Digest Ready", bundle: bundle)
            digestNoticeMessage = String(
                format: String(localized: "Digest exported to %@.", bundle: bundle),
                targetURL.lastPathComponent
            )
        } catch {
            digestErrorMessage = error.localizedDescription
        }
    }

    private func makeDigestContent() -> PaperDigestContent? {
        guard let paper else { return nil }

        do {
            try modelContext.save()
        } catch {
            digestErrorMessage = error.localizedDescription
            return nil
        }

        guard let content = PaperDigestExportPolicy.makeContent(paper: paper, notes: notes) else {
            digestErrorMessage = String(localized: "This paper does not have enough metadata to create a digest.", bundle: bundle)
            return nil
        }
        return content
    }

    private var translationMenuHelpText: String {
        if isWorking {
            return String(localized: "Translation in Progress", bundle: bundle)
        }
        if canTranslateLaTeX {
            return String(localized: "Translate HTML, PDF, or arXiv LaTeX", bundle: bundle)
        }
        if canTranslateHTML && canTranslatePDF {
            return String(localized: "Translate HTML or PDF", bundle: bundle)
        }
        if canTranslateHTML {
            return String(localized: "Translate HTML", bundle: bundle)
        }
        if canTranslatePDF {
            return String(localized: "Translate PDF", bundle: bundle)
        }
        return String(localized: "Translation Unavailable", bundle: bundle)
    }

    @ViewBuilder
    private var content: some View {
        ZStack(alignment: .bottom) {
            Group {
                if paper == nil {
                    emptyReaderState
                } else {
                    switch readerMode {
                    case .html:
                        if let htmlFileURL = htmlAttachment?.fileURL {
                            HTMLReaderView(
                                fileURL: htmlFileURL,
                                attachmentID: htmlAttachment?.id,
                                displayMode: displayMode,
                                displayAppearance: pdfDisplayAppearance,
                                fontSize: htmlReaderFontSize,
                                reloadToken: htmlReloadToken,
                                initialScrollRatio: restoredHTMLScrollRatio,
                                scrollRatio: $htmlScrollRatio,
                                segmentUpdate: htmlSegmentUpdate,
                                noteNavigationRequest: noteNavigationRequest,
                                selectionAssistantHistoryAnchors: selectionAssistantHistoryAnchors,
                                citationMarks: citationMarks,
                                onCitationMarksActivated: handleCitationMarksActivated,
                                selectionHighlightResetToken: htmlSelectionHighlightResetToken,
                                nativeSelectionClearToken: htmlNativeSelectionClearToken,
                                onNoteSelectionChanged: handleNoteSelectionChange,
                                onSelectionAssistantDismissed: handleHTMLSelectionAssistantDismissal,
                                findRequest: findRequest,
                                onFindStatusChanged: handleFindStatusChange,
                                sidenotes: HTMLSidenote.sidenotes(from: notes, attachmentID: htmlAttachment?.id),
                                sidenoteLabels: sidenoteLabels,
                                renderSidenoteMarkdown: NoteMarkdownRenderer.html,
                                sidenoteFocusRequest: sidenoteFocusRequest,
                                onSidenoteEvent: handleSidenoteEvent,
                                onSidenoteFocusHandled: handleSidenoteFocusHandled,
                                isRegionEditing: isEditingHTMLRegions,
                                regionEditLabels: htmlRegionEditLabels,
                                regionEditCommand: htmlRegionEditCommand,
                                onRegionEditEvent: handleHTMLRegionEditEvent
                            )
                        } else {
                            centeredUnavailableView(
                                String(localized: "No HTML available", bundle: bundle),
                                systemImage: "doc.text",
                                description: Text("Import an arXiv paper or web page with HTML content to read it here.", bundle: bundle)
                            )
                        }
                    case .pdf:
                        labeledPDFReader(
                            fileURL: originalPDFAttachment?.fileURL,
                            attachmentID: originalPDFAttachment?.id,
                            includesUnattributedSidenotes: true,
                            label: String(localized: "Original", bundle: bundle),
                            showsOriginalVersionMenu: true,
                            emptyTitle: String(localized: "No PDF available", bundle: bundle),
                            emptyDescription: String(localized: "Import a PDF or fetch one from arXiv to read it here.", bundle: bundle)
                        )
                    case .bilingualPDF:
                        if translatedPDFAttachment != nil {
                            DualPDFReaderView(
                                paperID: paper?.id,
                                originalURL: originalPDFAttachment?.fileURL,
                                originalAttachmentID: originalPDFAttachment?.id,
                                originalLabel: scanTranscriptionAttachment == nil ? nil : AnyView(originalVersionMenu),
                                translatedURL: translatedPDFAttachment?.fileURL,
                                translatedAttachmentID: translatedPDFAttachment?.id,
                                translatedLastPage: translatedPDFAttachment?.translatedLastPage,
                                displayAppearance: pdfDisplayAppearance,
                                pageIndex: pdfPageIndexBinding,
                                reloadToken: pdfReloadToken,
                                noteNavigationRequest: noteNavigationRequest,
                                selectionAssistantHistoryAnchors: selectionAssistantHistoryAnchors,
                                citationMarks: citationMarks,
                                onCitationMarksActivated: handleCitationMarksActivated,
                                annotationSession: pdfAnnotationSession,
                                handToolEnabled: pdfHandToolEnabled,
                                zoomHighlightAttachmentID: pdfZoomHighlightAttachmentID,
                                debugRegionSelectionEnabled: pdfDebugModeEnabled,
                                onDebugRegionSelected: handlePDFDebugRegionSelection,
                                onNoteSelectionChanged: handleNoteSelectionChange,
                                onArxivLinkActivated: onArxivLinkActivated,
                                findRequest: findRequest,
                                findTarget: bilingualFindTarget,
                                onFindStatusChanged: handleFindStatusChange
                            )
                        } else {
                            centeredUnavailableView(
                                String(localized: "No translated PDF", bundle: bundle),
                                systemImage: "character.book.closed",
                                description: Text("Run PDF translation first to compare the original and translated versions side by side.", bundle: bundle)
                            )
                        }
                    case .translatedPDF:
                        labeledPDFReader(
                            fileURL: translatedPDFAttachment?.fileURL,
                            attachmentID: translatedPDFAttachment?.id,
                            includesUnattributedSidenotes: false,
                            label: String(localized: "Translation", bundle: bundle),
                            emptyTitle: String(localized: "No translated PDF", bundle: bundle),
                            emptyDescription: String(localized: "Run PDF translation first to read the translated PDF on its own.", bundle: bundle),
                            reloadToken: pdfReloadToken,
                            debugRegionSelectionEnabled: pdfDebugModeEnabled,
                            onDebugRegionSelected: handlePDFDebugRegionSelection
                        )
                    }
                }
            }

            if let selection = selectionAssistantSelection,
               selection.trimmedQuote != nil,
               paper != nil {
                SelectionAssistantOverlay(
                    selection: selection,
                    progress: selectionAssistantProgress,
                    initialConversation: selectionAssistantInitialConversation,
                    perform: performSelectionAssistantRequest,
                    saveAsNote: onSaveSelectionAssistantNote,
                    onSourceActivated: activateSelectionAssistantSource,
                    onConversationChanged: persistSelectionAssistantConversation,
                    onInteractionBegan: pinSelectionAssistant,
                    onDismiss: clearSelectionAssistant,
                    quoteInWriting: quoteInWriting
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(10)
            }
        }
        .animation(.easeOut(duration: 0.18), value: selectionAssistantSelection != nil)
    }

    @MainActor
    private func performSelectionAssistantRequest(
        _ request: SelectionAssistantRequest,
        onPartialAnswer: @escaping @MainActor (String) -> Void
    ) async throws -> SelectionAssistantResult {
        guard let paper, let settings else {
            throw LLMProviderError.invalidConfiguration(
                String(localized: "Translation settings are unavailable.", bundle: bundle)
            )
        }
        let route = try LLMRouteResolver().resolveAssistantRoute(
            settings: settings,
            modelContext: modelContext
        )
        selectionAssistantProgress = .collectingPaperContext
        defer {
            selectionAssistantProgress = nil
        }
        guard let selection = selectionAssistantSelection else {
            throw LLMProviderError.invalidConfiguration(
                String(localized: "Select some text before using the reading assistant.", bundle: bundle)
            )
        }
        return try await SelectionAssistantOrchestrator().perform(
            request,
            selection: selection,
            paper: paper,
            attachments: attachments,
            notes: notes,
            targetLanguage: settings.targetLanguage,
            route: route,
            onProgress: { progress in
                selectionAssistantProgress = progress
            },
            onPartialAnswer: { partialAnswer in
                await onPartialAnswer(partialAnswer)
            }
        )
    }

    @MainActor
    private func activateSelectionAssistantSource(_ source: AssistantSource) {
        pinSelectionAssistant()
        if let request = source.navigationRequest {
            noteNavigationRequest = request
            return
        }
        guard let urlString = source.urlString,
              let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            Text(statusMessage ?? "")
                .font(.caption)
                .foregroundStyle(AppLocalization.isErrorMessage(statusMessage, bundle: bundle) ? .red : .secondary)
                .lineLimit(1)

            Spacer(minLength: 0)

            if translationSetupErrorMessage != nil, translationSetupErrorMessage == statusMessage {
                Button(String(localized: "Set Up Translation…", bundle: bundle)) {
                    TranslationSetupNavigation.showQuickSetup(using: openSettings)
                }
                .buttonStyle(.link)
                .font(.caption)
            }

            if pdfTranslationErrorLogURL != nil {
                Button {
                    revealPDFTranslationErrorLog()
                } label: {
                    Label(String(localized: "Show BabelDOC Log", bundle: bundle), systemImage: "doc.text.magnifyingglass")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help(String(localized: "Show BabelDOC Log", bundle: bundle))

                Button {
                    copyPDFTranslationErrorLogPath()
                } label: {
                    Label(String(localized: "Copy BabelDOC Log Path", bundle: bundle), systemImage: "doc.on.doc")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help(String(localized: "Copy BabelDOC Log Path", bundle: bundle))
            }

            if latexTranslationErrorLogURL != nil {
                Button {
                    revealLaTeXTranslationErrorLog()
                } label: {
                    Label(String(localized: "Show LaTeX Compilation Log", bundle: bundle), systemImage: "doc.text.magnifyingglass")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help(String(localized: "Show LaTeX Compilation Log", bundle: bundle))
            }

            if translatedLaTeXSourceAttachment != nil {
                Button {
                    revealTranslatedLaTeXSource()
                } label: {
                    Label(String(localized: "Reveal Translated LaTeX Source", bundle: bundle), systemImage: "folder")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help(String(localized: "Reveal Translated LaTeX Source", bundle: bundle))
            }

            Button {
                copyStatusMessage()
            } label: {
                Label(String(localized: "Copy Message", bundle: bundle), systemImage: "doc.on.doc")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help(String(localized: "Copy Message", bundle: bundle))

            Button {
                dismissStatusMessage()
            } label: {
                Label(String(localized: "Close", bundle: bundle), systemImage: "xmark")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help(String(localized: "Close", bundle: bundle))
        }
    }

    private func copyStatusMessage() {
        guard let statusMessage else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(statusMessage, forType: .string)
    }

    private var translationActivityPhase: TranslationActivityCapsule.Phase? {
        isWorking ? .running(isCancelling: isCancelling) : translationActivityOutcome?.phase
    }

    /// One capsule for the whole run, so on finishing it morphs in place: the cancel
    /// bubble melts in and the glow fills or drains.
    @ViewBuilder
    private var translationActivityCapsule: some View {
        if let phase = translationActivityPhase {
            TranslationActivityCapsule(
                phase: phase,
                detail: isWorking ? statusMessage : translationActivityOutcome?.message,
                fraction: translationProgress.flatMap { progress in
                    progress.total > 0 ? progress.completed / progress.total : nil
                },
                summary: translationProgress?.summary,
                onCancel: cancelTranslation
            )
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// Ends a translation run. The outcome is set in the same update that clears
    /// `isWorking`, so the running capsule turns into the outcome instead of
    /// disappearing for a frame. A run that failed passes no outcome.
    private func endTranslationRun(_ outcome: TranslationActivityCapsule.Phase?) {
        finishTranslationActivity(outcome)
        isWorking = false
        isCancelling = false
        translationTask = nil
    }

    /// Plays the finish or the cancel out in the capsule, so the run ends where it
    /// started. A finish with warnings, or a LaTeX finish whose row holds the button
    /// that reveals the source, also keeps its message in the status row.
    private func finishTranslationActivity(_ phase: TranslationActivityCapsule.Phase?) {
        guard let phase else {
            dismissTranslationActivityOutcome()
            return
        }
        let message = statusMessage
        let plainFinishes = [
            String(localized: "Translation cancelled.", bundle: bundle),
            String(localized: "HTML translation completed.", bundle: bundle),
            String(localized: "PDF translation completed.", bundle: bundle),
            String(localized: "Scanned PDF translation completed.", bundle: bundle),
        ]
        if let message, plainFinishes.contains(message) {
            statusMessage = nil
        }

        translationActivityOutcome = TranslationActivityOutcome(phase: phase, message: message)
        translationActivityDismissTask?.cancel()
        translationActivityDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(phase == .completed ? 2 : 1.4))
            guard Task.isCancelled == false else { return }
            withAnimation(.easeIn(duration: 0.25)) {
                translationActivityOutcome = nil
            }
            translationActivityDismissTask = nil
        }
    }

    private func dismissTranslationActivityOutcome() {
        translationActivityDismissTask?.cancel()
        translationActivityDismissTask = nil
        translationActivityOutcome = nil
    }

    private func translateHTML() {
        guard let paper, let htmlAttachment, let settings else { return }
        flushHTMLRegionChanges()
        let preferences = TranslationPreferencesSnapshot(settings)
        htmlSegmentUpdate = nil
        translationProgress = nil
        pdfTranslationErrorLogURL = nil
        pdfTranslationDiagnosticsNoticeID = nil
        latexTranslationErrorLogURL = nil
        isWorking = true
        isCancelling = false
        statusMessage = String(localized: "Translating HTML...", bundle: bundle)
        translationTask = Task {
            var runOutcome: TranslationActivityCapsule.Phase?
            // Translation rewrites paper.html, so region edits must be on disk first.
            await HTMLRegionWriter.shared.waitForQueuedWrites()
            do {
                try Task.checkCancellation()
                let resolvedRoute = try LLMRouteResolver().resolveHTMLRoute(
                    settings: settings,
                    modelContext: modelContext
                )
                let outcome = try await HTMLTranslationPipeline().translateHTML(
                    attachment: htmlAttachment,
                    paper: paper,
                    preferences: preferences,
                    route: resolvedRoute.snapshot,
                    apiKey: resolvedRoute.apiKey,
                    modelContext: modelContext,
                    onDocumentPrepared: {
                        displayMode = .bilingual
                        htmlReloadToken += 1
                    },
                    onProgressUpdated: { processedSegments, totalSegments in
                        translationProgress = totalSegments > 0 ? TranslationProgressStatus(
                            completed: Double(processedSegments),
                            total: Double(totalSegments),
                            summary: "\(processedSegments)/\(totalSegments)"
                        ) : nil
                        statusMessage = totalSegments > 0
                            ? String(localized: "Translating HTML...", bundle: bundle)
                            : String(localized: "Preparing HTML translation...", bundle: bundle)
                    },
                    onSegmentTranslated: { update in
                        displayMode = .bilingual
                        htmlSegmentUpdate = update
                    }
                )
                try Task.checkCancellation()
                displayMode = .bilingual
                translationProgress = nil
                statusMessage = outcome.failedSegments > 0
                    ? HTMLTranslationPipeline.skippedSegmentsMessage(count: outcome.failedSegments, bundle: bundle)
                    : String(localized: "HTML translation completed.", bundle: bundle)
                runOutcome = .completed
            } catch is CancellationError {
                runOutcome = .cancelled
                translationProgress = nil
                statusMessage = String(localized: "Translation cancelled.", bundle: bundle)
            } catch {
                handleTranslationError(error)
            }
            endTranslationRun(runOutcome)
        }
    }

    private func translateLaTeX() {
        guard latexTranslationEnabled,
              let paper,
              let settings,
              let arxivID = paper.arxivID,
              !arxivID.isEmpty else {
            return
        }
        #if os(macOS)
        guard ReadPaperLaTeXToolchain.detectConfigured() != nil else {
            translationProgress = nil
            latexTranslationErrorLogURL = nil
            statusMessage = ReadPaperLaTeXErrorPresentation.message(
                for: ReadPaperLaTeXToolchainError.latexmkNotFound,
                bundle: bundle
            )
            return
        }
        #endif
        let preferences = TranslationPreferencesSnapshot(settings)
        let arxivIdentifier = ReadPaperArXivIdentifier.resolving(
            id: arxivID,
            version: paper.arxivVersion
        )
        let job = TranslationJob(
            paperID: paper.id,
            kind: "latex",
            targetLanguage: preferences.targetLanguage,
            state: .running
        )
        modelContext.insert(job)
        do {
            try modelContext.save()
        } catch {
            handleTranslationError(error)
            return
        }

        let jobID = job.id
        translationProgress = nil
        pdfTranslationErrorLogURL = nil
        pdfTranslationDiagnosticsNoticeID = nil
        latexTranslationErrorLogURL = nil
        isWorking = true
        isCancelling = false
        statusMessage = String(localized: "Preparing arXiv LaTeX source...", bundle: bundle)
        translationTask = Task {
            var runOutcome: TranslationActivityCapsule.Phase?
            do {
                try Task.checkCancellation()
                let resolvedRoute = try LLMRouteResolver().resolvePDFRoute(
                    settings: settings,
                    modelContext: modelContext
                )
                let output = try await ReadPaperLaTeXTranslationService().translate(
                    ReadPaperLaTeXTranslationRequest(
                        paperID: paper.id,
                        arxivIdentifier: arxivIdentifier,
                        targetLanguage: preferences.targetLanguage,
                        maximumConcurrency: preferences.htmlTranslationConcurrency,
                        glossary: preferences.translationGlossary,
                        documentSummary: paper.abstractText,
                        route: resolvedRoute.snapshot,
                        apiKey: resolvedRoute.apiKey
                    )
                ) { update in
                    Task { @MainActor in
                        guard isWorking, !isCancelling else { return }
                        applyLaTeXProgress(update, jobID: jobID)
                    }
                }
                try Task.checkCancellation()

                let sourceAttachment = PaperAttachment(
                    paperID: paper.id,
                    kind: .resource,
                    source: .latexTrans,
                    filename: output.artifact.projectDirectory.lastPathComponent,
                    filePath: output.artifact.projectDirectory.path
                )
                modelContext.insert(sourceAttachment)

                var translatedAttachment: PaperAttachment?
                if let pdfURL = output.artifact.pdfURL {
                    let attachment = PaperAttachment(
                        paperID: paper.id,
                        kind: .translatedPDF,
                        source: .latexTrans,
                        filename: pdfURL.lastPathComponent,
                        filePath: pdfURL.path
                    )
                    modelContext.insert(attachment)
                    translatedAttachment = attachment
                }

                let compilationFailureMessage = output.pdfCompilationFailed
                    ? ReadPaperLaTeXCompilationDiagnostics.failureStatusMessage(
                        for: output.failedCompilationAttempts,
                        bundle: bundle
                    )
                    : nil
                let incompleteUnitsMessage = output.incompleteUnitCount > 0
                    ? ReadPaperLaTeXTranslationOutput.incompleteUnitsMessage(
                        count: output.incompleteUnitCount,
                        bundle: bundle
                    )
                    : nil
                if let storedJob = translationJob(id: jobID) {
                    storedJob.attachmentID = translatedAttachment?.id ?? sourceAttachment.id
                    storedJob.progress = output.pdfCompilationFailed ? 0.92 : 1
                    storedJob.state = output.pdfCompilationFailed ? .failed : .completed
                    storedJob.lastError = compilationFailureMessage ?? incompleteUnitsMessage
                    storedJob.modifiedAt = Date()
                }
                try modelContext.save()

                latexTranslationErrorLogURL = ReadPaperLaTeXCompilationDiagnostics.preferredLogURL(
                    from: output.failedCompilationAttempts
                )
                translationProgress = nil
                if translatedAttachment != nil {
                    readerMode = pdfAttachment == nil ? .translatedPDF : .bilingualPDF
                    pdfReloadToken += 1
                }
                statusMessage = compilationFailureMessage
                    ?? incompleteUnitsMessage
                    ?? String(localized: "LaTeX translation completed.", bundle: bundle)
                runOutcome = output.pdfCompilationFailed ? nil : .completed
            } catch is CancellationError {
                runOutcome = .cancelled
                translationProgress = nil
                finishTranslationJob(
                    id: jobID,
                    state: .failed,
                    error: String(localized: "Translation cancelled.", bundle: bundle)
                )
                statusMessage = String(localized: "Translation cancelled.", bundle: bundle)
            } catch {
                let message = ReadPaperLaTeXErrorPresentation.message(for: error, bundle: bundle)
                finishTranslationJob(id: jobID, state: .failed, error: message)
                translationProgress = nil
                pdfTranslationErrorLogURL = nil
                statusMessage = message
            }
            endTranslationRun(runOutcome)
        }
    }

    private func applyLaTeXProgress(_ update: ReadPaperLaTeXProgressUpdate, jobID: UUID) {
        let percentage = Int((update.fractionCompleted * 100).rounded())
        let summary: String
        if let completed = update.completedUnits,
           let total = update.totalUnits,
           total > 0 {
            summary = "\(completed)/\(total)"
        } else {
            summary = "\(percentage)%"
        }
        translationProgress = TranslationProgressStatus(
            completed: update.fractionCompleted,
            total: 1,
            summary: summary
        )
        statusMessage = update.statusMessage(bundle: bundle)

        guard let job = translationJob(id: jobID) else { return }
        job.progress = update.fractionCompleted
        if let completed = update.completedUnits {
            job.processedSegments = completed
        }
        if let total = update.totalUnits {
            job.totalSegments = total
        }
        job.modifiedAt = Date()
        try? modelContext.save()
    }

    private func finishTranslationJob(id: UUID, state: TranslationJobState, error: String?) {
        guard let job = translationJob(id: id) else { return }
        job.state = state
        job.lastError = error
        job.modifiedAt = Date()
        try? modelContext.save()
    }

    private func translationJob(id: UUID) -> TranslationJob? {
        guard let jobs = try? modelContext.fetch(FetchDescriptor<TranslationJob>()) else {
            return nil
        }
        return jobs.first { $0.id == id }
    }

    /// Asks for the initial notice or a page range, otherwise starts immediately.
    private func offerScannedPDFTranslation(hasNoTextLayer: Bool) {
        guard let pdfAttachment, let settings else { return }
        guard ScannedPDFTranslationPreferences.supports(targetLanguage: settings.targetLanguage) else {
            handleTranslationError(ScannedPDFTranslationError.unsupportedTargetLanguage)
            return
        }
        guard let pageCount = PDFDocument(url: pdfAttachment.fileURL)?.pageCount, pageCount > 0 else {
            handleTranslationError(ScannedPDFTranslationError.unreadablePDF)
            return
        }
        // A translation of every page has no last page; running it again only retries the pages
        // that kept the scan, so there is no range to choose.
        let previousTranslation = isScanRebuildTranslation ? translatedPDFAttachment : nil
        let translatedLastPage = previousTranslation.map { $0.translatedLastPage ?? pageCount } ?? 0
        if didConfirmScannedPDFTranslation, pageCount <= translatedLastPage + pdfTranslationBatchSize {
            startScannedPDFTranslation(pages: nil)
            return
        }
        scannedPDFTranslationOffer = ScannedPDFTranslationOffer(
            pageCount: pageCount,
            hasNoTextLayer: hasNoTextLayer,
            translatedLastPage: translatedLastPage
        )
    }

    private func scannedPDFTranslationOfferMessage(_ offer: ScannedPDFTranslationOffer) -> String {
        if offer.translatedLastPage > 0 {
            return AppLocalization.format(
                "Translated pages 1–%@ of %@.",
                bundle: bundle,
                "\(offer.translatedLastPage)",
                "\(offer.pageCount)"
            )
        }
        if didConfirmScannedPDFTranslation {
            return AppLocalization.format(
                "This PDF has %d pages. Translating the first %d pages is faster.",
                bundle: bundle,
                offer.pageCount,
                pdfTranslationBatchSize
            )
        }
        let explanation = offer.hasNoTextLayer
            ? String(localized: "Its pages are images, so their text cannot be translated directly. Freddie can read each page with a vision model, translate the text, and typeset it on the original page layout.", bundle: bundle)
            : String(localized: "Freddie reads each page image with a vision model, translates the text, and typesets it on the original page layout. Use this for scans and for PDFs whose text layer is unreliable.", bundle: bundle)
        let cost = AppLocalization.format(
            "Page images go to the model chosen for scanned pages in Settings > Reader, which must accept images. Expect about a minute and 50,000 tokens per page (%d pages). Finished pages are saved, so running it again only pays for new pages. XeLaTeX (MacTeX) is required.",
            bundle: bundle,
            offer.pageCount
        )
        return explanation + "\n\n" + cost
    }

    private func startScannedPDFTranslation(pages: [Int]?) {
        guard let paper, let pdfAttachment, let settings else { return }
        if !didConfirmScannedPDFTranslation {
            didConfirmScannedPDFTranslation = true
        }
        let preferences = TranslationPreferencesSnapshot(settings)
        let job = TranslationJob(
            paperID: paper.id,
            kind: "scan",
            targetLanguage: preferences.targetLanguage,
            state: .running
        )
        modelContext.insert(job)
        do {
            try modelContext.save()
        } catch {
            handleTranslationError(error)
            return
        }

        let jobID = job.id
        let previousTranslation = attachments.first { $0.kind == .translatedPDF && $0.source == .scanRebuild }
        let previousTranscription = ScannedPDFTranscription.attachment(in: attachments)
        translationProgress = nil
        pdfTranslationErrorLogURL = nil
        pdfTranslationDiagnosticsNoticeID = nil
        latexTranslationErrorLogURL = nil
        isWorking = true
        isCancelling = false
        statusMessage = String(localized: "Preparing scanned PDF translation...", bundle: bundle)
        translationTask = Task {
            var runOutcome: TranslationActivityCapsule.Phase?
            do {
                try Task.checkCancellation()
                let resolver = LLMRouteResolver()
                let transcriptionRoute = try resolver.resolveScannedPageRoute(settings: settings, modelContext: modelContext)
                let translationRoute = try resolver.resolvePDFRoute(settings: settings, modelContext: modelContext)
                let output = try await ScannedPDFTranslationService().translate(
                    ScannedPDFTranslationRequest(
                        paperID: paper.id,
                        inputPDF: pdfAttachment.fileURL,
                        pages: pages,
                        transcriptionRoute: transcriptionRoute,
                        translationRoute: translationRoute
                    )
                ) { update in
                    Task { @MainActor in
                        guard isWorking, !isCancelling else { return }
                        applyScannedPDFProgress(update, jobID: jobID)
                    }
                }
                try Task.checkCancellation()

                // A rerun rewrites the same files. Their records keep their IDs, so notes and
                // annotations made on them stay attached; the new date makes them the shown versions.
                let attachment = upsertScanRebuildAttachment(
                    previousTranslation, kind: .translatedPDF, paperID: paper.id, fileURL: output.outputPDF
                )
                // A run over the first pages ends there; the reader offers to continue from
                // here, like a partial BabelDOC translation.
                attachment.translatedLastPage = output.translatedLastPage
                if let transcriptionPDF = output.transcriptionPDF {
                    _ = upsertScanRebuildAttachment(
                        previousTranscription, kind: .resource, paperID: paper.id, fileURL: transcriptionPDF
                    )
                } else if let previousTranscription {
                    modelContext.delete(previousTranscription)
                }
                let fallbackMessage = ScannedPDFTranslationService.failureMessage(for: output, bundle: bundle)
                if let storedJob = translationJob(id: jobID) {
                    storedJob.attachmentID = attachment.id
                    storedJob.progress = 1
                    storedJob.state = .completed
                    storedJob.lastError = fallbackMessage
                    storedJob.modifiedAt = Date()
                }
                try modelContext.save()
                pdfReloadToken += 1
                readerMode = .bilingualPDF
                translationProgress = nil
                statusMessage = fallbackMessage
                    ?? String(localized: "Scanned PDF translation completed.", bundle: bundle)
                runOutcome = .completed
            } catch is CancellationError {
                runOutcome = .cancelled
                translationProgress = nil
                finishTranslationJob(
                    id: jobID,
                    state: .failed,
                    error: String(localized: "Translation cancelled.", bundle: bundle)
                )
                statusMessage = String(localized: "Translation cancelled.", bundle: bundle)
            } catch {
                handleTranslationError(error)
                finishTranslationJob(id: jobID, state: .failed, error: statusMessage)
            }
            endTranslationRun(runOutcome)
        }
    }

    private func upsertScanRebuildAttachment(
        _ existing: PaperAttachment?,
        kind: AttachmentKind,
        paperID: UUID,
        fileURL: URL
    ) -> PaperAttachment {
        if let existing {
            existing.filename = fileURL.lastPathComponent
            existing.filePath = fileURL.path
            existing.createdAt = Date()
            return existing
        }
        let attachment = PaperAttachment(
            paperID: paperID,
            kind: kind,
            source: .scanRebuild,
            filename: fileURL.lastPathComponent,
            filePath: fileURL.path
        )
        modelContext.insert(attachment)
        return attachment
    }

    private func applyScannedPDFProgress(_ update: ScannedPDFTranslationProgress, jobID: UUID) {
        if update.totalSteps > 0 {
            translationProgress = TranslationProgressStatus(
                completed: update.fractionCompleted,
                total: 1,
                summary: "\(Int((update.fractionCompleted * 100).rounded()))%"
            )
        }
        statusMessage = update.statusMessage(bundle: bundle)

        guard let job = translationJob(id: jobID) else { return }
        job.progress = update.fractionCompleted
        job.processedSegments = update.completedSteps
        job.totalSegments = update.totalSteps
        job.modifiedAt = Date()
    }

    private func translatePDF() {
        guard canTranslateTextPDF, let pdfAttachment else { return }

        do {
            try PDFTextLayerInspector().requireExtractableText(at: pdfAttachment.fileURL)
        } catch PDFTextLayerError.scannedWithOCR {
            offerScannedPDFTranslation(hasNoTextLayer: false)
            return
        } catch PDFTextLayerError.noExtractableText {
            offerScannedPDFTranslation(hasNoTextLayer: true)
            return
        } catch {
            handleTranslationError(error)
            return
        }

        if isPartialPDFTranslation && !isScanRebuildTranslation {
            extendPDFTranslation()
            return
        }

        let url = pdfAttachment.fileURL
        guard let document = PDFDocument(url: url) else { return }

        let totalPages = document.pageCount
        if totalPages > pdfTranslationBatchSize {
            pdfTranslationTotalPages = totalPages
            showPDFTranslationScopeDialog = true
        } else {
            startPDFTranslation(scope: .allPages)
        }
    }

    private func startPDFTranslation(scope: PDFTranslationScope) {
        guard canTranslateTextPDF, let paper, let pdfAttachment, let settings else { return }
        let preferences = TranslationPreferencesSnapshot(settings)
        let attachmentToReplace = isFullPDFTranslationComplete
            ? translatedPDFAttachment
            : nil
        let pageRange: ClosedRange<Int>? = {
            switch scope {
            case .firstPages(let count):
                return 1...PDFTranslationBatchPreference.normalized(count)
            case .allPages:
                return nil
            }
        }()

        translationProgress = nil
        pdfTranslationErrorLogURL = nil
        pdfTranslationDiagnosticsNoticeID = nil
        latexTranslationErrorLogURL = nil
        isWorking = true
        isCancelling = false
        statusMessage = String(localized: "Running BabelDOC...", bundle: bundle)
        translationTask = Task {
            var runOutcome: TranslationActivityCapsule.Phase?
            do {
                try Task.checkCancellation()
                let resolvedRoute = try LLMRouteResolver().resolvePDFRoute(
                    settings: settings,
                    modelContext: modelContext
                )
                let toolManager = BabelDocToolManager()
                let nativeTool = try toolManager.nativeToolPaths()
                statusMessage = String(localized: "Translating PDF with BabelDOC...", bundle: bundle)
                let outputDirectory = try PaperFileStore().translationsDirectory(for: paper)
                let toolEnvironment = try toolManager.nativeEnvironment(apiKey: resolvedRoute.apiKey)
                let arxivIdentifier = paper.arxivID.map {
                    ReadPaperArXivIdentifier.resolving(id: $0, version: paper.arxivVersion)
                }
                let semanticHints = try await BabelDocSemanticHintService().prepareIfAvailable(
                    isEnabled: babelDocSemanticHintsEnabled,
                    paperID: paper.id,
                    arxivIdentifier: arxivIdentifier
                ) { update in
                    Task { @MainActor in
                        guard isWorking, !isCancelling else { return }
                        statusMessage = update.localizedMessage
                    }
                }
                let translationResult = try await BabelDocRunner().translatePDFNative(
                    inputPDF: pdfAttachment.fileURL,
                    outputDirectory: outputDirectory,
                    preferences: preferences,
                    route: resolvedRoute.snapshot,
                    apiKey: resolvedRoute.apiKey,
                    tool: nativeTool,
                    documentTitle: paper.title,
                    semanticHintsURL: semanticHints?.fileURL,
                    pageRange: pageRange,
                    environment: toolEnvironment,
                    onStatusUpdate: { message in
                        Task { @MainActor in
                            guard isWorking, !isCancelling else { return }
                            if translationProgress == nil || message.hasPrefix(String(localized: "BabelDOC error", bundle: bundle)) {
                                statusMessage = message
                            }
                        }
                    },
                    onProgressUpdate: { progress in
                        Task { @MainActor in
                            guard isWorking, !isCancelling else { return }
                            translationProgress = TranslationProgressStatus(
                                completed: progress.completed,
                                total: progress.total,
                                summary: progress.summary
                            )
                            statusMessage = progress.statusMessage
                        }
                    }
                )
                let translated = translationResult.outputPDF
                try Task.checkCancellation()
                let translatedLastPage: Int? = {
                    switch scope {
                    case .firstPages(let count):
                        return PDFTranslationBatchPreference.normalized(count)
                    case .allPages:
                        return nil
                    }
                }()
                let previousTranslationURL: URL?
                if let attachmentToReplace {
                    previousTranslationURL = attachmentToReplace.fileURL
                    attachmentToReplace.source = .babeldoc
                    attachmentToReplace.filename = translated.lastPathComponent
                    attachmentToReplace.filePath = translated.path
                    attachmentToReplace.translatedLastPage = translatedLastPage
                } else {
                    previousTranslationURL = nil
                    modelContext.insert(PaperAttachment(
                        paperID: paper.id,
                        kind: .translatedPDF,
                        source: .babeldoc,
                        filename: translated.lastPathComponent,
                        filePath: translated.path,
                        translatedLastPage: translatedLastPage
                    ))
                }
                try modelContext.save()
                if let previousTranslationURL,
                   previousTranslationURL.standardizedFileURL != translated.standardizedFileURL {
                    try? FileManager.default.removeItem(at: previousTranslationURL)
                    try? FileManager.default.removeItem(
                        at: BabelDocRunner.diagnosticsURL(for: previousTranslationURL)
                    )
                }
                pdfReloadToken += 1
                readerMode = .bilingualPDF
                translationProgress = nil
                pdfTranslationErrorLogURL = translationResult.diagnosticsLogURL
                pdfTranslationDiagnosticsNoticeID = pdfTranslationNoticeID(
                    outputPDF: translated,
                    diagnostics: translationResult.diagnostics
                )
                statusMessage = pdfTranslationCompletionMessage(translationResult.diagnostics)
                runOutcome = .completed
            } catch is CancellationError {
                runOutcome = .cancelled
                translationProgress = nil
                pdfTranslationErrorLogURL = nil
                statusMessage = String(localized: "Translation cancelled.", bundle: bundle)
            } catch {
                handleTranslationError(error)
            }
            endTranslationRun(runOutcome)
        }
    }

    /// Translates the next pages on the route that made the partial translation.
    private func continuePDFTranslation(to requestedLastPage: Int? = nil) {
        guard isScanRebuildTranslation else {
            extendPDFTranslation(to: requestedLastPage)
            return
        }
        guard canTranslatePDF,
              let currentLastPage = translatedPDFAttachment?.translatedLastPage,
              let total = originalPDFPageCount, currentLastPage < total
        else { return }
        let nextLastPage = min(requestedLastPage ?? currentLastPage + pdfTranslationBatchSize, total)
        // Finished pages come from the checkpoints, so only the new pages are sent to the model.
        startScannedPDFTranslation(pages: nextLastPage < total ? Array(1...nextLastPage) : nil)
    }

    private func extendPDFTranslation(to requestedLastPage: Int? = nil) {
        guard canTranslateTextPDF, !isScanRebuildTranslation else { return }
        guard let paper, let pdfAttachment, let settings, let existingAttachment = translatedPDFAttachment, let currentLastPage = existingAttachment.translatedLastPage else { return }
        guard let total = originalPDFPageCount, currentLastPage < total else { return }

        let nextBatch = min(requestedLastPage ?? currentLastPage + pdfTranslationBatchSize, total)
        guard nextBatch > currentLastPage else { return }
        let pageRange = (currentLastPage + 1)...nextBatch
        let preferences = TranslationPreferencesSnapshot(settings)

        translationProgress = nil
        pdfTranslationErrorLogURL = nil
        pdfTranslationDiagnosticsNoticeID = nil
        latexTranslationErrorLogURL = nil
        isWorking = true
        isCancelling = false
        statusMessage = String(localized: "Running BabelDOC...", bundle: bundle)
        translationTask = Task {
            var runOutcome: TranslationActivityCapsule.Phase?
            do {
                try Task.checkCancellation()
                let resolvedRoute = try LLMRouteResolver().resolvePDFRoute(
                    settings: settings,
                    modelContext: modelContext
                )
                let toolManager = BabelDocToolManager()
                let nativeTool = try toolManager.nativeToolPaths()
                statusMessage = String(localized: "Translating PDF with BabelDOC...", bundle: bundle)
                let outputDirectory = try PaperFileStore().translationsDirectory(for: paper)
                let toolEnvironment = try toolManager.nativeEnvironment(apiKey: resolvedRoute.apiKey)
                let arxivIdentifier = paper.arxivID.map {
                    ReadPaperArXivIdentifier.resolving(id: $0, version: paper.arxivVersion)
                }
                let semanticHints = try await BabelDocSemanticHintService().prepareIfAvailable(
                    isEnabled: babelDocSemanticHintsEnabled,
                    paperID: paper.id,
                    arxivIdentifier: arxivIdentifier
                ) { update in
                    Task { @MainActor in
                        guard isWorking, !isCancelling else { return }
                        statusMessage = update.localizedMessage
                    }
                }

                guard let existingDoc = PDFDocument(url: existingAttachment.fileURL) else {
                    throw PDFMergerError.failedToOpenFile(existingAttachment.fileURL.path)
                }
                TranslatedPDFPageBoundsNormalizer.normalizeBounds(in: existingDoc)
                let trimmedExisting: PDFDocument = {
                    let doc = PDFDocument()
                    let pageCount = min(currentLastPage, existingDoc.pageCount)
                    for i in 0..<pageCount {
                        guard let page = existingDoc.page(at: i) else { continue }
                        doc.insert(page, at: i)
                    }
                    return doc
                }()

                let incrementResult = try await BabelDocRunner().translatePDFNative(
                    inputPDF: pdfAttachment.fileURL,
                    outputDirectory: outputDirectory,
                    preferences: preferences,
                    route: resolvedRoute.snapshot,
                    apiKey: resolvedRoute.apiKey,
                    tool: nativeTool,
                    documentTitle: paper.title,
                    semanticHintsURL: semanticHints?.fileURL,
                    pageRange: pageRange,
                    environment: toolEnvironment,
                    onStatusUpdate: { message in
                        Task { @MainActor in
                            guard isWorking, !isCancelling else { return }
                            if translationProgress == nil || message.hasPrefix(String(localized: "BabelDOC error", bundle: bundle)) {
                                statusMessage = message
                            }
                        }
                    },
                    onProgressUpdate: { progress in
                        Task { @MainActor in
                            guard isWorking, !isCancelling else { return }
                            translationProgress = TranslationProgressStatus(
                                completed: progress.completed,
                                total: progress.total,
                                summary: progress.summary
                            )
                            statusMessage = progress.statusMessage
                        }
                    }
                )
                let incrementPDF = incrementResult.outputPDF
                try Task.checkCancellation()

                let mergedFilename = "merged-\(nextBatch)-\(UUID().uuidString.prefix(8)).pdf"
                let mergedURL = outputDirectory.appendingPathComponent(mergedFilename)
                let _ = try PDFMerger.merge(existing: trimmedExisting, increment: incrementPDF, output: mergedURL)

                let existingDiagnostics = try? BabelDocRunner.readDiagnostics(for: existingAttachment.fileURL)
                let combinedDiagnostics: BabelDocTranslationDiagnostics? = {
                    switch (existingDiagnostics, incrementResult.diagnostics) {
                    case let (existing?, increment?):
                        return existing.merging(increment)
                    case let (existing?, nil):
                        return existing
                    case let (nil, increment?):
                        return increment
                    case (nil, nil):
                        return nil
                    }
                }()
                let mergedDiagnosticsURL: URL?
                if let combinedDiagnostics, combinedDiagnostics.isDegraded {
                    mergedDiagnosticsURL = try BabelDocRunner.writeDiagnostics(
                        combinedDiagnostics,
                        for: mergedURL
                    )
                } else {
                    mergedDiagnosticsURL = nil
                }

                // Clean up old merged PDF file to prevent storage bloat
                let oldFileURL = existingAttachment.fileURL
                if oldFileURL != mergedURL {
                    try? FileManager.default.removeItem(at: oldFileURL)
                    try? FileManager.default.removeItem(at: BabelDocRunner.diagnosticsURL(for: oldFileURL))
                }
                try? FileManager.default.removeItem(at: incrementPDF)
                try? FileManager.default.removeItem(at: BabelDocRunner.diagnosticsURL(for: incrementPDF))

                existingAttachment.filePath = mergedURL.path
                existingAttachment.filename = mergedFilename
                existingAttachment.translatedLastPage = nextBatch
                try modelContext.save()

                pdfReloadToken += 1
                translationProgress = nil
                pdfTranslationErrorLogURL = mergedDiagnosticsURL
                pdfTranslationDiagnosticsNoticeID = pdfTranslationNoticeID(
                    outputPDF: mergedURL,
                    diagnostics: combinedDiagnostics
                )
                statusMessage = pdfTranslationCompletionMessage(combinedDiagnostics)
                runOutcome = .completed
            } catch is CancellationError {
                runOutcome = .cancelled
                translationProgress = nil
                pdfTranslationErrorLogURL = nil
                statusMessage = String(localized: "Translation cancelled.", bundle: bundle)
            } catch {
                handleTranslationError(error)
            }
            endTranslationRun(runOutcome)
        }
    }

    private func cancelTranslation() {
        guard isWorking else { return }
        isCancelling = true
        statusMessage = String(localized: "Cancelling translation...", bundle: bundle)
        translationTask?.cancel()
    }

    private func pdfTranslationCompletionMessage(
        _ diagnostics: BabelDocTranslationDiagnostics?
    ) -> String {
        guard let diagnostics, diagnostics.isDegraded else {
            return String(localized: "PDF translation completed.", bundle: bundle)
        }
        return AppLocalization.format(
            "PDF translation completed with warnings: translated %d/%d text blocks; %d failed and kept their original layout.",
            bundle: bundle,
            diagnostics.translatedCount,
            diagnostics.candidateCount,
            diagnostics.failedCount
        )
    }

    private func restorePDFTranslationDiagnostics() {
        guard !isWorking else { return }
        let wasShowingDiagnosticsNotice = pdfTranslationDiagnosticsNoticeID != nil
        pdfTranslationDiagnosticsNoticeID = nil

        guard let paperID = paper?.id,
              let translatedPDF = translatedPDFAttachment?.fileURL else {
            pdfTranslationErrorLogURL = nil
            if wasShowingDiagnosticsNotice {
                statusMessage = nil
            }
            return
        }
        let diagnosticsURL = BabelDocRunner.diagnosticsURL(for: translatedPDF)
        guard FileManager.default.fileExists(atPath: diagnosticsURL.path),
              let diagnostics = try? BabelDocRunner.readDiagnostics(for: translatedPDF),
              diagnostics.isDegraded else {
            pdfTranslationErrorLogURL = nil
            if wasShowingDiagnosticsNotice {
                statusMessage = nil
            }
            return
        }

        let noticeStore = PDFTranslationDiagnosticsNoticeStore()
        let noticeID = noticeStore.noticeID(
            outputPDF: translatedPDF,
            diagnostics: diagnostics
        )
        guard !noticeStore.isDismissed(paperID: paperID, noticeID: noticeID) else {
            pdfTranslationErrorLogURL = nil
            statusMessage = nil
            return
        }

        pdfTranslationErrorLogURL = diagnosticsURL
        pdfTranslationDiagnosticsNoticeID = noticeID
        statusMessage = pdfTranslationCompletionMessage(diagnostics)
    }

    private func pdfTranslationNoticeID(
        outputPDF: URL,
        diagnostics: BabelDocTranslationDiagnostics?
    ) -> String? {
        guard let diagnostics, diagnostics.isDegraded else { return nil }
        return PDFTranslationDiagnosticsNoticeStore().noticeID(
            outputPDF: outputPDF,
            diagnostics: diagnostics
        )
    }

    private func handleTranslationError(_ error: Error) {
        translationProgress = nil
        pdfTranslationDiagnosticsNoticeID = nil
        if let babelDocError = error as? BabelDocRunError {
            pdfTranslationErrorLogURL = babelDocError.logURL
        } else {
            pdfTranslationErrorLogURL = nil
        }
        statusMessage = AppLocalization.errorMessage(error, bundle: bundle)
        translationSetupErrorMessage = error is LLMRouteError ? statusMessage : nil
    }

    /// Looks for a usable route without reading an API key, so it never asks for
    /// Touch ID. Runs again whenever translation settings are saved.
    private func refreshTranslationSetupNeed() {
        guard let settings, !didHandleTranslationSetupNotice else {
            needsTranslationSetup = false
            return
        }
        let keychainStore = KeychainStore()
        needsTranslationSetup = !LLMTranslationSetupStatus.hasUsableRoute(
            settings: settings,
            modelContext: modelContext,
            hasStoredAPIKey: { (try? keychainStore.contains(account: $0)) == true }
        )
    }

    /// Until translation is set up, a notice at the bottom of the reader leads to the
    /// quick setup in Settings. It goes away for good once opened or closed.
    private var translationSetupNotice: some View {
        HStack(spacing: 10) {
            Image(systemName: "translate")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Text("Connect a translation service to translate papers.", bundle: bundle)
                .font(.callout.weight(.medium))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Button(String(localized: "Set Up…", bundle: bundle)) {
                didHandleTranslationSetupNotice = true
                TranslationSetupNavigation.showQuickSetup(using: openSettings)
            }
            .readPaperGlassButtonStyle(prominent: true)
            .controlSize(.small)

            Button {
                didHandleTranslationSetupNotice = true
            } label: {
                Label(String(localized: "Close", bundle: bundle), systemImage: "xmark")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help(String(localized: "Close", bundle: bundle))
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
        .readPaperGlassEffect(in: Capsule())
        .shadow(color: .black.opacity(0.14), radius: 10, y: 4)
    }

    private func revealPDFTranslationErrorLog() {
        guard let pdfTranslationErrorLogURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([pdfTranslationErrorLogURL])
    }

    private func copyPDFTranslationErrorLogPath() {
        guard let pdfTranslationErrorLogURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pdfTranslationErrorLogURL.path, forType: .string)
    }

    private func revealLaTeXTranslationErrorLog() {
        guard let latexTranslationErrorLogURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([latexTranslationErrorLogURL])
    }

    private func revealTranslatedLaTeXSource() {
        guard let translatedLaTeXSourceAttachment else { return }
        NSWorkspace.shared.activateFileViewerSelecting([translatedLaTeXSourceAttachment.fileURL])
    }

    private func dismissStatusMessage() {
        guard !isWorking else { return }
        if let paperID = paper?.id,
           let noticeID = pdfTranslationDiagnosticsNoticeID {
            PDFTranslationDiagnosticsNoticeStore().dismiss(
                paperID: paperID,
                noticeID: noticeID
            )
        }
        statusMessage = nil
        translationProgress = nil
        pdfTranslationErrorLogURL = nil
        pdfTranslationDiagnosticsNoticeID = nil
    }

    private var translateMoreBanner: some View {
        let lastPage = translatedPDFAttachment?.translatedLastPage ?? 0
        let total = originalPDFPageCount ?? 0
        let nextEnd = min(lastPage + pdfTranslationBatchSize, total)
        return ReadPaperGlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                Text(AppLocalization.format("Translated pages 1–%@ of %@.", "\(lastPage)", "\(total)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button {
                    continuePDFTranslation()
                } label: {
                    Text(AppLocalization.format("Translate pages %@–%@", "\(lastPage + 1)", "\(nextEnd)"))
                        .font(.caption)
                }
                .readPaperGlassButtonStyle(prominent: true)
                .controlSize(.small)

                if nextEnd < total {
                    Button {
                        continuePDFTranslation(to: total)
                    } label: {
                        Text("Translate All", bundle: bundle)
                            .font(.caption)
                    }
                    .readPaperGlassButtonStyle()
                    .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(ReadPaperAppearanceHeaderSurface(role: .reader))
        .disabled(canContinuePDFTranslation == false)
    }

    private func syncReaderModeWithAvailableContent() {
        guard paper != nil else { return }

        let resolvedMode = ReadingStateStore.resolvedReaderMode(
            preferredMode: readerMode,
            hasHTML: htmlAttachment != nil,
            hasPDF: pdfAttachment != nil,
            hasTranslatedPDF: translatedPDFAttachment != nil
        )
        guard resolvedMode != readerMode else { return }

        updateWithoutPersistingReadingState {
            if resolvedMode != .html {
                lastPDFReaderMode = normalizedPDFReaderMode(resolvedMode)
            }
            readerMode = resolvedMode
        }
    }

    @ViewBuilder
    private func labeledPDFReader(
        fileURL: URL?,
        attachmentID: UUID?,
        includesUnattributedSidenotes: Bool,
        label: String,
        showsOriginalVersionMenu: Bool = false,
        emptyTitle: String,
        emptyDescription: String,
        reloadToken: Int = 0,
        debugRegionSelectionEnabled: Bool = false,
        onDebugRegionSelected: ((PDFDebugRegionSelection) -> Void)? = nil
    ) -> some View {
        if fileURL != nil {
            GeometryReader { proxy in
                let canShowRail = proxy.size.width >= PDFSidenoteRail.width + PDFSidenoteRail.minimumReaderWidth
                let anchors = canShowRail
                    ? PDFSidenoteAnchor.anchors(
                        from: notes,
                        attachmentID: attachmentID,
                        includesUnattributedNotes: includesUnattributedSidenotes
                    )
                    : []
                PDFDisplaySurface(appearance: pdfDisplayAppearance) {
                    HStack(spacing: 0) {
                        PDFReaderView(
                            fileURL: fileURL,
                            paperID: paper?.id,
                            attachmentID: attachmentID,
                            displayAppearance: pdfDisplayAppearance,
                            pageIndex: pdfPageIndexBinding,
                            reloadToken: reloadToken,
                            noteNavigationRequest: noteNavigationRequest,
                            selectionAssistantHistoryAnchors: selectionAssistantHistoryAnchors,
                            annotationSession: pdfAnnotationSession,
                            handToolEnabled: pdfHandToolEnabled,
                            onNoteSelectionChanged: handleNoteSelectionChange,
                            onArxivLinkActivated: onArxivLinkActivated,
                            debugRegionSelectionEnabled: debugRegionSelectionEnabled,
                            onDebugRegionSelected: onDebugRegionSelected,
                            findRequest: findRequest,
                            onFindStatusChanged: handleFindStatusChange,
                            sidenoteAnchors: anchors,
                            sidenoteLayout: pdfSidenoteLayout,
                            citationMarks: citationMarks,
                            onCitationMarksActivated: handleCitationMarksActivated
                        )

                        if anchors.isEmpty == false {
                            let anchoredIDs = Set(anchors.map(\.id))
                            PDFSidenoteRail(
                                notes: notes.filter { anchoredIDs.contains($0.id) },
                                layout: pdfSidenoteLayout,
                                focusRequest: sidenoteFocusRequest,
                                onFocusHandled: handleSidenoteFocusHandled,
                                onCommit: saveSidenoteEdits,
                                onDelete: { sidenotePendingDeletion = $0 }
                            )
                        }
                    }
                }
                .onChange(of: canShowRail, initial: true) { _, newValue in
                    isPDFSidenoteRailAvailable = newValue
                }
            }
                .overlay(alignment: .topLeading) {
                    if showsOriginalVersionMenu, scanTranscriptionAttachment != nil {
                        originalVersionMenu
                    } else {
                        readerLabel(label)
                    }
                }
        } else {
            centeredUnavailableView(
                emptyTitle,
                systemImage: "doc.richtext",
                description: Text(emptyDescription)
            )
        }
    }

    private func centeredUnavailableView(
        _ title: String,
        systemImage: String,
        description: Text
    ) -> some View {
        ContentUnavailableView {
            Label {
                Text(verbatim: title)
            } icon: {
                Image(systemName: systemImage)
            }
        } description: {
            description
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    /// With no paper open, the reader is the way into the library: one action, like
    /// Zotero's empty library, instead of a tour of features.
    private var emptyReaderState: some View {
        VStack(spacing: 14) {
            Image(systemName: isLibraryEmpty ? "doc.badge.plus" : "doc.text")
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text(isLibraryEmpty ? "Add Your First Paper" : "No Paper Selected", bundle: bundle)
                    .font(.title3.weight(.semibold))
                Text(
                    isLibraryEmpty
                        ? "Import from an arXiv ID or a web page URL, or drop a PDF here."
                        : "Select a paper in the library, or add another one.",
                    bundle: bundle
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.center)

            Button {
                onAddPaper()
            } label: {
                Label(String(localized: "Add Paper", bundle: bundle), systemImage: "plus")
                    .padding(.horizontal, 4)
            }
            .readPaperGlassButtonStyle(prominent: isLibraryEmpty)
            .controlSize(.large)
            .padding(.top, 4)
        }
        .frame(maxWidth: 360)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(ReadPaperAppearanceSurface(role: .reader))
    }

    private func readerLabel(_ value: String) -> some View {
        Text(value)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .readPaperGlassEffect(in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .padding(8)
    }

    /// The Original label of a scanned PDF with a corrected transcription: chooses which one to read.
    private var originalVersionMenu: some View {
        let title = showsScanTranscription
            ? String(localized: "Corrected Transcription", bundle: bundle)
            : String(localized: "Scanned Original", bundle: bundle)
        return Menu {
            Toggle(String(localized: "Scanned Original", bundle: bundle), isOn: Binding(
                get: { !showsScanTranscription },
                set: { if $0 { setShowsScanTranscription(false) } }
            ))
            Toggle(String(localized: "Corrected Transcription", bundle: bundle), isOn: Binding(
                get: { showsScanTranscription },
                set: { if $0 { setShowsScanTranscription(true) } }
            ))
        } label: {
            HStack(spacing: 3) {
                Text(title)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .readPaperGlassEffect(in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(8)
        .help(String(localized: "Read the scanned pages or the corrected transcription typeset from them", bundle: bundle))
        .accessibilityLabel(String(localized: "Original", bundle: bundle))
        .accessibilityValue(title)
    }

    private func setShowsScanTranscription(_ shows: Bool) {
        guard let paperID = paper?.id else { return }
        var paperIDs = ScannedPDFTranscription.decode(transcriptionPaperIDsStorage)
        if shows {
            paperIDs.insert(paperID)
        } else {
            paperIDs.remove(paperID)
        }
        transcriptionPaperIDsStorage = ScannedPDFTranscription.encode(paperIDs)
    }

    private func handleNoteSelectionChange(_ selection: NoteSelectionContext?) {
        noteSelectionContext = selection
        selectionAssistantDismissTask?.cancel()
        selectionAssistantDismissTask = nil

        if let selection {
            isSelectionAssistantPinned = false
            if let paper {
                selectionAssistantInitialConversation = try? SelectionAssistantConversationStore()
                    .conversation(
                        paperID: paper.id,
                        selectionIdentity: selection.selectionAssistantIdentity
                    )
            } else {
                selectionAssistantInitialConversation = nil
            }
            selectionAssistantSelection = selection
            return
        }

        guard isSelectionAssistantPinned == false else { return }
        selectionAssistantDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard Task.isCancelled == false,
                  isSelectionAssistantPinned == false else { return }
            selectionAssistantSelection = nil
            selectionAssistantInitialConversation = nil
            selectionAssistantDismissTask = nil
        }
    }

    private func pinSelectionAssistant() {
        selectionAssistantDismissTask?.cancel()
        selectionAssistantDismissTask = nil
        if isSelectionAssistantPinned == false {
            htmlNativeSelectionClearToken &+= 1
        }
        isSelectionAssistantPinned = true
    }

    private func handleHTMLSelectionAssistantDismissal() {
        noteSelectionContext = nil
        clearSelectionAssistant()
    }

    @MainActor
    private func persistSelectionAssistantConversation(
        _ snapshot: SelectionAssistantConversationSnapshot
    ) {
        guard let paper else { return }
        try? SelectionAssistantConversationStore().save(snapshot, paperID: paper.id)
        refreshSelectionAssistantHistoryAnchors()
    }

    @MainActor
    private func refreshSelectionAssistantHistoryAnchors() {
        guard let paper else {
            selectionAssistantHistoryAnchors = []
            return
        }
        selectionAssistantHistoryAnchors = (try? SelectionAssistantConversationStore()
            .historyAnchors(paperID: paper.id)) ?? []
    }

    private func clearSelectionAssistant() {
        selectionAssistantDismissTask?.cancel()
        selectionAssistantDismissTask = nil
        selectionAssistantProgress = nil
        selectionAssistantInitialConversation = nil
        isSelectionAssistantPinned = false
        selectionAssistantSelection = nil
        htmlSelectionHighlightResetToken &+= 1
    }

    /// A citation opened from a writing arrives together with its paper. Going to it after
    /// the paper's reading position is restored works whichever change SwiftUI handles first.
    private func revealNavigationArrivingWithPaper() {
        guard let targetPaperID = noteNavigationRequest?.paperID, targetPaperID == paper?.id else { return }
        revealNoteAnchorIfNeeded()
    }

    private func revealNoteAnchorIfNeeded() {
        guard let request = noteNavigationRequest else { return }

        if request.htmlSelector != nil, htmlAttachment != nil {
            updateWithoutPersistingReadingState {
                displayMode = .bilingual
                readerMode = .html
            }
            return
        }

        guard let targetPageIndex = request.pageIndex else { return }
        let targetMode = preferredReaderMode(for: request)
        // A note or citation made on the scan or on its transcription opens that version.
        if let attachmentID = request.attachmentID, scanTranscriptionAttachment != nil {
            if attachmentID == scanTranscriptionAttachment?.id, !showsScanTranscription {
                setShowsScanTranscription(true)
            } else if attachmentID == pdfAttachment?.id, showsScanTranscription {
                setShowsScanTranscription(false)
            }
        }

        updateWithoutPersistingReadingState {
            readerMode = targetMode
            if targetMode != .html {
                lastPDFReaderMode = normalizedPDFReaderMode(targetMode)
            }
            pdfPageIndex = max(0, targetPageIndex)
        }
    }

    private func preferredReaderMode(for request: NoteNavigationRequest) -> ReaderMode {
        if request.htmlSelector != nil, htmlAttachment != nil {
            return .html
        }

        if request.attachmentID == translatedPDFAttachment?.id, translatedPDFAttachment != nil {
            if pdfAttachment != nil {
                return .bilingualPDF
            }
            return .translatedPDF
        }

        if pdfAttachment != nil {
            return .pdf
        }

        if translatedPDFAttachment != nil {
            return .translatedPDF
        }

        return readerMode
    }

    private func normalizedPDFReaderMode(_ mode: ReaderMode) -> ReaderMode {
        switch mode {
        case .html:
            .pdf
        case .pdf, .bilingualPDF, .translatedPDF:
            mode
        }
    }

    private func restoreReadingStateForCurrentPaper() {
        guard let paper else { return }

        let (restoredMode, restoredPageIndex) = restoredReadingPosition
        let restoredScrollRatio = restoredHTMLScrollRatio

        updateWithoutPersistingReadingState {
            readingStatePaperID = paper.id
            readerMode = restoredMode
            if restoredMode != .html {
                lastPDFReaderMode = normalizedPDFReaderMode(restoredMode)
            }
            pdfPageIndex = restoredPageIndex
            htmlScrollRatio = restoredScrollRatio
        }
    }

    private func refreshOriginalPDFPageCount(for request: PDFPageCountRequest?) async {
        guard let request else {
            originalPDFPageCount = nil
            extractablePDFRequest = nil
            return
        }

        let (pageCount, hasExtractableText) = await Task.detached(priority: .utility) {
            guard let document = CGPDFDocument(request.fileURL as CFURL) else {
                return (nil as Int?, false)
            }
            let verdict = PDFTextLayerInspector().inspect(document)
            return (document.numberOfPages, verdict == .extractable)
        }.value
        guard !Task.isCancelled, originalPDFPageCountRequest == request else { return }
        originalPDFPageCount = pageCount
        extractablePDFRequest = hasExtractableText ? request : nil
    }

    private func readingStatePersistenceSnapshot() -> ReadingStatePersistenceSnapshot? {
        guard !suspendReadingStatePersistence, let paper else { return nil }
        // The previous paper's position must not be saved as this one's before it is restored.
        guard isAwaitingReadingStateRestore == false else { return nil }
        guard htmlAttachment != nil || pdfAttachment != nil || translatedPDFAttachment != nil else {
            return nil
        }

        let resolvedMode = ReadingStateStore.resolvedReaderMode(
            preferredMode: readerMode,
            hasHTML: htmlAttachment != nil,
            hasPDF: pdfAttachment != nil,
            hasTranslatedPDF: translatedPDFAttachment != nil
        )
        return ReadingStatePersistenceSnapshot(
            paperID: paper.id,
            attachmentID: attachmentID(for: resolvedMode),
            readerMode: resolvedMode,
            pageIndex: pdfPageIndex,
            scrollRatio: resolvedMode == .html ? htmlScrollRatio : 0
        )
    }

    private func scheduleReadingStatePersistence() {
        guard let snapshot = readingStatePersistenceSnapshot() else { return }
        guard pendingReadingStatePersistence != snapshot else { return }

        readingStatePersistenceTask?.cancel()
        pendingReadingStatePersistence = snapshot
        readingStatePersistenceTask = Task { @MainActor in
            do {
                try await Task.sleep(for: Self.readingStatePersistenceDelay)
            } catch {
                return
            }
            guard Task.isCancelled == false,
                  pendingReadingStatePersistence == snapshot else {
                return
            }
            pendingReadingStatePersistence = nil
            readingStatePersistenceTask = nil
            persistReadingState(snapshot)
        }
    }

    private func persistReadingStateImmediatelyIfNeeded() {
        readingStatePersistenceTask?.cancel()
        readingStatePersistenceTask = nil
        pendingReadingStatePersistence = nil
        guard let snapshot = readingStatePersistenceSnapshot() else { return }
        persistReadingState(snapshot)
    }

    private func flushPendingReadingStatePersistence() {
        readingStatePersistenceTask?.cancel()
        readingStatePersistenceTask = nil
        guard let snapshot = pendingReadingStatePersistence else { return }
        pendingReadingStatePersistence = nil
        persistReadingState(snapshot)
    }

    private func flushReadingStatePersistence() {
        if pendingReadingStatePersistence != nil {
            flushPendingReadingStatePersistence()
        } else {
            persistReadingStateImmediatelyIfNeeded()
        }
    }

    private func persistReadingState(_ snapshot: ReadingStatePersistenceSnapshot) {
        let signpostID = OSSignpostID(log: Self.performanceLog)
        os_signpost(
            .begin,
            log: Self.performanceLog,
            name: "Persist Reading State",
            signpostID: signpostID
        )
        defer {
            os_signpost(
                .end,
                log: Self.performanceLog,
                name: "Persist Reading State",
                signpostID: signpostID
            )
        }

        do {
            try ReadingStateStore().upsertState(
                for: snapshot.paperID,
                attachmentID: snapshot.attachmentID,
                readerMode: snapshot.readerMode,
                pageIndex: snapshot.pageIndex,
                scrollRatio: snapshot.scrollRatio,
                knownStatesByDescendingModificationDate: readingStates,
                in: modelContext
            )
        } catch {
            assertionFailure("Failed to save reading state: \(error.localizedDescription)")
        }
    }

    private func attachmentID(for mode: ReaderMode) -> UUID? {
        switch mode {
        case .html:
            htmlAttachment?.id
        case .pdf, .bilingualPDF:
            pdfAttachment?.id
        case .translatedPDF:
            translatedPDFAttachment?.id
        }
    }

    private func updateWithoutPersistingReadingState(_ updates: () -> Void) {
        suspendReadingStatePersistence = true
        updates()
        DispatchQueue.main.async {
            suspendReadingStatePersistence = false
        }
    }
}

/// What the first-run setup check depends on: the routes and the save time, which
/// Settings bumps whenever it saves a provider key or a route.
private struct TranslationSetupCheck: Equatable {
    let settingsID: UUID?
    let htmlModelID: UUID?
    let pdfModelID: UUID?
    let modifiedAt: Date?

    @MainActor
    init(settings: AppSettings?) {
        settingsID = settings?.id
        htmlModelID = settings?.selectedHTMLModelProfileID
        pdfModelID = settings?.selectedPDFModelProfileID
        modifiedAt = settings?.modifiedAt
    }
}

extension ReaderPaneView: Equatable {
    /// The window redraws for much that the reader does not show, such as SwiftData refreshing
    /// its models after a save, and redrawing the reader also updates its toolbar. Bindings
    /// still update the reader when their values change, models it reads redraw it through
    /// observation, and the action closures only reach state that outlives the view value.
    nonisolated static func == (lhs: ReaderPaneView, rhs: ReaderPaneView) -> Bool {
        MainActor.assumeIsolated {
            lhs.paper === rhs.paper
                && lhs.isLibraryEmpty == rhs.isLibraryEmpty
                && lhs.settings === rhs.settings
                && lhs.writingLibrary === rhs.writingLibrary
                && lhs.attachments.elementsEqual(rhs.attachments, by: ===)
                && lhs.notes.elementsEqual(rhs.notes, by: ===)
        }
    }
}

/// The PDF reader modes as the toolbar's Original / Bilingual / Translated choice.
private extension TranslationDisplayMode {
    init(pdfReaderMode: ReaderMode) {
        switch pdfReaderMode {
        case .html, .pdf:
            self = .original
        case .bilingualPDF:
            self = .bilingual
        case .translatedPDF:
            self = .translated
        }
    }

    var pdfReaderMode: ReaderMode {
        switch self {
        case .original:
            .pdf
        case .bilingual:
            .bilingualPDF
        case .translated:
            .translatedPDF
        }
    }
}

/// Receives the choice from the menu of writings citing a passage.
private final class CitationMenuTarget: NSObject {
    var marks: [String: WritingCitationMark] = [:]
    private let onSelect: (WritingCitationMark) -> Void

    init(onSelect: @escaping (WritingCitationMark) -> Void) {
        self.onSelect = onSelect
    }

    @MainActor @objc func select(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let mark = marks[id] else { return }
        onSelect(mark)
    }
}

/// The reader's part of "Quote in Writing": the menu command and its error alert.
private struct WritingQuoteSupport: ViewModifier {
    @Environment(\.localizationBundle) private var bundle
    @Binding var errorMessage: String?
    var action: QuoteInWritingAction?

    func body(content: Content) -> some View {
        content
            .focusedSceneValue(\.quoteInWritingAction, action)
            .alert(
                String(localized: "Unable to Quote in Writing", bundle: bundle),
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { isPresented in
                        if !isPresented {
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
}
