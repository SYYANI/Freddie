import PDFKit
import SwiftData
import SwiftUI
import UIKit

struct IPadReaderPaneView: View {
    private enum PrimaryReaderMode: String, Identifiable {
        case html
        case pdf

        var id: String { rawValue }
    }

    private enum PDFTranslationScope {
        case firstPages(Int)
        case allPages
    }

    private struct TranslationProgressState: Equatable {
        let processed: Int
        let total: Int
    }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.localizationBundle) private var bundle
    @Environment(\.pdfDisplayAppearance) private var appearance
    @AppStorage(HTMLReaderTypography.fontSizeUserDefaultsKey)
    private var htmlFontSize = HTMLReaderTypography.defaultFontSize
    @AppStorage(PDFTranslationBatchPreference.userDefaultsKey)
    private var pdfTranslationBatchSizeRawValue = PDFTranslationBatchPreference.defaultValue
    @AppStorage(BabelDocSemanticHintPreference.userDefaultsKey)
    private var babelDocSemanticHintsEnabled = BabelDocSemanticHintPreference.defaultValue

    let paper: Paper?
    let attachments: [PaperAttachment]
    let settings: AppSettings?
    @Binding var noteSelectionContext: NoteSelectionContext?
    @Binding var noteNavigationRequest: NoteNavigationRequest?
    let onToggleInspector: () -> Void

    @State private var readerMode: ReaderMode = .pdf
    @State private var lastPDFReaderMode: ReaderMode = .pdf
    @State private var displayMode: TranslationDisplayMode = .bilingual
    @State private var pdfPageIndex = 0
    @State private var translatedPageIndex = 0
    @State private var pendingProgrammaticTranslatedPageTargets: Set<Int> = []
    @State private var pdfReloadToken = 0
    @State private var htmlScrollRatio = 0.0
    @State private var htmlReloadToken = 0
    @State private var htmlSegmentUpdate: HTMLTranslationSegmentUpdate?
    @State private var translationProgress: TranslationProgressState?
    @State private var pdfTranslationProgress: BabelDocProgressUpdate?
    @State private var translationStatus: String?
    @State private var translationTask: Task<Void, Never>?
    @State private var isTranslating = false
    @State private var showPDFTranslationScopeDialog = false
    @State private var pdfTranslationTotalPages = 0

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
        guard let pdfAttachment else { return nil }
        return PDFDocument(url: pdfAttachment.fileURL)?.pageCount
    }

    private var translatedPDFPageCount: Int {
        guard let translatedPDFAttachment else { return 0 }
        return PDFDocument(url: translatedPDFAttachment.fileURL)?.pageCount ?? 0
    }

    private var isPartialPDFTranslation: Bool {
        guard let lastPage = translatedPDFAttachment?.translatedLastPage,
              let total = originalPDFPageCount else { return false }
        return lastPage < total
    }

    private var isFullPDFTranslationComplete: Bool {
        guard let attachment = translatedPDFAttachment else { return false }
        guard let lastPage = attachment.translatedLastPage else { return true }
        guard let total = originalPDFPageCount else { return true }
        return lastPage >= total
    }

    private var isNearTranslationEdge: Bool {
        guard readerMode != .html,
              isPartialPDFTranslation,
              let lastPage = translatedPDFAttachment?.translatedLastPage else { return false }
        return pdfPageIndex >= max(0, lastPage - 2)
    }

    private var pdfTranslationBatchSize: Int {
        PDFTranslationBatchPreference.normalized(pdfTranslationBatchSizeRawValue)
    }

    private var primaryReaderMode: Binding<PrimaryReaderMode> {
        Binding(
            get: { readerMode == .html ? .html : .pdf },
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
            get: { normalizedPDFReaderMode(readerMode == .html ? lastPDFReaderMode : readerMode) },
            set: { newValue in
                let normalizedMode = normalizedPDFReaderMode(newValue)
                lastPDFReaderMode = normalizedMode
                readerMode = normalizedMode
            }
        )
    }

    private var shouldShowReaderHeader: Bool {
        isTranslating || translationStatus != nil || translationProgress != nil || pdfTranslationProgress != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            if paper != nil {
                if shouldShowReaderHeader {
                    readerHeader
                    Divider()
                }
                readerSurface
                if isNearTranslationEdge && !isTranslating {
                    Divider()
                    translateMoreBanner
                }
            } else {
                ContentUnavailableView {
                    Label {
                        Text("No paper selected", bundle: bundle)
                    } icon: {
                        Image(systemName: "doc.text")
                    }
                } description: {
                    Text("Select a paper from the library.", bundle: bundle)
                }
            }
        }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle(paper?.title ?? String(localized: "Reader", bundle: bundle))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            readerToolbar
        }
        .onAppear { restoreReadingState() }
        .onChange(of: paper?.id) { _, _ in
            noteSelectionContext = nil
            restoreReadingState()
        }
        .onChange(of: attachments.map {
            "\($0.id)-\($0.kindRawValue)-\($0.filePath)-\($0.translatedLastPage ?? -1)"
        }) { _, _ in
            normalizeReaderMode()
            syncTranslatedPageFromOriginal(pdfPageIndex)
        }
        .onChange(of: readerMode) { _, newValue in
            if newValue != .html {
                lastPDFReaderMode = normalizedPDFReaderMode(newValue)
            }
            persistReadingState()
        }
        .onChange(of: pdfPageIndex) { _, newValue in
            syncTranslatedPageFromOriginal(newValue)
            persistReadingState()
        }
        .onChange(of: htmlScrollRatio) { _, _ in persistReadingState() }
        .onChange(of: noteNavigationRequest?.id) { _, _ in revealNoteAnchor() }
        .onDisappear {
            persistReadingState()
            translationTask?.cancel()
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
    }

    @ToolbarContentBuilder
    private var readerToolbar: some ToolbarContent {
        if #available(iOS 26.0, *) {
            ToolbarItem(placement: .primaryAction) {
                primaryReaderModePicker
            }
            .sharedBackgroundVisibility(.hidden)

            ToolbarItem(placement: .primaryAction) {
                if readerMode == .html {
                    htmlDisplayPicker
                } else {
                    pdfDisplayPicker
                }
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .primaryAction) {
                primaryReaderModePicker
            }

            ToolbarItem(placement: .primaryAction) {
                if readerMode == .html {
                    htmlDisplayPicker
                } else {
                    pdfDisplayPicker
                }
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            translationMenu

            Button(action: copySourceLink) {
                Label(String(localized: "Copy Link", bundle: bundle), systemImage: "link")
            }
            .disabled(sourceURL == nil)

            if isTranslating {
                Button {
                    translationTask?.cancel()
                } label: {
                    Label(String(localized: "Cancel", bundle: bundle), systemImage: "xmark.circle")
                }
            }
        }

        if #available(iOS 26.0, *) {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }

        ToolbarItem(placement: .primaryAction) {
            Button(action: onToggleInspector) {
                Label(String(localized: "Inspector", bundle: bundle), systemImage: "sidebar.right")
            }
        }
    }

    private var readerHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let progress = pdfTranslationProgress, progress.total > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: progress.completed, total: progress.total)
                    if progress.summary != translationStatus {
                        Text(progress.summary)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            } else if let progress = translationProgress, progress.total > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: Double(progress.processed), total: Double(progress.total))
                    Text("\(progress.processed)/\(progress.total)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if let translationStatus {
                HStack(spacing: 8) {
                    Text(translationStatus)
                        .font(.caption)
                        .foregroundStyle(AppLocalization.isErrorMessage(translationStatus, bundle: bundle) ? .red : .secondary)

                    Spacer(minLength: 0)

                    if !isTranslating {
                        Button {
                            dismissTranslationStatus()
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(Text("Close", bundle: bundle))
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var primaryReaderModePicker: some View {
        Picker(String(localized: "Reader", bundle: bundle), selection: primaryReaderMode) {
            Text("HTML", bundle: bundle)
                .tag(PrimaryReaderMode.html)
            Text("PDF", bundle: bundle)
                .tag(PrimaryReaderMode.pdf)
        }
        .pickerStyle(.segmented)
        .frame(width: 140)
        .labelsHidden()
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
        .frame(width: 270)
        .labelsHidden()
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
        .frame(width: 270)
        .labelsHidden()
    }

    private var translationMenu: some View {
        Menu {
            Button {
                translateHTML()
            } label: {
                Label(String(localized: "Translate HTML", bundle: bundle), systemImage: "globe")
            }
            .disabled(htmlAttachment == nil || settings == nil)

            Button {
                translatePDF()
            } label: {
                Label(
                    isPartialPDFTranslation
                        ? String(localized: "Translate More PDF Pages", bundle: bundle)
                        : String(localized: "Translate PDF", bundle: bundle),
                    systemImage: "doc"
                )
            }
            .disabled(pdfAttachment == nil || settings == nil || isFullPDFTranslationComplete)
        } label: {
            Label(String(localized: "Translate", bundle: bundle), systemImage: "translate")
                .labelStyle(.iconOnly)
        }
        .menuIndicator(.hidden)
        .disabled(isTranslating || (htmlAttachment == nil && pdfAttachment == nil))
    }

    @ViewBuilder
    private var readerSurface: some View {
        switch readerMode {
        case .html:
            if let htmlAttachment {
                HTMLReaderView(
                    fileURL: htmlAttachment.fileURL,
                    attachmentID: htmlAttachment.id,
                    displayMode: displayMode,
                    displayAppearance: appearance,
                    fontSize: htmlFontSize,
                    reloadToken: htmlReloadToken,
                    initialScrollRatio: htmlScrollRatio,
                    scrollRatio: $htmlScrollRatio,
                    segmentUpdate: htmlSegmentUpdate,
                    noteNavigationRequest: noteNavigationRequest,
                    onNoteSelectionChanged: { noteSelectionContext = $0 }
                )
            } else {
                unavailable(
                    String(localized: "No HTML available", bundle: bundle),
                    systemImage: "doc.text",
                    description: Text(
                        "Import an arXiv paper or web page with HTML content to read it here.",
                        bundle: bundle
                    )
                )
            }
        case .pdf:
            if let pdfAttachment {
                PDFDisplaySurface(appearance: appearance) {
                    PDFReaderView(
                        fileURL: pdfAttachment.fileURL,
                        attachmentID: pdfAttachment.id,
                        displayAppearance: appearance,
                        pageIndex: $pdfPageIndex,
                        reloadToken: pdfReloadToken,
                        onNoteSelectionChanged: { noteSelectionContext = $0 }
                    )
                }
            } else {
                unavailable(String(localized: "PDF is not available for this paper.", bundle: bundle))
            }
        case .bilingualPDF:
            if let pdfAttachment, let translatedPDFAttachment {
                HStack(spacing: 0) {
                    PDFDisplaySurface(appearance: appearance) {
                        PDFReaderView(
                            fileURL: pdfAttachment.fileURL,
                            attachmentID: pdfAttachment.id,
                            displayAppearance: appearance,
                            pageIndex: $pdfPageIndex,
                            reloadToken: pdfReloadToken,
                            onNoteSelectionChanged: { noteSelectionContext = $0 }
                        )
                    }
                    Divider()
                    PDFDisplaySurface(appearance: appearance) {
                        PDFReaderView(
                            fileURL: translatedPDFAttachment.fileURL,
                            attachmentID: translatedPDFAttachment.id,
                            displayAppearance: appearance,
                            pageIndex: translatedPageBinding,
                            reloadToken: pdfReloadToken,
                            onNoteSelectionChanged: { noteSelectionContext = $0 }
                        )
                    }
                }
            } else {
                unavailable(
                    String(localized: "No translated PDF", bundle: bundle),
                    systemImage: "character.book.closed",
                    description: Text(
                        "Run PDF translation first to compare the original and translated versions side by side.",
                        bundle: bundle
                    )
                )
            }
        case .translatedPDF:
            if let translatedPDFAttachment {
                PDFDisplaySurface(appearance: appearance) {
                    PDFReaderView(
                        fileURL: translatedPDFAttachment.fileURL,
                        attachmentID: translatedPDFAttachment.id,
                        displayAppearance: appearance,
                        pageIndex: translatedPageBinding,
                        reloadToken: pdfReloadToken,
                        onNoteSelectionChanged: { noteSelectionContext = $0 }
                    )
                }
            } else {
                unavailable(
                    String(localized: "No translated PDF", bundle: bundle),
                    systemImage: "doc.richtext",
                    description: Text(
                        "Run PDF translation first to read the translated PDF on its own.",
                        bundle: bundle
                    )
                )
            }
        }
    }

    private var translatedPageBinding: Binding<Int> {
        Binding(
            get: { translatedPageIndex },
            set: { newValue in
                let clamped = DualPDFPageIndexSync.translatedPageIndex(
                    forOriginalPageIndex: newValue,
                    translatedPageCount: translatedPDFPageCount
                )
                translatedPageIndex = clamped
                let originalTarget = DualPDFPageIndexSync.originalPageIndex(
                    forTranslatedPageIndex: clamped,
                    translatedPageCount: translatedPDFPageCount,
                    pendingProgrammaticTargets: &pendingProgrammaticTranslatedPageTargets
                )
                if let originalTarget, pdfPageIndex != originalTarget {
                    pdfPageIndex = originalTarget
                }
            }
        )
    }

    private func syncTranslatedPageFromOriginal(_ originalPageIndex: Int) {
        guard translatedPDFPageCount > 0 else {
            pendingProgrammaticTranslatedPageTargets.removeAll()
            translatedPageIndex = 0
            return
        }
        let target = DualPDFPageIndexSync.translatedPageIndex(
            forOriginalPageIndex: originalPageIndex,
            translatedPageCount: translatedPDFPageCount
        )
        guard translatedPageIndex != target else { return }
        pendingProgrammaticTranslatedPageTargets.insert(target)
        translatedPageIndex = target
    }

    private func unavailable(_ message: String) -> some View {
        ContentUnavailableView {
            Label(message, systemImage: "doc.questionmark")
        }
    }

    private func unavailable(
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

    private var sourceURL: URL? {
        guard let paper else { return nil }
        if let arxivID = paper.arxivID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !arxivID.isEmpty {
            return URL(string: "https://arxiv.org/abs/\(arxivID)")
        }
        if let doi = paper.doi?.trimmingCharacters(in: .whitespacesAndNewlines),
           !doi.isEmpty {
            return URL(string: "https://doi.org/\(doi)")
        }
        if let htmlURL = paper.htmlURLString.flatMap(URL.init(string:)) {
            return htmlURL
        }
        return paper.pdfURLString.flatMap(URL.init(string:))
    }

    private func copySourceLink() {
        guard let sourceURL else { return }
        UIPasteboard.general.string = sourceURL.absoluteString
        translationStatus = String(localized: "Link copied to the clipboard.", bundle: bundle)
    }

    private func translateHTML() {
        guard let paper, let htmlAttachment, let settings else { return }
        translationTask?.cancel()
        isTranslating = true
        translationStatus = String(localized: "Translating HTML...", bundle: bundle)
        translationProgress = nil
        pdfTranslationProgress = nil
        htmlSegmentUpdate = nil

        translationTask = Task { @MainActor in
            do {
                let route = try LLMRouteResolver().resolveHTMLRoute(
                    settings: settings,
                    modelContext: modelContext
                )
                try await HTMLTranslationPipeline().translateHTML(
                    attachment: htmlAttachment,
                    paper: paper,
                    preferences: TranslationPreferencesSnapshot(settings),
                    route: route.snapshot,
                    apiKey: route.apiKey,
                    modelContext: modelContext,
                    onDocumentPrepared: {
                        displayMode = .bilingual
                        htmlReloadToken += 1
                    },
                    onProgressUpdated: { processed, total in
                        translationProgress = .init(processed: processed, total: total)
                    },
                    onSegmentTranslated: { update in
                        displayMode = .bilingual
                        htmlSegmentUpdate = update
                    }
                )
                translationStatus = String(localized: "HTML translation completed.", bundle: bundle)
            } catch is CancellationError {
                translationStatus = String(localized: "Translation cancelled.", bundle: bundle)
            } catch {
                translationStatus = AppLocalization.errorMessage(error, bundle: bundle)
            }
            translationProgress = nil
            isTranslating = false
            translationTask = nil
        }
    }

    private func translatePDF() {
        guard let pdfAttachment,
              let document = PDFDocument(url: pdfAttachment.fileURL),
              document.pageCount > 0,
              !isFullPDFTranslationComplete else { return }
        if isPartialPDFTranslation {
            extendPDFTranslation()
        } else if document.pageCount > pdfTranslationBatchSize {
            pdfTranslationTotalPages = document.pageCount
            showPDFTranslationScopeDialog = true
        } else {
            startPDFTranslation(scope: .allPages)
        }
    }

    private func startPDFTranslation(scope: PDFTranslationScope) {
        guard let paper, let pdfAttachment, let settings else { return }
        let pageRange: ClosedRange<Int>? = {
            switch scope {
            case .firstPages(let count):
                1...min(count, originalPDFPageCount ?? count)
            case .allPages:
                nil
            }
        }()

        beginPDFTranslation()
        translationTask = Task { @MainActor in
            do {
                let resolvedRoute = try LLMRouteResolver().resolvePDFRoute(
                    settings: settings,
                    modelContext: modelContext
                )
                let outputDirectory = try PaperFileStore().translationsDirectory(for: paper)
                let arxivIdentifier = paper.arxivID.map {
                    ReadPaperArXivIdentifier.resolving(id: $0, version: paper.arxivVersion)
                }
                let semanticHints = try await BabelDocSemanticHintService().prepareIfAvailable(
                    isEnabled: babelDocSemanticHintsEnabled,
                    paperID: paper.id,
                    arxivIdentifier: arxivIdentifier
                ) { update in
                    Task { @MainActor in translationStatus = update.localizedMessage }
                }
                let translated = try await InProcessBabelDocRunner().translatePDF(
                    inputPDF: pdfAttachment.fileURL,
                    outputDirectory: outputDirectory,
                    preferences: TranslationPreferencesSnapshot(settings),
                    route: resolvedRoute.snapshot,
                    apiKey: resolvedRoute.apiKey,
                    documentTitle: paper.title,
                    semanticHints: semanticHints?.document,
                    pageRange: pageRange,
                    onProgressUpdate: { progress in
                        Task { @MainActor in handlePDFProgress(progress) }
                    }
                )
                try Task.checkCancellation()
                let lastPage: Int? = pageRange?.upperBound
                modelContext.insert(PaperAttachment(
                    paperID: paper.id,
                    kind: .translatedPDF,
                    source: .babeldoc,
                    filename: translated.lastPathComponent,
                    filePath: translated.path,
                    translatedLastPage: lastPage
                ))
                try modelContext.save()
                syncTranslatedPageFromOriginal(pdfPageIndex)
                readerMode = .bilingualPDF
                finishPDFTranslation(message: String(localized: "PDF translation completed.", bundle: bundle))
            } catch is CancellationError {
                finishPDFTranslation(message: String(localized: "Translation cancelled.", bundle: bundle))
            } catch {
                finishPDFTranslation(message: AppLocalization.errorMessage(error, bundle: bundle))
            }
        }
    }

    private func extendPDFTranslation(to requestedLastPage: Int? = nil) {
        guard let paper, let pdfAttachment, let settings,
              let existingAttachment = translatedPDFAttachment,
              let currentLastPage = existingAttachment.translatedLastPage,
              let totalPages = originalPDFPageCount,
              currentLastPage < totalPages else { return }

        let nextLastPage = min(requestedLastPage ?? currentLastPage + pdfTranslationBatchSize, totalPages)
        guard nextLastPage > currentLastPage else { return }
        let pageRange = (currentLastPage + 1)...nextLastPage
        beginPDFTranslation()
        translationTask = Task { @MainActor in
            do {
                let resolvedRoute = try LLMRouteResolver().resolvePDFRoute(
                    settings: settings,
                    modelContext: modelContext
                )
                let outputDirectory = try PaperFileStore().translationsDirectory(for: paper)
                let arxivIdentifier = paper.arxivID.map {
                    ReadPaperArXivIdentifier.resolving(id: $0, version: paper.arxivVersion)
                }
                let semanticHints = try await BabelDocSemanticHintService().prepareIfAvailable(
                    isEnabled: babelDocSemanticHintsEnabled,
                    paperID: paper.id,
                    arxivIdentifier: arxivIdentifier
                ) { update in
                    Task { @MainActor in translationStatus = update.localizedMessage }
                }
                let increment = try await InProcessBabelDocRunner().translatePDF(
                    inputPDF: pdfAttachment.fileURL,
                    outputDirectory: outputDirectory,
                    preferences: TranslationPreferencesSnapshot(settings),
                    route: resolvedRoute.snapshot,
                    apiKey: resolvedRoute.apiKey,
                    documentTitle: paper.title,
                    semanticHints: semanticHints?.document,
                    pageRange: pageRange,
                    onProgressUpdate: { progress in
                        Task { @MainActor in handlePDFProgress(progress) }
                    }
                )
                try Task.checkCancellation()
                let oldURL = existingAttachment.fileURL
                try TranslatedPDFPageBoundsNormalizer.normalize(at: oldURL)
                let mergedURL = outputDirectory.appendingPathComponent(
                    "merged-\(nextLastPage)-\(UUID().uuidString.prefix(8)).pdf"
                )
                _ = try await PDFMerger.mergeInBackground(
                    existing: oldURL,
                    increment: increment,
                    output: mergedURL
                )
                try? FileManager.default.removeItem(at: increment)
                existingAttachment.filePath = mergedURL.path
                existingAttachment.filename = mergedURL.lastPathComponent
                existingAttachment.translatedLastPage = nextLastPage
                try modelContext.save()
                if oldURL != mergedURL { try? FileManager.default.removeItem(at: oldURL) }
                pdfReloadToken += 1
                syncTranslatedPageFromOriginal(pdfPageIndex)
                finishPDFTranslation(message: String(localized: "PDF translation completed.", bundle: bundle))
            } catch is CancellationError {
                finishPDFTranslation(message: String(localized: "Translation cancelled.", bundle: bundle))
            } catch {
                finishPDFTranslation(message: AppLocalization.errorMessage(error, bundle: bundle))
            }
        }
    }

    private func beginPDFTranslation() {
        translationTask?.cancel()
        isTranslating = true
        translationProgress = nil
        pdfTranslationProgress = nil
        translationStatus = String(localized: "Translating PDF with BabelDOC...", bundle: bundle)
    }

    private func handlePDFProgress(_ progress: BabelDocProgressUpdate) {
        Task { @MainActor in
            guard isTranslating else { return }
            pdfTranslationProgress = progress
            translationStatus = progress.statusMessage
        }
    }

    private func finishPDFTranslation(message: String) {
        pdfTranslationProgress = nil
        translationStatus = message
        isTranslating = false
        translationTask = nil
    }

    private func dismissTranslationStatus() {
        guard !isTranslating else { return }
        translationStatus = nil
        translationProgress = nil
        pdfTranslationProgress = nil
    }

    private var nextPDFTranslationBatchLabel: String {
        guard let lastPage = translatedPDFAttachment?.translatedLastPage,
              let totalPages = originalPDFPageCount else {
            return String(localized: "Translate More PDF Pages", bundle: bundle)
        }
        let nextLastPage = min(lastPage + pdfTranslationBatchSize, totalPages)
        return AppLocalization.format(
            "Translate pages %@–%@",
            bundle: bundle,
            "\(lastPage + 1)",
            "\(nextLastPage)"
        )
    }

    private var shouldOfferTranslateAllPDFPages: Bool {
        guard let lastPage = translatedPDFAttachment?.translatedLastPage,
              let totalPages = originalPDFPageCount else { return false }
        return lastPage + pdfTranslationBatchSize < totalPages
    }

    private var translateMoreBanner: some View {
        let lastPage = translatedPDFAttachment?.translatedLastPage ?? 0
        let totalPages = originalPDFPageCount ?? 0

        return HStack(spacing: 8) {
            Text(AppLocalization.format(
                "Translated pages 1–%@ of %@.",
                bundle: bundle,
                "\(lastPage)",
                "\(totalPages)"
            ))
            .font(.caption)
            .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            Button {
                extendPDFTranslation()
            } label: {
                Text(nextPDFTranslationBatchLabel)
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            if shouldOfferTranslateAllPDFPages {
                Button {
                    extendPDFTranslation(to: totalPages)
                } label: {
                    Text("Translate All", bundle: bundle)
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(uiColor: .systemBackground))
    }

    private func restoreReadingState() {
        guard let paper else { return }
        let state = try? ReadingStateStore().state(for: paper.id, in: modelContext)
        pdfPageIndex = max(0, state?.pageIndex ?? 0)
        htmlScrollRatio = ReadingStateStore.clampedScrollRatio(state?.scrollRatio ?? 0)
        readerMode = ReadingStateStore.resolvedReaderMode(
            preferredMode: state?.readerMode,
            hasHTML: htmlAttachment != nil,
            hasPDF: pdfAttachment != nil,
            hasTranslatedPDF: translatedPDFAttachment != nil
        )
        syncTranslatedPageFromOriginal(pdfPageIndex)
        normalizeReaderMode()
        if readerMode != .html {
            lastPDFReaderMode = normalizedPDFReaderMode(readerMode)
        }
    }

    private func normalizedPDFReaderMode(_ mode: ReaderMode) -> ReaderMode {
        switch mode {
        case .html:
            return .pdf
        case .pdf, .bilingualPDF, .translatedPDF:
            return mode
        }
    }

    private func normalizeReaderMode() {
        if readerMode == .html, htmlAttachment != nil { return }
        if readerMode == .pdf, pdfAttachment != nil { return }
        if readerMode == .bilingualPDF, pdfAttachment != nil, translatedPDFAttachment != nil { return }
        if readerMode == .translatedPDF, translatedPDFAttachment != nil { return }
        readerMode = pdfAttachment != nil ? .pdf : .html
    }

    private func persistReadingState() {
        guard let paper else { return }
        let attachmentID: UUID? = switch readerMode {
        case .html: htmlAttachment?.id
        case .pdf, .bilingualPDF: pdfAttachment?.id
        case .translatedPDF: translatedPDFAttachment?.id
        }
        try? ReadingStateStore().upsertState(
            for: paper.id,
            attachmentID: attachmentID,
            readerMode: readerMode,
            pageIndex: pdfPageIndex,
            scrollRatio: htmlScrollRatio,
            in: modelContext
        )
    }

    private func revealNoteAnchor() {
        guard let request = noteNavigationRequest else { return }
        if request.attachmentID == htmlAttachment?.id || request.htmlSelector != nil {
            readerMode = .html
        } else if request.attachmentID == translatedPDFAttachment?.id {
            readerMode = .translatedPDF
            if let pageIndex = request.pageIndex {
                pdfPageIndex = max(0, pageIndex)
                syncTranslatedPageFromOriginal(pdfPageIndex)
            }
        } else if request.attachmentID == pdfAttachment?.id || request.pageIndex != nil {
            readerMode = translatedPDFAttachment == nil ? .pdf : .bilingualPDF
            if let pageIndex = request.pageIndex { pdfPageIndex = max(0, pageIndex) }
        }
    }
}
