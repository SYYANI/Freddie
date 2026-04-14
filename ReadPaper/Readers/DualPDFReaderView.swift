import PDFKit
import SwiftUI

struct DualPDFReaderView: View {
    @Environment(\.localizationBundle) private var bundle
    var originalURL: URL?
    var translatedURL: URL?
    @Binding var pageIndex: Int
    var reloadToken: Int = 0
    @State private var translatedPageIndex = 0
    @State private var translatedPageCount: Int = 0

    private var isPartialTranslation: Bool {
        guard translatedPageCount > 0,
              let originalDoc = originalURL.flatMap({ PDFDocument(url: $0) }) else { return false }
        return translatedPageCount < originalDoc.pageCount
    }

    var body: some View {
        HSplitView {
            PDFReaderView(fileURL: originalURL, pageIndex: $pageIndex)
                .overlay(alignment: .topLeading) {
                    readerLabel(String(localized: "Original", bundle: bundle))
                }
            PDFReaderView(fileURL: translatedURL, pageIndex: $translatedPageIndex, reloadToken: reloadToken)
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
            updateTranslatedPageCount()
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
            updateTranslatedPageCount()
        }
    }

    private var maxTranslatedPage: Int {
        max(translatedPageCount - 1, 0)
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
}
