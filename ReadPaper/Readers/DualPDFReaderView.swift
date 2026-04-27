import PDFKit
import SwiftUI

struct DualPDFReaderView: View {
    @Environment(\.localizationBundle) private var bundle
    var originalURL: URL?
    var originalAttachmentID: UUID? = nil
    var translatedURL: URL?
    var translatedAttachmentID: UUID? = nil
    var displayAppearance: PDFDisplayAppearance = .defaultMode
    @Binding var pageIndex: Int
    var reloadToken: Int = 0
    var onNoteSelectionChanged: ((NoteSelectionContext?) -> Void)? = nil
    @State private var translatedPageIndex = 0
    @State private var translatedPageCount: Int = 0
    @State private var originalPageCount: Int = 0
    @State private var activeSelectionSource: SelectionSource?
    @State private var pendingProgrammaticTranslatedPageTargets: Set<Int> = []

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
            themedPDFReader(
                fileURL: originalURL,
                attachmentID: originalAttachmentID,
                pageIndex: $pageIndex
            ) { selection in
                handleSelectionChange(selection, source: .original)
            }
                .overlay(alignment: .topLeading) {
                    readerLabel(String(localized: "Original", bundle: bundle))
                }
            themedPDFReader(
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
            updatePageCounts()
            syncTranslatedPageFromOriginal(pageIndex)
        }
        .onChange(of: pageIndex) { _, newValue in
            syncTranslatedPageFromOriginal(newValue)
        }
        .onChange(of: translatedPageIndex) { _, newValue in
            let target = DualPDFPageIndexSync.originalPageIndex(
                forTranslatedPageIndex: newValue,
                translatedPageCount: translatedPageCount,
                pendingProgrammaticTargets: &pendingProgrammaticTranslatedPageTargets
            )
            guard let target, pageIndex != target else { return }
            pageIndex = target
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
            syncTranslatedPageFromOriginal(pageIndex)
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

    private func syncTranslatedPageFromOriginal(_ originalPageIndex: Int) {
        guard translatedPageCount > 0 else { return }
        let target = DualPDFPageIndexSync.translatedPageIndex(
            forOriginalPageIndex: originalPageIndex,
            translatedPageCount: translatedPageCount
        )
        guard translatedPageIndex != target else { return }
        pendingProgrammaticTranslatedPageTargets.insert(target)
        translatedPageIndex = target
    }

    private func themedPDFReader(
        fileURL: URL?,
        attachmentID: UUID?,
        pageIndex: Binding<Int>,
        reloadToken: Int = 0,
        onSelectionChanged: @escaping (NoteSelectionContext?) -> Void
    ) -> some View {
        PDFDisplaySurface(appearance: displayAppearance) {
            PDFReaderView(
                fileURL: fileURL,
                attachmentID: attachmentID,
                displayAppearance: displayAppearance,
                pageIndex: pageIndex,
                reloadToken: reloadToken,
                onNoteSelectionChanged: onSelectionChanged
            )
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

struct DualPDFPageIndexSync {
    static func translatedPageIndex(
        forOriginalPageIndex originalPageIndex: Int,
        translatedPageCount: Int
    ) -> Int {
        min(max(0, originalPageIndex), maxTranslatedPage(translatedPageCount))
    }

    static func originalPageIndex(
        forTranslatedPageIndex translatedPageIndex: Int,
        translatedPageCount: Int,
        pendingProgrammaticTargets: inout Set<Int>
    ) -> Int? {
        guard translatedPageCount > 0 else {
            pendingProgrammaticTargets.removeAll()
            return nil
        }

        if pendingProgrammaticTargets.remove(translatedPageIndex) != nil {
            return nil
        }

        if !pendingProgrammaticTargets.isEmpty {
            pendingProgrammaticTargets.removeAll()
        }

        guard translatedPageIndex <= maxTranslatedPage(translatedPageCount) else {
            return nil
        }

        return max(0, translatedPageIndex)
    }

    private static func maxTranslatedPage(_ translatedPageCount: Int) -> Int {
        max(translatedPageCount - 1, 0)
    }
}
