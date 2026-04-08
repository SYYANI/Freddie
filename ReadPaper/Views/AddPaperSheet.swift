import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct AddPaperSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Binding var isPresented: Bool
    @Binding var selectedPaperID: UUID?

    @State private var arxivInput = ""
    @State private var isImporting = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Add a paper")
                .font(.title2.weight(.semibold))

            VStack(alignment: .leading, spacing: 8) {
                Text("arXiv ID or URL")
                    .font(.headline)
                TextField("2303.08774 or https://arxiv.org/abs/2303.08774", text: $arxivInput)
                    .textFieldStyle(.roundedBorder)
                Button("Import from arXiv") {
                    importArxiv()
                }
                .disabled(arxivInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isImporting)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Local PDF")
                    .font(.headline)
                Button("Choose PDF...") {
                    importLocalPDF()
                }
                .disabled(isImporting)
            }

            if isImporting {
                ProgressView()
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            HStack {
                Spacer()
                Button("Close") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
    }

    private func importArxiv() {
        isImporting = true
        errorMessage = nil
        let input = arxivInput
        Task {
            do {
                let paper = try await PaperImporter().importArxiv(input, modelContext: modelContext)
                selectedPaperID = paper.id
                isPresented = false
            } catch {
                errorMessage = error.localizedDescription
            }
            isImporting = false
        }
    }

    private func importLocalPDF() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        isImporting = true
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
}
