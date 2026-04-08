import PDFKit
import SwiftUI

struct PDFReaderView: NSViewRepresentable {
    var fileURL: URL?
    @Binding var pageIndex: Int

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.backgroundColor = .textBackgroundColor
        context.coordinator.pdfView = view
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        guard let fileURL else {
            view.document = nil
            context.coordinator.loadedURL = nil
            return
        }
        if context.coordinator.loadedURL != fileURL {
            view.document = PDFDocument(url: fileURL)
            context.coordinator.loadedURL = fileURL
        }
        if let page = view.document?.page(at: pageIndex), view.currentPage != page {
            view.go(to: page)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(pageIndex: $pageIndex)
    }

    final class Coordinator: NSObject {
        var loadedURL: URL?
        weak var pdfView: PDFView?
        var pageIndex: Binding<Int>

        init(pageIndex: Binding<Int>) {
            self.pageIndex = pageIndex
        }
    }
}
