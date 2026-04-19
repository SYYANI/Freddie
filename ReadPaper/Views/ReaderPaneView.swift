import PDFKit
import SwiftData
import SwiftUI

struct ReaderPaneView: View {
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
    @Query(sort: \ReadingState.modifiedAt, order: .reverse) private var readingStates: [ReadingState]

    var paper: Paper?
    var attachments: [PaperAttachment]
    var settings: AppSettings?
    @Binding var readerMode: ReaderMode
    @Binding var displayMode: TranslationDisplayMode
    @Binding var isInspectorCollapsed: Bool

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
    @State private var lastPDFReaderMode: ReaderMode = .pdf
    @State private var suspendReadingStatePersistence = false
    @State private var showPDFTranslationScopeDialog = false
    @State private var pdfTranslationTotalPages: Int = 0

    private var pdfAttachment: PaperAttachment? {
        attachments.first { $0.kind == .pdf }
    }

    private var htmlAttachment: PaperAttachment? {
        attachments.first { $0.kind == .html }
    }

    private var translatedPDFAttachment: PaperAttachment? {
        attachments.first { $0.kind == .translatedPDF }
    }

    private var originalPDFPageCount: Int? {
        guard let url = pdfAttachment?.fileURL else { return nil }
        return PDFDocument(url: url)?.pageCount
    }

    private var isPartialPDFTranslation: Bool {
        guard let attachment = translatedPDFAttachment,
              let lastPage = attachment.translatedLastPage,
              let total = originalPDFPageCount
        else { return false }
        return lastPage < total
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
        pdfAttachment != nil && settings != nil && !isFullPDFTranslationComplete
    }

    private var isFullPDFTranslationComplete: Bool {
        guard let attachment = translatedPDFAttachment else { return false }
        guard let lastPage = attachment.translatedLastPage else { return true }
        guard let total = originalPDFPageCount else { return true }
        return lastPage >= total
    }

    private var translationControlsDisabled: Bool {
        isWorking || (!canTranslateHTML && !canTranslatePDF)
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

    var body: some View {
        readerSurface
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
            .toolbar {
                readerToolbar
            }
            .onAppear(perform: restoreReadingStateForCurrentPaper)
            .onChange(of: paper?.id) { _, _ in
                restoreReadingStateForCurrentPaper()
            }
            .onChange(of: readerAvailability) { _, _ in
                syncReaderModeWithAvailableContent()
            }
            .onChange(of: readerMode) { _, newValue in
                if newValue != .html {
                    lastPDFReaderMode = normalizedPDFReaderMode(newValue)
                }
                persistReadingStateIfNeeded()
            }
            .onChange(of: pdfPageIndex) { _, _ in
                persistReadingStateIfNeeded()
            }
            .onChange(of: htmlScrollRatio) { _, _ in
                persistReadingStateIfNeeded()
            }
            .onDisappear(perform: persistReadingStateIfNeeded)
            .confirmationDialog(
                String(localized: "Choose Translation Scope", bundle: bundle),
                isPresented: $showPDFTranslationScopeDialog,
                titleVisibility: .visible
            ) {
                Button(String(localized: "First 10 Pages", bundle: bundle)) {
                    startPDFTranslation(scope: .firstPages(10))
                }
                Button(String(localized: "All Pages", bundle: bundle)) {
                    startPDFTranslation(scope: .allPages)
                }
                Button(String(localized: "Cancel", bundle: bundle), role: .cancel) {}
            } message: {
                Text(AppLocalization.format("This PDF has %d pages. Translating the first 10 pages is faster.", pdfTranslationTotalPages))
            }
    }

    private var readerSurface: some View {
        VStack(spacing: 0) {
            paneHeader
            Divider()

            if isWorking || statusMessage != nil {
                statusRow
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(nsColor: .windowBackgroundColor))

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
        HStack(spacing: 12) {
            Text("READER", bundle: bundle)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(1.1)

            if let paper {
                Text(paper.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                Text("Select a paper to start reading", bundle: bundle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .frame(minHeight: 20)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
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
            } else {
                ToolbarItem(placement: .primaryAction) {
                    pdfDisplayPicker
                }
            }

            ToolbarItemGroup(placement: .primaryAction) {
                translationMenu

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
                } else {
                    Label(String(localized: "Translate PDF", bundle: bundle), systemImage: "doc")
                        .labelStyle(.titleAndIcon)
                }
            }
            .disabled(canTranslatePDF == false)
        } label: {
            Label(String(localized: "Translate", bundle: bundle), systemImage: "translate")
                .labelStyle(.iconOnly)
        }
        .menuIndicator(.hidden)
        .disabled(translationControlsDisabled)
        .help(translationMenuHelpText)
    }

    private var translationMenuHelpText: String {
        if isWorking {
            return String(localized: "Translation in Progress", bundle: bundle)
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
        if paper == nil {
            emptyReaderState
        } else {
            switch readerMode {
            case .html:
                if let htmlFileURL = htmlAttachment?.fileURL {
                    HTMLReaderView(
                        fileURL: htmlFileURL,
                        displayMode: displayMode,
                        reloadToken: htmlReloadToken,
                        scrollRatio: $htmlScrollRatio,
                        segmentUpdate: htmlSegmentUpdate
                    )
                } else {
                    centeredUnavailableView(
                        String(localized: "No HTML available", bundle: bundle),
                        systemImage: "doc.text",
                        description: Text("Import an arXiv paper with HTML content to read it here.", bundle: bundle)
                    )
                }
            case .pdf:
                labeledPDFReader(
                    fileURL: pdfAttachment?.fileURL,
                    label: String(localized: "Original", bundle: bundle),
                    emptyTitle: String(localized: "No PDF available", bundle: bundle),
                    emptyDescription: String(localized: "Import a PDF or fetch one from arXiv to read it here.", bundle: bundle)
                )
            case .bilingualPDF:
                if translatedPDFAttachment != nil {
                    DualPDFReaderView(
                        originalURL: pdfAttachment?.fileURL,
                        translatedURL: translatedPDFAttachment?.fileURL,
                        pageIndex: $pdfPageIndex,
                        reloadToken: pdfReloadToken
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
                    label: String(localized: "Translation", bundle: bundle),
                    emptyTitle: String(localized: "No translated PDF", bundle: bundle),
                    emptyDescription: String(localized: "Run PDF translation first to read the translated PDF on its own.", bundle: bundle),
                    reloadToken: pdfReloadToken
                )
            }
        }
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
                translationProgress = nil
                statusMessage = AppLocalization.errorMessage(error, bundle: bundle)
            }
            isWorking = false
            isCancelling = false
            translationTask = nil
        }
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
        if totalPages > 10 {
            pdfTranslationTotalPages = totalPages
            showPDFTranslationScopeDialog = true
        } else {
            startPDFTranslation(scope: .allPages)
        }
    }

    private func startPDFTranslation(scope: PDFTranslationScope) {
        guard let paper, let pdfAttachment, let settings else { return }
        let preferences = TranslationPreferencesSnapshot(settings)
        let pageRange: ClosedRange<Int>? = {
            switch scope {
            case .firstPages(let count):
                return 1...count
            case .allPages:
                return nil
            }
        }()

        translationProgress = nil
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
                if try await toolManager.needsInstallOrRepair() {
                    statusMessage = String(localized: "Installing BabelDOC...", bundle: bundle)
                    let installResult = try await toolManager.installOrUpdateBabelDOC(version: preferences.babelDocVersion)
                    try Task.checkCancellation()
                    guard installResult.exitCode == 0 else {
                        throw BabelDocRunError.failed(installResult.combinedOutput)
                    }
                }
                statusMessage = String(localized: "Translating PDF with BabelDOC...", bundle: bundle)
                let outputDirectory = try PaperFileStore().translationsDirectory(for: paper)
                let toolEnvironment = try toolManager.environment()
                let translated = try await BabelDocRunner().translatePDF(
                    inputPDF: pdfAttachment.fileURL,
                    outputDirectory: outputDirectory,
                    preferences: preferences,
                    route: resolvedRoute.snapshot,
                    apiKey: resolvedRoute.apiKey,
                    babelDocPythonExecutable: try toolManager.babelDocPythonExecutableURL(),
                    bridgeScript: try toolManager.ensureProgressBridgeScript(),
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
                try Task.checkCancellation()
                let translatedLastPage: Int? = {
                    switch scope {
                    case .firstPages(let count):
                        return count
                    case .allPages:
                        return nil
                    }
                }()
                modelContext.insert(PaperAttachment(
                    paperID: paper.id,
                    kind: .translatedPDF,
                    source: .babeldoc,
                    filename: translated.lastPathComponent,
                    filePath: translated.path,
                    translatedLastPage: translatedLastPage
                ))
                try modelContext.save()
                readerMode = .bilingualPDF
                translationProgress = nil
                statusMessage = String(localized: "PDF translation completed.", bundle: bundle)
            } catch is CancellationError {
                translationProgress = nil
                statusMessage = String(localized: "Translation cancelled.", bundle: bundle)
            } catch {
                translationProgress = nil
                statusMessage = AppLocalization.errorMessage(error, bundle: bundle)
            }
            isWorking = false
            isCancelling = false
            translationTask = nil
        }
    }

    private func extendPDFTranslation() {
        guard let paper, let pdfAttachment, let settings, let existingAttachment = translatedPDFAttachment, let currentLastPage = existingAttachment.translatedLastPage else { return }
        guard let total = originalPDFPageCount, currentLastPage < total else { return }

        let nextBatch = min(currentLastPage + 10, total)
        let pageRange = (currentLastPage + 1)...nextBatch
        let preferences = TranslationPreferencesSnapshot(settings)

        translationProgress = nil
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
                if try await toolManager.needsInstallOrRepair() {
                    statusMessage = String(localized: "Installing BabelDOC...", bundle: bundle)
                    let installResult = try await toolManager.installOrUpdateBabelDOC(version: preferences.babelDocVersion)
                    try Task.checkCancellation()
                    guard installResult.exitCode == 0 else {
                        throw BabelDocRunError.failed(installResult.combinedOutput)
                    }
                }
                statusMessage = String(localized: "Translating PDF with BabelDOC...", bundle: bundle)
                let outputDirectory = try PaperFileStore().translationsDirectory(for: paper)
                let toolEnvironment = try toolManager.environment()

                guard let existingDoc = PDFDocument(url: existingAttachment.fileURL) else {
                    throw PDFMergerError.failedToOpenFile(existingAttachment.fileURL.path)
                }
                let trimmedExisting: PDFDocument = {
                    let doc = PDFDocument()
                    let pageCount = min(currentLastPage, existingDoc.pageCount)
                    for i in 0..<pageCount {
                        guard let page = existingDoc.page(at: i) else { continue }
                        doc.insert(page, at: i)
                    }
                    return doc
                }()

                let incrementPDF = try await BabelDocRunner().translatePDF(
                    inputPDF: pdfAttachment.fileURL,
                    outputDirectory: outputDirectory,
                    preferences: preferences,
                    route: resolvedRoute.snapshot,
                    apiKey: resolvedRoute.apiKey,
                    babelDocPythonExecutable: try toolManager.babelDocPythonExecutableURL(),
                    bridgeScript: try toolManager.ensureProgressBridgeScript(),
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
                try Task.checkCancellation()

                let mergedFilename = "merged-\(nextBatch)-\(UUID().uuidString.prefix(8)).pdf"
                let mergedURL = outputDirectory.appendingPathComponent(mergedFilename)
                let _ = try PDFMerger.merge(existing: trimmedExisting, increment: incrementPDF, output: mergedURL)

                // Clean up old merged PDF file to prevent storage bloat
                let oldFileURL = existingAttachment.fileURL
                if oldFileURL != mergedURL {
                    try? FileManager.default.removeItem(at: oldFileURL)
                }

                existingAttachment.filePath = mergedURL.path
                existingAttachment.filename = mergedFilename
                existingAttachment.translatedLastPage = nextBatch
                try modelContext.save()

                pdfReloadToken += 1
                translationProgress = nil
                statusMessage = String(localized: "PDF translation completed.", bundle: bundle)
            } catch is CancellationError {
                translationProgress = nil
                statusMessage = String(localized: "Translation cancelled.", bundle: bundle)
            } catch {
                translationProgress = nil
                statusMessage = AppLocalization.errorMessage(error, bundle: bundle)
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

    private var translateMoreBanner: some View {
        let lastPage = translatedPDFAttachment?.translatedLastPage ?? 0
        let total = originalPDFPageCount ?? 0
        let nextEnd = min(lastPage + 10, total)
        return HStack(spacing: 8) {
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
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor))
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
        label: String,
        emptyTitle: String,
        emptyDescription: String,
        reloadToken: Int = 0
    ) -> some View {
        if fileURL != nil {
            PDFReaderView(fileURL: fileURL, pageIndex: $pdfPageIndex, reloadToken: reloadToken)
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
                VStack(alignment: .leading, spacing: 12) {
                    Text("READY TO READ", bundle: bundle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .tracking(1.2)

                    Text("Build your local paper desk", bundle: bundle)
                        .font(.system(size: 30, weight: .semibold, design: .rounded))

                    Text("Import an arXiv paper or a local PDF from the sidebar. Once the first paper is added, HTML, PDF, bilingual reading, and translation tools all appear here.", bundle: bundle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

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
                        description: String(localized: "Add an arXiv ID, an arXiv URL, or a local PDF from the library sidebar.", bundle: bundle)
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

                HStack(spacing: 12) {
                    Image(systemName: "sidebar.left")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 36, height: 36)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Start from the left sidebar", bundle: bundle)
                            .font(.headline)
                        Text("Use the + button in the library to create the first paper record.", bundle: bundle)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 28)
            .padding(.bottom, 32)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func emptyStateCard(
        title: String,
        systemImage: String,
        description: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.primary)
                .frame(width: 40, height: 40)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))

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
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06))
        }
    }

    private func readerLabel(_ value: String) -> some View {
        Text(value)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            .padding(8)
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

    private func persistReadingStateIfNeeded() {
        guard !suspendReadingStatePersistence, let paper else { return }
        guard htmlAttachment != nil || pdfAttachment != nil || translatedPDFAttachment != nil else { return }

        let resolvedMode = ReadingStateStore.resolvedReaderMode(
            preferredMode: readerMode,
            hasHTML: htmlAttachment != nil,
            hasPDF: pdfAttachment != nil,
            hasTranslatedPDF: translatedPDFAttachment != nil
        )
        let attachmentID = attachmentID(for: resolvedMode)

        do {
            try ReadingStateStore().upsertState(
                for: paper.id,
                attachmentID: attachmentID,
                readerMode: resolvedMode,
                pageIndex: pdfPageIndex,
                scrollRatio: resolvedMode == .html ? htmlScrollRatio : 0,
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
