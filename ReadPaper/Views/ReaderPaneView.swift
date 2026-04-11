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

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ReadingState.modifiedAt, order: .reverse) private var readingStates: [ReadingState]

    var paper: Paper?
    var attachments: [PaperAttachment]
    var settings: AppSettings?
    @Binding var readerMode: ReaderMode
    @Binding var displayMode: TranslationDisplayMode

    @State private var pdfPageIndex = 0
    @State private var htmlScrollRatio = 0.0
    @State private var htmlReloadToken = 0
    @State private var htmlSegmentUpdate: HTMLTranslationSegmentUpdate?
    @State private var isWorking = false
    @State private var isCancelling = false
    @State private var statusMessage: String?
    @State private var translationProgress: TranslationProgressStatus?
    @State private var translationTask: Task<Void, Never>?
    @State private var lastPDFReaderMode: ReaderMode = .pdf
    @State private var suspendReadingStatePersistence = false

    private var pdfAttachment: PaperAttachment? {
        attachments.first { $0.kind == .pdf }
    }

    private var htmlAttachment: PaperAttachment? {
        attachments.first { $0.kind == .html }
    }

    private var translatedPDFAttachment: PaperAttachment? {
        attachments.first { $0.kind == .translatedPDF }
    }

    private var canTranslateHTML: Bool {
        htmlAttachment != nil && settings != nil
    }

    private var canTranslatePDF: Bool {
        pdfAttachment != nil && settings != nil
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
        }
    }

    private var paneHeader: some View {
        HStack(spacing: 12) {
            Text("READER")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(1.1)

            if let paper {
                Text(paper.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                Text("Select a paper to start reading")
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
                        Label(isCancelling ? "Cancelling..." : "Cancel", systemImage: "xmark.circle")
                    }
                    .labelStyle(.iconOnly)
                    .disabled(isCancelling)
                    .help(isCancelling ? "Cancelling translation..." : "Cancel Translation")
                }
            }
        }
    }

    private var readerModePicker: some View {
        Picker("Reader", selection: primaryReaderMode) {
            Text("HTML")
                .tag(PrimaryReaderMode.html)
            Text("PDF")
                .tag(PrimaryReaderMode.pdf)
        }
        .pickerStyle(.segmented)
        .frame(width: 120)
        .labelsHidden()
        .help("Switch between HTML and PDF reading")
    }

    private var htmlDisplayPicker: some View {
        Picker("Display", selection: $displayMode) {
            Text("Original")
                .tag(TranslationDisplayMode.original)
            Text("Bilingual")
                .tag(TranslationDisplayMode.bilingual)
            Text("Translated")
                .tag(TranslationDisplayMode.translated)
        }
        .pickerStyle(.segmented)
        .frame(width: 250)
        .labelsHidden()
        .help("HTML Display Mode")
    }

    private var pdfDisplayPicker: some View {
        Picker("PDF Display", selection: pdfReaderModeSelection) {
            Text("Original")
                .tag(ReaderMode.pdf)
            Text("Bilingual")
                .tag(ReaderMode.bilingualPDF)    
            Text("Translated")
                .tag(ReaderMode.translatedPDF)
        }
        .pickerStyle(.segmented)
        .frame(width: 250)
        .labelsHidden()
        .help("PDF Display Mode")
    }

    private var translationMenu: some View {
        Menu {
            Button {
                translateHTML()
            } label: {
                Label("Translate HTML", systemImage: "globe")
                    .labelStyle(.titleAndIcon)
            }
            .disabled(canTranslateHTML == false)

            Button {
                translatePDF()
            } label: {
                Label("Translate PDF", systemImage: "doc")
                    .labelStyle(.titleAndIcon)
            }
            .disabled(canTranslatePDF == false)
        } label: {
            Label("Translate", systemImage: "translate")
                .labelStyle(.iconOnly)
        }
        .menuIndicator(.hidden)
        .disabled(translationControlsDisabled)
        .help(translationMenuHelpText)
    }

    private var translationMenuHelpText: String {
        if isWorking {
            return "Translation in Progress"
        }
        if canTranslateHTML && canTranslatePDF {
            return "Translate HTML or PDF"
        }
        if canTranslateHTML {
            return "Translate HTML"
        }
        if canTranslatePDF {
            return "Translate PDF"
        }
        return "Translation Unavailable"
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
                        "No HTML available",
                        systemImage: "doc.text",
                        description: Text("Import an arXiv paper with HTML content to read it here.")
                    )
                }
            case .pdf:
                labeledPDFReader(
                    fileURL: pdfAttachment?.fileURL,
                    label: "Original",
                    emptyTitle: "No PDF available",
                    emptyDescription: "Import a PDF or fetch one from arXiv to read it here."
                )
            case .bilingualPDF:
                if translatedPDFAttachment != nil {
                    DualPDFReaderView(
                        originalURL: pdfAttachment?.fileURL,
                        translatedURL: translatedPDFAttachment?.fileURL,
                        pageIndex: $pdfPageIndex
                    )
                } else {
                    centeredUnavailableView(
                        "No translated PDF",
                        systemImage: "character.book.closed",
                        description: Text("Run PDF translation first to compare the original and translated versions side by side.")
                    )
                }
            case .translatedPDF:
                labeledPDFReader(
                    fileURL: translatedPDFAttachment?.fileURL,
                    label: "Translation",
                    emptyTitle: "No translated PDF",
                    emptyDescription: "Run PDF translation first to read the translated PDF on its own."
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
                Text(statusMessage ?? "Working...")
                    .font(.caption)
                    .foregroundStyle(statusMessage?.hasPrefix("Error") == true ? .red : .secondary)
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
        statusMessage = "Translating HTML..."
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
                        statusMessage = totalSegments > 0 ? "Translating HTML..." : "Preparing HTML translation..."
                    },
                    onSegmentTranslated: { update in
                        displayMode = .bilingual
                        htmlSegmentUpdate = update
                    }
                )
                try Task.checkCancellation()
                displayMode = .bilingual
                translationProgress = nil
                statusMessage = "HTML translation completed."
            } catch is CancellationError {
                translationProgress = nil
                statusMessage = "Translation cancelled."
            } catch {
                translationProgress = nil
                statusMessage = "Error: \(error.localizedDescription)"
            }
            isWorking = false
            isCancelling = false
            translationTask = nil
        }
    }

    private func translatePDF() {
        guard let paper, let pdfAttachment, let settings else { return }
        let preferences = TranslationPreferencesSnapshot(settings)
        translationProgress = nil
        isWorking = true
        isCancelling = false
        statusMessage = "Running BabelDOC..."
        translationTask = Task {
            do {
                try Task.checkCancellation()
                let resolvedRoute = try LLMRouteResolver().resolvePDFRoute(
                    settings: settings,
                    modelContext: modelContext
                )
                let toolManager = BabelDocToolManager()
                if try toolManager.detect() != .ready {
                    statusMessage = "Installing BabelDOC..."
                    let installResult = try await toolManager.installOrUpdateBabelDOC(version: preferences.babelDocVersion)
                    try Task.checkCancellation()
                    guard installResult.exitCode == 0 else {
                        throw BabelDocRunError.failed(installResult.combinedOutput)
                    }
                }
                statusMessage = "Translating PDF with BabelDOC..."
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
                    environment: toolEnvironment,
                    onStatusUpdate: { message in
                        Task { @MainActor in
                            guard isWorking, !isCancelling else { return }
                            if translationProgress == nil || message.hasPrefix("BabelDOC error") {
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
                modelContext.insert(PaperAttachment(
                    paperID: paper.id,
                    kind: .translatedPDF,
                    source: .babeldoc,
                    filename: translated.lastPathComponent,
                    filePath: translated.path
                ))
                try modelContext.save()
                readerMode = .bilingualPDF
                translationProgress = nil
                statusMessage = "PDF translation completed."
            } catch is CancellationError {
                translationProgress = nil
                statusMessage = "Translation cancelled."
            } catch {
                translationProgress = nil
                statusMessage = "Error: \(error.localizedDescription)"
            }
            isWorking = false
            isCancelling = false
            translationTask = nil
        }
    }

    private func cancelTranslation() {
        guard isWorking else { return }
        isCancelling = true
        statusMessage = "Cancelling translation..."
        translationTask?.cancel()
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
        emptyDescription: String
    ) -> some View {
        if fileURL != nil {
            PDFReaderView(fileURL: fileURL, pageIndex: $pdfPageIndex)
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
                    Text("READY TO READ")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .tracking(1.2)

                    Text("Build your local paper desk")
                        .font(.system(size: 30, weight: .semibold, design: .rounded))

                    Text("Import an arXiv paper or a local PDF from the sidebar. Once the first paper is added, HTML, PDF, bilingual reading, and translation tools all appear here.")
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
                        title: "Import",
                        systemImage: "square.and.arrow.down",
                        description: "Add an arXiv ID, an arXiv URL, or a local PDF from the library sidebar."
                    )
                    emptyStateCard(
                        title: "Read",
                        systemImage: "doc.richtext",
                        description: "Switch between localized HTML, original PDF, translated PDF, and side-by-side PDF comparison."
                    )
                    emptyStateCard(
                        title: "Translate",
                        systemImage: "character.book.closed",
                        description: "Run semantic HTML translation incrementally, or send the PDF through BabelDOC when you need a full translated document."
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
                        Text("Start from the left sidebar")
                            .font(.headline)
                        Text("Use the + button in the library to create the first paper record.")
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
