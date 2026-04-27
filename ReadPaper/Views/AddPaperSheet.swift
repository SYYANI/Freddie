import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct AddPaperSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.localizationBundle) private var bundle
    @Binding var isPresented: Bool
    @Binding var selectedPaperID: UUID?

    @State private var arxivInput = ""
    @State private var webPageInput = ""
    @State private var isImporting = false
    @State private var arxivImportProgress: ArxivImportProgress?
    @State private var webPageImportProgress: WebPageImportProgress?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Add a paper", bundle: bundle)
                .font(.title2.weight(.semibold))

            VStack(alignment: .leading, spacing: 8) {
                Text("arXiv ID or URL", bundle: bundle)
                    .font(.headline)
                TextField(
                    String(localized: "2303.08774 or https://arxiv.org/abs/2303.08774", bundle: bundle),
                    text: $arxivInput
                )
                    .textFieldStyle(.roundedBorder)
                Button(String(localized: "Import from arXiv", bundle: bundle)) {
                    importArxiv()
                }
                .disabled(arxivInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isImporting)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Web page URL", bundle: bundle)
                    .font(.headline)
                TextField(
                    String(localized: "https://example.com/paper.html", bundle: bundle),
                    text: $webPageInput
                )
                    .textFieldStyle(.roundedBorder)
                Button(String(localized: "Import web page", bundle: bundle)) {
                    importWebPage()
                }
                .disabled(webPageInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isImporting)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Local PDF", bundle: bundle)
                    .font(.headline)
                Button(String(localized: "Choose PDF...", bundle: bundle)) {
                    importLocalPDF()
                }
                .disabled(isImporting)
            }

            if isImporting {
                if let arxivImportProgress {
                    importProgressView(arxivImportProgress)
                } else if let webPageImportProgress {
                    importProgressView(webPageImportProgress)
                } else {
                    ProgressView()
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            HStack {
                Spacer()
                Button(String(localized: "Close", bundle: bundle)) {
                    isPresented = false
                }
                .disabled(isImporting)
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
    }

    private func importArxiv() {
        isImporting = true
        arxivImportProgress = .resolvingInput()
        webPageImportProgress = nil
        errorMessage = nil
        let input = arxivInput
        Task {
            do {
                let paper = try await PaperImporter().importArxiv(
                    input,
                    modelContext: modelContext
                ) { progress in
                    arxivImportProgress = progress
                }
                selectedPaperID = paper.id
                isPresented = false
            } catch {
                errorMessage = error.localizedDescription
            }
            isImporting = false
            arxivImportProgress = nil
        }
    }

    private func importWebPage() {
        isImporting = true
        arxivImportProgress = nil
        webPageImportProgress = .validatingURL()
        errorMessage = nil
        let input = webPageInput
        Task {
            do {
                let paper = try await PaperImporter().importWebPage(
                    input,
                    modelContext: modelContext
                ) { progress in
                    webPageImportProgress = progress
                }
                selectedPaperID = paper.id
                isPresented = false
            } catch {
                errorMessage = error.localizedDescription
            }
            isImporting = false
            webPageImportProgress = nil
        }
    }

    private func importLocalPDF() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose PDF...", bundle: bundle)
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        isImporting = true
        arxivImportProgress = nil
        webPageImportProgress = nil
        errorMessage = nil
        do {
            let paper = try PaperImporter().importLocalPDF(url, modelContext: modelContext)
            selectedPaperID = paper.id
            isPresented = false
        } catch {
            errorMessage = error.localizedDescription
        }
        isImporting = false
    }

    private func importProgressView(_ progress: ArxivImportProgress) -> some View {
        importProgressView(
            stepLabel: progress.stepLabel,
            fractionCompleted: progress.fractionCompleted,
            title: progress.title,
            detail: progress.detail
        )
    }

    private func importProgressView(_ progress: WebPageImportProgress) -> some View {
        importProgressView(
            stepLabel: progress.stepLabel,
            fractionCompleted: progress.fractionCompleted,
            title: progress.title,
            detail: progress.detail
        )
    }

    private func importProgressView(
        stepLabel: String,
        fractionCompleted: Double,
        title: String,
        detail: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(stepLabel)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(round(fractionCompleted * 100)))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: fractionCompleted)
                .progressViewStyle(.linear)

            Text(title)
                .font(.subheadline.weight(.semibold))

            if let detail {
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
    }
}
