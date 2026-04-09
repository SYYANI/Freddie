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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var content: some View {
        if paper == nil {
            emptyReaderState
        } else {
            switch readerMode {
            case .html:
                HTMLReaderView(fileURL: htmlAttachment?.fileURL, displayMode: displayMode, reloadToken: htmlReloadToken)
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
                        translatedURL: translatedPDFAttachment?.fileURL
                    )
                } else {
                    ContentUnavailableView(
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

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Picker("Reader", selection: $readerMode) {
                    Text("HTML").tag(ReaderMode.html)
                    Text("PDF").tag(ReaderMode.pdf)
                    Text("Bilingual PDF").tag(ReaderMode.bilingualPDF)
                    Text("Translated PDF").tag(ReaderMode.translatedPDF)
                }
                .pickerStyle(.segmented)
                .frame(width: 460)

                if readerMode == .html {
                    Picker("Display", selection: $displayMode) {
                        Text("Original").tag(TranslationDisplayMode.original)
                        Text("Bilingual").tag(TranslationDisplayMode.bilingual)
                        Text("Translated").tag(TranslationDisplayMode.translated)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 320)
                }

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
        .background(Color(nsColor: .windowBackgroundColor))
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
                    modelContext: modelContext,
                    onSegmentTranslated: { processed, total in
                        displayMode = .bilingual
                        htmlReloadToken += 1
                        statusMessage = "Translated HTML \(processed)/\(total)..."
                    }
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
                    babelDocExecutable: try toolManager.babelDocExecutableURL,
                    onStatusUpdate: { message in
                        Task { @MainActor in
                            guard isWorking, !isCancelling else { return }
                            statusMessage = message
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
            ContentUnavailableView(
                emptyTitle,
                systemImage: "doc.richtext",
                description: Text(emptyDescription)
            )
        }
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

                HStack(alignment: .top, spacing: 16) {
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
}
