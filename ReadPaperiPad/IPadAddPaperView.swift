import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct IPadAddPaperView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.localizationBundle) private var bundle
    @Binding var isPresented: Bool
    @Binding var selectedPaperID: UUID?

    @State private var arxivInput = ""
    @State private var webPageInput = ""
    @State private var isImporting = false
    @State private var isPickingPDF = false
    @State private var progressTitle: String?
    @State private var progressDetail: String?
    @State private var progressFraction = 0.0
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "arXiv ID or URL", bundle: bundle)) {
                    TextField(
                        String(localized: "2303.08774 or https://arxiv.org/abs/2303.08774", bundle: bundle),
                        text: $arxivInput
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    Button(String(localized: "Import from arXiv", bundle: bundle)) {
                        importArxiv()
                    }
                    .disabled(arxivInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isImporting)
                }

                Section(String(localized: "Web page URL", bundle: bundle)) {
                    TextField(
                        String(localized: "https://example.com/paper.html", bundle: bundle),
                        text: $webPageInput
                    )
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    Button(String(localized: "Import web page", bundle: bundle)) {
                        importWebPage()
                    }
                    .disabled(webPageInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isImporting)
                }

                Section(String(localized: "Local PDF", bundle: bundle)) {
                    Button(String(localized: "Choose PDF...", bundle: bundle)) {
                        isPickingPDF = true
                    }
                    .disabled(isImporting)
                }

                if isImporting {
                    Section {
                        ProgressView(value: progressFraction)
                        if let progressTitle {
                            Text(progressTitle).font(.headline)
                        }
                        if let progressDetail {
                            Text(progressDetail).foregroundStyle(.secondary)
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(String(localized: "Add a paper", bundle: bundle))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Close", bundle: bundle)) { isPresented = false }
                        .disabled(isImporting)
                }
            }
        }
        .fileImporter(
            isPresented: $isPickingPDF,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { importLocalPDF(url) }
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
    }

    private func importArxiv() {
        beginImport()
        Task {
            do {
                let paper = try await PaperImporter().importArxiv(arxivInput, modelContext: modelContext) { progress in
                    progressTitle = progress.title
                    progressDetail = progress.detail
                    progressFraction = progress.fractionCompleted
                }
                finishImport(with: paper)
            } catch { failImport(error) }
        }
    }

    private func importWebPage() {
        beginImport()
        Task {
            do {
                let paper = try await PaperImporter().importWebPage(webPageInput, modelContext: modelContext) { progress in
                    progressTitle = progress.title
                    progressDetail = progress.detail
                    progressFraction = progress.fractionCompleted
                }
                finishImport(with: paper)
            } catch { failImport(error) }
        }
    }

    private func importLocalPDF(_ url: URL) {
        beginImport()
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        do {
            finishImport(with: try PaperImporter().importLocalPDF(url, modelContext: modelContext))
        } catch {
            failImport(error)
        }
    }

    private func beginImport() {
        isImporting = true
        errorMessage = nil
        progressFraction = 0
        progressTitle = String(localized: "Preparing import...", bundle: bundle)
        progressDetail = nil
    }

    private func finishImport(with paper: Paper) {
        selectedPaperID = paper.id
        isImporting = false
        isPresented = false
    }

    private func failImport(_ error: Error) {
        errorMessage = AppLocalization.errorMessage(error, bundle: bundle)
        isImporting = false
    }
}
