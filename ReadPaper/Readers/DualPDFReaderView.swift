import SwiftUI

struct DualPDFReaderView: View {
    var originalURL: URL?
    var translatedURL: URL?
    @State private var originalPageIndex = 0
    @State private var translatedPageIndex = 0

    var body: some View {
        HSplitView {
            PDFReaderView(fileURL: originalURL, pageIndex: $originalPageIndex)
                .overlay(alignment: .topLeading) {
                    readerLabel("Original")
                }
            PDFReaderView(fileURL: translatedURL, pageIndex: $translatedPageIndex)
                .overlay(alignment: .topLeading) {
                    readerLabel("Translation")
                }
        }
        .onChange(of: originalPageIndex) { _, newValue in
            translatedPageIndex = newValue
        }
        .onChange(of: translatedPageIndex) { _, newValue in
            originalPageIndex = newValue
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
