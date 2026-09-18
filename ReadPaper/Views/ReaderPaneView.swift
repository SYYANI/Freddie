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

    private enum PDFTranslationScope {
        case firstPages(Int)
        case allPages
    }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.localizationBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.pdfDisplayAppearance) private var pdfDisplayAppearance
    @Query(sort: \ReadingState.modifiedAt, order: .reverse) private var readingStates: [ReadingState]
    @AppStorage(PDFTranslationBatchPreference.userDefaultsKey)
    private var pdfTranslationBatchSizeRawValue = PDFTranslationBatchPreference.defaultValue
    @AppStorage(HTMLReaderTypography.fontSizeUserDefaultsKey)
    private var htmlReaderFontSize = HTMLReaderTypography.defaultFontSize
    @AppStorage(BabelDocSemanticHintPreference.userDefaultsKey)
    private var babelDocSemanticHintsEnabled = BabelDocSemanticHintPreference.defaultValue
    @AppStorage(LaTeXIntegrationPreferences.translationEnabledKey)
    private var latexTranslationEnabled = false

    var paper: Paper?
    var attachments: [PaperAttachment]
    var notes: [Note]
    var settings: AppSettings?
    @Binding var readerMode: ReaderMode
    @Binding var displayMode: TranslationDisplayMode
    @Binding var isInspectorCollapsed: Bool
    @Binding var noteSelectionContext: NoteSelectionContext?
    @Binding var noteNavigationRequest: NoteNavigationRequest?
    var onCreateAnchoredNote: () -> Void
    var onSaveSelectionAssistantNote: @MainActor @Sendable (
        NoteSelectionContext,
        String,
        UUID?
    ) throws -> UUID
    var onArxivLinkActivated: (URL) -> Void

    @State private var pdfPageIndex = 0
    @State private var htmlScrollRatio = 0.0
    @State private var htmlReloadToken = 0
    @State private var pdfReloadToken = 0
    @State private var htmlSegmentUpdate: HTMLTranslationSegmentUpdate?
    @State private var isWorking = false
    @State private var isCancelling = false
    @State private var statusMessage: String?
    @State private var translationProgress: TranslationProgressStatus?
    @State private var translationTask: Task<Void, Never>?
    @State private var pdfTranslationErrorLogURL: URL?
    @State private var pdfTranslationDiagnosticsNoticeID: String?
    @State private var latexTranslationErrorLogURL: URL?
    @State private var lastPDFReaderMode: ReaderMode = .pdf
    @State private var suspendReadingStatePersistence = false
    @State private var pendingReadingStatePersistence: ReadingStatePersistenceSnapshot?
    @State private var readingStatePersistenceTask: Task<Void, Never>?
    @State private var showPDFTranslationScopeDialog = false
    @State private var pdfTranslationTotalPages: Int = 0
    @State private var digestNoticeMessage: String?
    @State private var digestNoticeTitle: String?
    @State private var digestErrorMessage: String?
    @State private var copyToastMessage: String?
    @State private var copyToastDismissTask: Task<Void, Never>?
    @State private var pdfDebugModeEnabled = false
    @State private var pdfDebugExportDirectoryURL: URL?
    @State private var pdfDebugDirectoryHasSecurityScope = false
    @StateObject private var pdfAnnotationSession = PDFAnnotationSession()
    @State private var pdfAnnotationNoteText = ""
    @State private var selectionAssistantSelection: NoteSelectionContext?
    @State private var isSelectionAssistantPinned = false
    @State private var selectionAssistantDismissTask: Task<Void, Never>?
    @State private var selectionAssistantProgress: SelectionAssistantProgress?
    @State private var selectionAssistantInitialConversation: SelectionAssistantConversationSnapshot?
    @State private var selectionAssistantHistoryAnchors: [SelectionAssistantHistoryAnchor] = []
    @State private var htmlSelectionHighlightResetToken = 0
    @State private var htmlNativeSelectionClearToken = 0
    @State private var originalPDFPageCount: Int?

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
        isWorking || (!canTranslateHTML && !canTranslatePDF && !canTranslateLaTeX)
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
        guard let paper else { return nil }
        return readingStates.first { $0.paperID == paper.id }
    }

    private var restoredHTMLScrollRatio: Double {
        ReadingStateStore.clampedScrollRatio(readingState?.scrollRatio ?? 0)
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

    private var readerBody: some View {
        readerSurface
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                ReadPaperAppearanceSurface(role: .reader)
                    .ignoresSafeArea()
            }
            .overlay(alignment: .bottom) {
                if let copyToastMessage {
                    copyToast(message: copyToastMessage)
                        .padding(.bottom, 20)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .zIndex(20)
                }
            }
            .animation(.easeOut(duration: 0.18), value: copyToastMessage != nil)
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
                flushPendingReadingStatePersistence()
                deactivatePDFTranslationDebugMode()
                pdfAnnotationSession.resetForDocumentChange()
                noteSelectionContext = nil
                clearSelectionAssistant()
                restoreReadingStateForCurrentPaper()
                refreshSelectionAssistantHistoryAnchors()
            }
            .onChange(of: readerAvailability) { _, _ in
                syncReaderModeWithAvailableContent()
                restorePDFTranslationDiagnostics()
            }
            .onChange(of: readerMode) { _, newValue in
                noteSelectionContext = nil
                clearSelectionAssistant()
                if newValue != .html {
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
            .onDisappear {
                flushReadingStatePersistence()
                deactivatePDFTranslationDebugMode()
                clearSelectionAssistant()
                dismissCopyToast()
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

    var body: some View {
        readerBody
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
            }

            if isWorking || statusMessage != nil {
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
            ToolbarItem(placement: .primaryAction) {
                readerModePicker
            }

            if readerMode == .html {
                ToolbarItem(placement: .primaryAction) {
                    htmlDisplayPicker
                }
                ToolbarItem(placement: .primaryAction) {
                    htmlTypographyMenu
                }
            } else {
                ToolbarItem(placement: .primaryAction) {
                    pdfDisplayPicker
                }
                ToolbarItem(placement: .primaryAction) {
                    pdfAnnotationMenu
                }
            }

            ToolbarItemGroup(placement: .primaryAction) {
                noteSelectionButton
                translationMenu
                #if DEBUG
                pdfTranslationDebugButton
                #endif
                exportMenu

                if isWorking {
                    Button {
                        cancelTranslation()
                    } label: {
                        Label(
                            isCancelling
                                ? String(localized: "Cancelling...", bundle: bundle)
                                : String(localized: "Cancel", bundle: bundle),
                            systemImage: "xmark.circle"
                        )
                    }
                    .labelStyle(.iconOnly)
                    .disabled(isCancelling)
                    .help(
                        isCancelling
                            ? String(localized: "Cancelling translation...", bundle: bundle)
                            : String(localized: "Cancel Translation", bundle: bundle)
                    )
                }
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
        Picker(String(localized: "Reader", bundle: bundle), selection: primaryReaderMode) {
            Text("HTML", bundle: bundle)
                .tag(PrimaryReaderMode.html)
            Text("PDF", bundle: bundle)
                .tag(PrimaryReaderMode.pdf)
        }
        .pickerStyle(.segmented)
        .frame(width: 120)
        .labelsHidden()
        .help(String(localized: "Switch between HTML and PDF reading", bundle: bundle))
    }

    private var htmlDisplayPicker: some View {
        Picker(String(localized: "Display", bundle: bundle), selection: $displayMode) {
            Text("Original", bundle: bundle)
                .tag(TranslationDisplayMode.original)
            Text("Bilingual", bundle: bundle)
                .tag(TranslationDisplayMode.bilingual)
            Text("Translated", bundle: bundle)
                .tag(TranslationDisplayMode.translated)
        }
        .pickerStyle(.segmented)
        .fixedSize()
        .labelsHidden()
        .help(String(localized: "HTML Display Mode", bundle: bundle))
    }

    private var htmlTypographyMenu: some View {
        Menu {
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
        } label: {
            Label(
                String(
                    format: String(localized: "Font Size: %d", bundle: bundle),
                    Int(HTMLReaderTypography.clampFontSize(htmlReaderFontSize).rounded())
                ),
                systemImage: "textformat.size"
            )
        }
        .labelStyle(.iconOnly)
        .help(
            String(
                format: String(localized: "HTML Font Size: %d", bundle: bundle),
                Int(HTMLReaderTypography.clampFontSize(htmlReaderFontSize).rounded())
            )
        )
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

    private var pdfDisplayPicker: some View {
        Picker(String(localized: "PDF Display", bundle: bundle), selection: pdfReaderModeSelection) {
            Text("Original", bundle: bundle)
                .tag(ReaderMode.pdf)
            Text("Bilingual", bundle: bundle)
                .tag(ReaderMode.bilingualPDF)    
            Text("Translated", bundle: bundle)
                .tag(ReaderMode.translatedPDF)
        }
        .pickerStyle(.segmented)
        .fixedSize()
        .labelsHidden()
        .help(String(localized: "PDF Display Mode", bundle: bundle))
    }

    private var pdfAnnotationMenu: some View {
        Menu {
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
                annotationLineWidthButton(1, title: String(localized: "Thin", bundle: bundle))
                annotationLineWidthButton(2, title: String(localized: "Medium", bundle: bundle))
                annotationLineWidthButton(5, title: String(localized: "Thick", bundle: bundle))
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
        } label: {
            Label(
                String(localized: "PDF Annotations", bundle: bundle),
                systemImage: pdfAnnotationToolSystemImage
            )
            .labelStyle(.iconOnly)
            .foregroundStyle(
                pdfAnnotationSession.interactionMode == .browse
                    ? Color.primary
                    : Color.accentColor
            )
        }
        .menuIndicator(.hidden)
        .disabled(pdfAnnotationSession.isDebugInteractionActive)
        .help(String(localized: "PDF Annotations", bundle: bundle))
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
                if isPartialPDFTranslation {
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

            if readerMode != .html {
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
            Label(String(localized: "Share", bundle: bundle), systemImage: "square.and.arrow.up")
                .labelStyle(.iconOnly)
        }
        .menuIndicator(.hidden)
        .help(String(localized: "Share Paper", bundle: bundle))
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
                                selectionHighlightResetToken: htmlSelectionHighlightResetToken,
                                nativeSelectionClearToken: htmlNativeSelectionClearToken,
                                onNoteSelectionChanged: handleNoteSelectionChange,
                                onSelectionAssistantDismissed: handleHTMLSelectionAssistantDismissal
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
                            fileURL: pdfAttachment?.fileURL,
                            attachmentID: pdfAttachment?.id,
                            label: String(localized: "Original", bundle: bundle),
                            emptyTitle: String(localized: "No PDF available", bundle: bundle),
                            emptyDescription: String(localized: "Import a PDF or fetch one from arXiv to read it here.", bundle: bundle)
                        )
                    case .bilingualPDF:
                        if translatedPDFAttachment != nil {
                            DualPDFReaderView(
                                paperID: paper?.id,
                                originalURL: pdfAttachment?.fileURL,
                                originalAttachmentID: pdfAttachment?.id,
                                translatedURL: translatedPDFAttachment?.fileURL,
                                translatedAttachmentID: translatedPDFAttachment?.id,
                                translatedLastPage: translatedPDFAttachment?.translatedLastPage,
                                displayAppearance: pdfDisplayAppearance,
                                pageIndex: $pdfPageIndex,
                                reloadToken: pdfReloadToken,
                                noteNavigationRequest: noteNavigationRequest,
                                selectionAssistantHistoryAnchors: selectionAssistantHistoryAnchors,
                                annotationSession: pdfAnnotationSession,
                                debugRegionSelectionEnabled: pdfDebugModeEnabled,
                                onDebugRegionSelected: handlePDFDebugRegionSelection,
                                onNoteSelectionChanged: handleNoteSelectionChange,
                                onArxivLinkActivated: onArxivLinkActivated
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
                    onDismiss: clearSelectionAssistant
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
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if isWorking, translationProgress == nil {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(statusMessage ?? String(localized: "Working...", bundle: bundle))
                    .font(.caption)
                    .foregroundStyle(AppLocalization.isErrorMessage(statusMessage, bundle: bundle) ? .red : .secondary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                if let translationProgress {
                    Text(translationProgress.summary)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
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

                if statusMessage != nil, !isWorking {
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

            if let translationProgress, translationProgress.total > 0 {
                ProgressView(
                    value: Double(translationProgress.completed),
                    total: Double(translationProgress.total)
                )
                .progressViewStyle(.linear)
                .controlSize(.small)
            }
        }
    }

    private func translateHTML() {
        guard let paper, let htmlAttachment, let settings else { return }
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
            do {
                try Task.checkCancellation()
                let resolvedRoute = try LLMRouteResolver().resolveHTMLRoute(
                    settings: settings,
                    modelContext: modelContext
                )
                try await HTMLTranslationPipeline().translateHTML(
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
                statusMessage = String(localized: "HTML translation completed.", bundle: bundle)
            } catch is CancellationError {
                translationProgress = nil
                statusMessage = String(localized: "Translation cancelled.", bundle: bundle)
            } catch {
                handleTranslationError(error)
            }
            isWorking = false
            isCancelling = false
            translationTask = nil
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
                if let storedJob = translationJob(id: jobID) {
                    storedJob.attachmentID = translatedAttachment?.id ?? sourceAttachment.id
                    storedJob.progress = output.pdfCompilationFailed ? 0.92 : 1
                    storedJob.state = output.pdfCompilationFailed ? .failed : .completed
                    storedJob.lastError = compilationFailureMessage
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
                    ?? String(localized: "LaTeX translation completed.", bundle: bundle)
            } catch is CancellationError {
                translationProgress = nil
                finishLaTeXJob(
                    id: jobID,
                    state: .failed,
                    error: String(localized: "Translation cancelled.", bundle: bundle)
                )
                statusMessage = String(localized: "Translation cancelled.", bundle: bundle)
            } catch {
                let message = ReadPaperLaTeXErrorPresentation.message(for: error, bundle: bundle)
                finishLaTeXJob(id: jobID, state: .failed, error: message)
                translationProgress = nil
                pdfTranslationErrorLogURL = nil
                statusMessage = message
            }
            isWorking = false
            isCancelling = false
            translationTask = nil
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

    private func finishLaTeXJob(id: UUID, state: TranslationJobState, error: String?) {
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

    private func translatePDF() {
        guard let pdfAttachment else { return }

        if isPartialPDFTranslation {
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
        guard let paper, let pdfAttachment, let settings else { return }
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
            } catch is CancellationError {
                translationProgress = nil
                pdfTranslationErrorLogURL = nil
                statusMessage = String(localized: "Translation cancelled.", bundle: bundle)
            } catch {
                handleTranslationError(error)
            }
            isWorking = false
            isCancelling = false
            translationTask = nil
        }
    }

    private func extendPDFTranslation(to requestedLastPage: Int? = nil) {
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
            } catch is CancellationError {
                translationProgress = nil
                pdfTranslationErrorLogURL = nil
                statusMessage = String(localized: "Translation cancelled.", bundle: bundle)
            } catch {
                handleTranslationError(error)
            }
            isWorking = false
            isCancelling = false
            translationTask = nil
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
                    extendPDFTranslation()
                } label: {
                    Text(AppLocalization.format("Translate pages %@–%@", "\(lastPage + 1)", "\(nextEnd)"))
                        .font(.caption)
                }
                .readPaperGlassButtonStyle(prominent: true)
                .controlSize(.small)

                if nextEnd < total {
                    Button {
                        extendPDFTranslation(to: total)
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
        label: String,
        emptyTitle: String,
        emptyDescription: String,
        reloadToken: Int = 0,
        debugRegionSelectionEnabled: Bool = false,
        onDebugRegionSelected: ((PDFDebugRegionSelection) -> Void)? = nil
    ) -> some View {
        if fileURL != nil {
            PDFDisplaySurface(appearance: pdfDisplayAppearance) {
                PDFReaderView(
                    fileURL: fileURL,
                    paperID: paper?.id,
                    attachmentID: attachmentID,
                    displayAppearance: pdfDisplayAppearance,
                    pageIndex: $pdfPageIndex,
                    reloadToken: reloadToken,
                    noteNavigationRequest: noteNavigationRequest,
                    selectionAssistantHistoryAnchors: selectionAssistantHistoryAnchors,
                    annotationSession: pdfAnnotationSession,
                    onNoteSelectionChanged: handleNoteSelectionChange,
                    onArxivLinkActivated: onArxivLinkActivated,
                    debugRegionSelectionEnabled: debugRegionSelectionEnabled,
                    onDebugRegionSelected: onDebugRegionSelected
                )
            }
                .overlay(alignment: .topLeading) {
                    readerLabel(label)
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

    private var emptyReaderState: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("Build your local paper desk", bundle: bundle)
                    .font(.system(
                        size: 30,
                        weight: .semibold,
                        design: pdfDisplayAppearance == .paper ? .serif : .rounded
                    ))

                LazyVGrid(
                    columns: [
                        GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 16, alignment: .top)
                    ],
                    alignment: .leading,
                    spacing: 16
                ) {
                    emptyStateCard(
                        title: String(localized: "Import", bundle: bundle),
                        systemImage: "square.and.arrow.down",
                        description: String(localized: "Add an arXiv ID, an arXiv URL, web page URL, or a local PDF from the library sidebar.", bundle: bundle)
                    )
                    emptyStateCard(
                        title: String(localized: "Read", bundle: bundle),
                        systemImage: "doc.richtext",
                        description: String(localized: "Switch between localized HTML, original PDF, translated PDF, and side-by-side PDF comparison.", bundle: bundle)
                    )
                    emptyStateCard(
                        title: String(localized: "Translate", bundle: bundle),
                        systemImage: "character.book.closed",
                        description: String(localized: "Run semantic HTML translation incrementally, or send the PDF through BabelDOC when you need a full translated document.", bundle: bundle)
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)

            }
            .padding(.horizontal, 32)
            .padding(.top, 28)
            .padding(.bottom, 32)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ReadPaperAppearanceSurface(role: .reader))
    }

    private func emptyStateCard(
        title: String,
        systemImage: String,
        description: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(
                    pdfDisplayAppearance == .paper
                        ? ReadPaperTheme.accentColor
                        : Color.primary
                )
                .frame(width: 40, height: 40)
                .background {
                    if pdfDisplayAppearance == .paper {
                        ReadPaperTheme.accentColor
                            .opacity(0.10)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    } else {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(.regularMaterial)
                    }
                }

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 168, maxHeight: .infinity, alignment: .topLeading)
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    pdfDisplayAppearance == .paper
                        ? ReadPaperTheme.cardColor(scheme: colorScheme)
                        : Color(nsColor: .controlBackgroundColor)
                )
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    pdfDisplayAppearance == .paper
                        ? ReadPaperTheme.cardBorderColor(scheme: colorScheme)
                        : Color.primary.opacity(0.06)
                )
        }
    }

    private func readerLabel(_ value: String) -> some View {
        Text(value)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .readPaperGlassEffect(in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .padding(8)
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
        guard paper != nil else { return }

        let restoredMode = ReadingStateStore.resolvedReaderMode(
            preferredMode: readingState?.readerMode,
            hasHTML: htmlAttachment != nil,
            hasPDF: pdfAttachment != nil,
            hasTranslatedPDF: translatedPDFAttachment != nil
        )
        let restoredPageIndex = max(0, readingState?.pageIndex ?? 0)
        let restoredScrollRatio = ReadingStateStore.clampedScrollRatio(readingState?.scrollRatio ?? 0)

        updateWithoutPersistingReadingState {
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
            return
        }

        let pageCount = await Task.detached(priority: .utility) {
            CGPDFDocument(request.fileURL as CFURL)?.numberOfPages
        }.value
        guard originalPDFPageCountRequest == request else { return }
        originalPDFPageCount = pageCount
    }

    private func readingStatePersistenceSnapshot() -> ReadingStatePersistenceSnapshot? {
        guard !suspendReadingStatePersistence, let paper else { return nil }
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
