import PDFKit
import SwiftData
import SwiftUI
import UIKit

struct IPadReaderPaneView: View {
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
    @AppStorage(PDFDisplayAppearance.userDefaultsKey)
    private var appearanceRawValue = PDFDisplayAppearance.defaultValue.rawValue
    @AppStorage(HTMLReaderTypography.fontSizeUserDefaultsKey)
    private var htmlFontSize = HTMLReaderTypography.defaultFontSize
    @AppStorage(PDFTranslationBatchPreference.userDefaultsKey)
    private var pdfTranslationBatchSizeRawValue = PDFTranslationBatchPreference.defaultValue

    let paper: Paper?
    let attachments: [PaperAttachment]
    let settings: AppSettings?
    @Binding var noteSelectionContext: NoteSelectionContext?
    @Binding var noteNavigationRequest: NoteNavigationRequest?
    let onShowInspector: () -> Void

    @State private var readerMode: ReaderMode = .pdf
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

    private var pdfTranslationBatchSize: Int {
        PDFTranslationBatchPreference.normalized(pdfTranslationBatchSizeRawValue)
    }

    private var appearance: PDFDisplayAppearance {
        PDFDisplayAppearance.resolve(rawValue: appearanceRawValue)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let paper {
                readerHeader(paper)
                Divider()
                readerSurface
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
            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: copySourceLink) {
                    Label(String(localized: "Copy Link", bundle: bundle), systemImage: "link")
                }
                .disabled(sourceURL == nil)

                Button(action: onShowInspector) {
                    Label(String(localized: "Inspector", bundle: bundle), systemImage: "sidebar.right")
                }
            }
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
        .onChange(of: readerMode) { _, _ in persistReadingState() }
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

    private func readerHeader(_ paper: Paper) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(paper.title)
                        .font(.headline)
                        .lineLimit(2)
                    Text(paper.displayAuthors)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                modePicker
            }

            if readerMode == .html {
                HStack(spacing: 12) {
                    Picker(String(localized: "Display", bundle: bundle), selection: $displayMode) {
                        Text("Original", bundle: bundle).tag(TranslationDisplayMode.original)
                        Text("Bilingual", bundle: bundle).tag(TranslationDisplayMode.bilingual)
                        Text("Translated", bundle: bundle).tag(TranslationDisplayMode.translated)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 360)

                    Spacer()

                    if isTranslating {
                        Button(String(localized: "Cancel", bundle: bundle), role: .cancel) {
                            translationTask?.cancel()
                        }
                    } else {
                        Button {
                            translateHTML()
                        } label: {
                            Label(String(localized: "Translate HTML", bundle: bundle), systemImage: "character.book.closed")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(htmlAttachment == nil || settings == nil)
                    }
                }
            } else if pdfAttachment != nil {
                HStack(spacing: 12) {
                    Spacer()
                    if isTranslating {
                        Button(String(localized: "Cancel", bundle: bundle), role: .cancel) {
                            translationTask?.cancel()
                        }
                    } else {
                        Button {
                            translatePDF()
                        } label: {
                            Label(
                                isPartialPDFTranslation
                                    ? String(localized: "Translate More PDF Pages", bundle: bundle)
                                    : String(localized: "Translate PDF", bundle: bundle),
                                systemImage: "character.book.closed"
                            )
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(settings == nil || isFullPDFTranslationComplete)
                    }
                }
            }

            if let progress = pdfTranslationProgress, progress.total > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: progress.completed, total: progress.total)
                    Text(progress.summary)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
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
                Text(translationStatus)
                    .font(.caption)
                    .foregroundStyle(AppLocalization.isErrorMessage(translationStatus, bundle: bundle) ? .red : .secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var modePicker: some View {
        Picker(String(localized: "Reader", bundle: bundle), selection: $readerMode) {
            if htmlAttachment != nil {
                Text("HTML", bundle: bundle).tag(ReaderMode.html)
            }
            if pdfAttachment != nil {
                Text("Original", bundle: bundle).tag(ReaderMode.pdf)
            }
            if pdfAttachment != nil, translatedPDFAttachment != nil {
                Text("Bilingual", bundle: bundle).tag(ReaderMode.bilingualPDF)
            }
            if translatedPDFAttachment != nil {
                Text("Translated", bundle: bundle).tag(ReaderMode.translatedPDF)
            }
        }
        .pickerStyle(.segmented)
        .fixedSize()
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
                unavailable(String(localized: "HTML is not available for this paper.", bundle: bundle))
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
                unavailable(String(localized: "Translated PDF is not available for this paper.", bundle: bundle))
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
                unavailable(String(localized: "Translated PDF is not available for this paper.", bundle: bundle))
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
                let translated = try await InProcessBabelDocRunner().translatePDF(
                    inputPDF: pdfAttachment.fileURL,
                    outputDirectory: outputDirectory,
                    preferences: TranslationPreferencesSnapshot(settings),
                    route: resolvedRoute.snapshot,
                    apiKey: resolvedRoute.apiKey,
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

    private func extendPDFTranslation() {
        guard let paper, let pdfAttachment, let settings,
              let existingAttachment = translatedPDFAttachment,
              let currentLastPage = existingAttachment.translatedLastPage,
              let totalPages = originalPDFPageCount,
              currentLastPage < totalPages else { return }

        let nextLastPage = min(currentLastPage + pdfTranslationBatchSize, totalPages)
        let pageRange = (currentLastPage + 1)...nextLastPage
        beginPDFTranslation()
        translationTask = Task { @MainActor in
            do {
                let resolvedRoute = try LLMRouteResolver().resolvePDFRoute(
                    settings: settings,
                    modelContext: modelContext
                )
                let outputDirectory = try PaperFileStore().translationsDirectory(for: paper)
                let increment = try await InProcessBabelDocRunner().translatePDF(
                    inputPDF: pdfAttachment.fileURL,
                    outputDirectory: outputDirectory,
                    preferences: TranslationPreferencesSnapshot(settings),
                    route: resolvedRoute.snapshot,
                    apiKey: resolvedRoute.apiKey,
                    pageRange: pageRange,
                    onProgressUpdate: { progress in
                        Task { @MainActor in handlePDFProgress(progress) }
                    }
                )
                try Task.checkCancellation()
                let oldURL = existingAttachment.fileURL
                let mergedURL = outputDirectory.appendingPathComponent(
                    "merged-\(nextLastPage)-\(UUID().uuidString.prefix(8)).pdf"
                )
                _ = try PDFMerger.merge(existing: oldURL, increment: increment, output: mergedURL)
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
