import PDFKit
import SwiftUI

struct DualPDFReaderView: View {
    @Environment(\.localizationBundle) private var bundle
    var originalURL: URL?
    var originalAttachmentID: UUID? = nil
    var translatedURL: URL?
    var translatedAttachmentID: UUID? = nil
    @Binding var pageIndex: Int
    var reloadToken: Int = 0
    var onNoteSelectionChanged: ((NoteSelectionContext?) -> Void)? = nil
    @State private var translatedPageIndex = 0
    @State private var translatedPageCount: Int = 0
    @State private var originalPageCount: Int = 0
    @State private var activeSelectionSource: SelectionSource?

    private enum SelectionSource {
        case original
        case translated
    }

    private var isPartialTranslation: Bool {
        guard translatedPageCount > 0, originalPageCount > 0 else { return false }
        return translatedPageCount < originalPageCount
    }

    var body: some View {
        HSplitView {
            PDFReaderView(
                fileURL: originalURL,
                attachmentID: originalAttachmentID,
                pageIndex: $pageIndex
            ) { selection in
                handleSelectionChange(selection, source: .original)
            }
                .overlay(alignment: .topLeading) {
                    readerLabel(String(localized: "Original", bundle: bundle))
                }
            PDFReaderView(
                fileURL: translatedURL,
                attachmentID: translatedAttachmentID,
                pageIndex: $translatedPageIndex,
                reloadToken: reloadToken
            ) { selection in
                handleSelectionChange(selection, source: .translated)
            }
                .overlay(alignment: .topLeading) {
                    if isPartialTranslation {
                        readerLabel(String(localized: "Translation (partial)", bundle: bundle))
                    } else {
                        readerLabel(String(localized: "Translation", bundle: bundle))
                    }
                }
        }
        .onAppear {
            translatedPageIndex = min(pageIndex, maxTranslatedPage)
            updatePageCounts()
        }
        .onChange(of: pageIndex) { _, newValue in
            let target = min(newValue, maxTranslatedPage)
            guard translatedPageIndex != target else { return }
            translatedPageIndex = target
        }
        .onChange(of: translatedPageIndex) { _, newValue in
            guard pageIndex != newValue else { return }
            if newValue <= maxTranslatedPage {
                pageIndex = newValue
            }
        }
        .onChange(of: reloadToken) { _, _ in
            updatePageCounts()
        }
        .onChange(of: originalURL) { _, _ in
            updateOriginalPageCount()
            activeSelectionSource = nil
            onNoteSelectionChanged?(nil)
        }
        .onChange(of: translatedURL) { _, _ in
            updateTranslatedPageCount()
            activeSelectionSource = nil
            onNoteSelectionChanged?(nil)
        }
        .onChange(of: translatedPageCount) { _, newCount in
            guard newCount > 0 else { return }
            let target = min(pageIndex, maxTranslatedPage)
            if translatedPageIndex != target {
                translatedPageIndex = target
            }
        }
    }

    private var maxTranslatedPage: Int {
        max(translatedPageCount - 1, 0)
    }

    private func updatePageCounts() {
        updateOriginalPageCount()
        updateTranslatedPageCount()
    }

    private func updateOriginalPageCount() {
        originalPageCount = originalURL.flatMap { PDFDocument(url: $0)?.pageCount } ?? 0
    }

    private func updateTranslatedPageCount() {
        translatedPageCount = translatedURL.flatMap { PDFDocument(url: $0)?.pageCount } ?? 0
    }

    private func readerLabel(_ value: String) -> some View {
        Text(value)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            .padding(8)
    }

    private func handleSelectionChange(_ selection: NoteSelectionContext?, source: SelectionSource) {
        if let selection {
            activeSelectionSource = source
            onNoteSelectionChanged?(selection)
            return
        }

        guard activeSelectionSource == source else { return }
        activeSelectionSource = nil
        onNoteSelectionChanged?(nil)
    }
}
