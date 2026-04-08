import SwiftData
import SwiftUI

struct ReaderPaneView: View {
    @Environment(\.modelContext) private var modelContext

    var paper: Paper?
    var attachments: [PaperAttachment]
    var settings: AppSettings?
    @Binding var readerMode: ReaderMode
    @Binding var displayMode: TranslationDisplayMode

    @State private var pdfPageIndex = 0
    @State private var htmlReloadToken = 0
    @State private var isWorking = false
    @State private var isCancelling = false
    @State private var statusMessage: String?
    @State private var translationTask: Task<Void, Never>?

    private var pdfAttachment: PaperAttachment? {
        attachments.first { $0.kind == .pdf }
    }

    private var htmlAttachment: PaperAttachment? {
        attachments.first { $0.kind == .html }
    }

    private var translatedPDFAttachment: PaperAttachment? {
        attachments.first { $0.kind == .translatedPDF }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        if paper == nil {
            ContentUnavailableView(
                "Choose a paper",
                systemImage: "doc.text",
                description: Text("Your imported arXiv papers and PDFs appear here.")
            )
        } else {
            switch readerMode {
            case .html:
                HTMLReaderView(fileURL: htmlAttachment?.fileURL, displayMode: displayMode, reloadToken: htmlReloadToken)
            case .pdf:
                PDFReaderView(fileURL: pdfAttachment?.fileURL, pageIndex: $pdfPageIndex)
            case .bilingualPDF:
                DualPDFReaderView(
                    originalURL: pdfAttachment?.fileURL,
                    translatedURL: translatedPDFAttachment?.fileURL
                )
            }
        }
    }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Picker("Reader", selection: $readerMode) {
                    Text("HTML").tag(ReaderMode.html)
                    Text("PDF").tag(ReaderMode.pdf)
                    Text("Bilingual PDF").tag(ReaderMode.bilingualPDF)
                }
                .pickerStyle(.segmented)
                .frame(width: 320)

                Picker("Display", selection: $displayMode) {
                    Text("Original").tag(TranslationDisplayMode.original)
                    Text("Bilingual").tag(TranslationDisplayMode.bilingual)
                    Text("Translated").tag(TranslationDisplayMode.translated)
                }
                .pickerStyle(.segmented)
                .frame(width: 320)
                .disabled(readerMode != .html)

                Spacer()

                Button("Translate HTML") {
                    translateHTML()
                }
                .disabled(paper == nil || htmlAttachment == nil || settings == nil || isWorking)

                Button("Translate PDF") {
                    translatePDF()
                }
                .disabled(paper == nil || pdfAttachment == nil || settings == nil || isWorking)

                if isWorking {
                    Button(isCancelling ? "Cancelling..." : "Cancel") {
                        cancelTranslation()
                    }
                    .disabled(isCancelling)
                }
            }
            if isWorking || statusMessage != nil {
                statusRow
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            if isWorking {
                ProgressView()
                    .controlSize(.small)
            }
            Text(statusMessage ?? "Working...")
                .font(.caption)
                .foregroundStyle(statusMessage?.hasPrefix("Error") == true ? .red : .secondary)
                .lineLimit(1)
        }
    }

    private func translateHTML() {
        guard let paper, let htmlAttachment, let settings else { return }
        let settingsSnapshot = AppSettingsSnapshot(settings)
        isWorking = true
        isCancelling = false
        statusMessage = "Translating HTML..."
        translationTask = Task {
            do {
                try Task.checkCancellation()
                try await HTMLTranslationPipeline().translateHTML(
                    attachment: htmlAttachment,
                    paper: paper,
                    settings: settingsSnapshot,
                    modelContext: modelContext
                )
                try Task.checkCancellation()
                displayMode = .bilingual
                htmlReloadToken += 1
                statusMessage = "HTML translation completed."
            } catch is CancellationError {
                statusMessage = "Translation cancelled."
            } catch {
                statusMessage = "Error: \(error.localizedDescription)"
            }
            isWorking = false
            isCancelling = false
            translationTask = nil
        }
    }

    private func translatePDF() {
        guard let paper, let pdfAttachment, let settings else { return }
        let settingsSnapshot = AppSettingsSnapshot(settings)
        isWorking = true
        isCancelling = false
        statusMessage = "Running BabelDOC..."
        translationTask = Task {
            do {
                try Task.checkCancellation()
                let apiKey = try KeychainStore().load(account: KeychainStore.openAIAPIKeyAccount) ?? ""
                guard !apiKey.isEmpty else {
                    throw PaperImportError.missingAPIConfiguration
                }
                let toolManager = BabelDocToolManager()
                if try toolManager.detect() != .ready {
                    statusMessage = "Installing BabelDOC..."
                    let installResult = try await toolManager.installOrUpdateBabelDOC(version: settingsSnapshot.babelDocVersion)
                    try Task.checkCancellation()
                    guard installResult.exitCode == 0 else {
                        throw BabelDocRunError.failed(installResult.combinedOutput)
                    }
                }
                statusMessage = "Translating PDF with BabelDOC..."
                let outputDirectory = try PaperFileStore().translationsDirectory(for: paper)
                let translated = try await BabelDocRunner().translatePDF(
                    inputPDF: pdfAttachment.fileURL,
                    outputDirectory: outputDirectory,
                    settings: settingsSnapshot,
                    apiKey: apiKey,
                    babelDocExecutable: try toolManager.babelDocExecutableURL
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
                statusMessage = "PDF translation completed."
            } catch is CancellationError {
                statusMessage = "Translation cancelled."
            } catch {
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
}
