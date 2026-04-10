import SwiftUI

struct DualPDFReaderView: View {
    var originalURL: URL?
    var translatedURL: URL?
    @Binding var pageIndex: Int
    @State private var translatedPageIndex = 0

    var body: some View {
        HSplitView {
            PDFReaderView(fileURL: originalURL, pageIndex: $pageIndex)
                .overlay(alignment: .topLeading) {
                    readerLabel("Original")
                }
            PDFReaderView(fileURL: translatedURL, pageIndex: $translatedPageIndex)
                .overlay(alignment: .topLeading) {
                    readerLabel("Translation")
                }
        }
        .onAppear {
            translatedPageIndex = pageIndex
        }
        .onChange(of: pageIndex) { _, newValue in
            guard translatedPageIndex != newValue else { return }
            translatedPageIndex = newValue
        }
        .onChange(of: translatedPageIndex) { _, newValue in
            guard pageIndex != newValue else { return }
            pageIndex = newValue
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
