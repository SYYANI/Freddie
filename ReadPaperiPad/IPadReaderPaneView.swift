import PDFKit
import SwiftData
import SwiftUI
import UIKit

struct IPadReaderPaneView: View {
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

    let paper: Paper?
    let attachments: [PaperAttachment]
    let settings: AppSettings?
    @Binding var noteSelectionContext: NoteSelectionContext?
    @Binding var noteNavigationRequest: NoteNavigationRequest?
    let onShowInspector: () -> Void

    @State private var readerMode: ReaderMode = .pdf
    @State private var displayMode: TranslationDisplayMode = .bilingual
    @State private var pdfPageIndex = 0
    @State private var htmlScrollRatio = 0.0
    @State private var htmlReloadToken = 0
    @State private var htmlSegmentUpdate: HTMLTranslationSegmentUpdate?
    @State private var translationProgress: TranslationProgressState?
    @State private var translationStatus: String?
    @State private var translationTask: Task<Void, Never>?
    @State private var isTranslating = false

    private var pdfAttachment: PaperAttachment? {
        attachments.first { $0.kind == .pdf }
    }

    private var htmlAttachment: PaperAttachment? {
        attachments.first { $0.kind == .html }
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
        .onChange(of: attachments.map { "\($0.id)-\($0.kindRawValue)" }) { _, _ in
            normalizeReaderMode()
        }
        .onChange(of: readerMode) { _, _ in persistReadingState() }
        .onChange(of: pdfPageIndex) { _, _ in persistReadingState() }
        .onChange(of: htmlScrollRatio) { _, _ in persistReadingState() }
        .onChange(of: noteNavigationRequest?.id) { _, _ in revealNoteAnchor() }
        .onDisappear {
            persistReadingState()
            translationTask?.cancel()
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
            }

            if let progress = translationProgress, progress.total > 0 {
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
                Text("PDF", bundle: bundle).tag(ReaderMode.pdf)
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
        case .pdf, .bilingualPDF, .translatedPDF:
            if let pdfAttachment {
                PDFDisplaySurface(appearance: appearance) {
                    PDFReaderView(
                        fileURL: pdfAttachment.fileURL,
                        attachmentID: pdfAttachment.id,
                        displayAppearance: appearance,
                        pageIndex: $pdfPageIndex,
                        onNoteSelectionChanged: { noteSelectionContext = $0 }
                    )
                }
            } else {
                unavailable(String(localized: "PDF is not available for this paper.", bundle: bundle))
            }
        }
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

    private func restoreReadingState() {
        guard let paper else { return }
        let state = try? ReadingStateStore().state(for: paper.id, in: modelContext)
        pdfPageIndex = max(0, state?.pageIndex ?? 0)
        htmlScrollRatio = ReadingStateStore.clampedScrollRatio(state?.scrollRatio ?? 0)
        readerMode = ReadingStateStore.resolvedReaderMode(
            preferredMode: state?.readerMode,
            hasHTML: htmlAttachment != nil,
            hasPDF: pdfAttachment != nil,
            hasTranslatedPDF: false
        )
        normalizeReaderMode()
    }

    private func normalizeReaderMode() {
        if readerMode == .html, htmlAttachment != nil { return }
        if readerMode == .pdf, pdfAttachment != nil { return }
        readerMode = pdfAttachment != nil ? .pdf : .html
    }

    private func persistReadingState() {
        guard let paper else { return }
        let attachmentID = readerMode == .html ? htmlAttachment?.id : pdfAttachment?.id
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
        } else if request.attachmentID == pdfAttachment?.id || request.pageIndex != nil {
            readerMode = .pdf
            if let pageIndex = request.pageIndex { pdfPageIndex = max(0, pageIndex) }
        }
    }
}
