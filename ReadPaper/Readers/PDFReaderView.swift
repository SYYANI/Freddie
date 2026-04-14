import PDFKit
import SwiftUI

struct PDFReaderView: NSViewRepresentable {
    var fileURL: URL?
    @Binding var pageIndex: Int
    var reloadToken: Int = 0

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.backgroundColor = .textBackgroundColor
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        guard let fileURL else {
            view.document = nil
            context.coordinator.loadedURL = nil
            context.coordinator.lastReloadToken = reloadToken
            context.coordinator.scheduleCurrentPageIndexUpdate()
            return
        }
        if context.coordinator.loadedURL != fileURL || context.coordinator.lastReloadToken != reloadToken {
            view.document = PDFDocument(url: fileURL)
            context.coordinator.loadedURL = fileURL
            context.coordinator.lastReloadToken = reloadToken
        }
        if let page = view.document?.page(at: pageIndex), view.currentPage != page {
            view.go(to: page)
        }
        context.coordinator.scheduleCurrentPageIndexUpdate()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(pageIndex: $pageIndex)
    }

    @MainActor
    final class Coordinator: NSObject {
        var loadedURL: URL?
        var lastReloadToken: Int = 0
        weak var pdfView: PDFView?
        var pageIndex: Binding<Int>
        private var isPageIndexUpdateScheduled = false

        init(pageIndex: Binding<Int>) {
            self.pageIndex = pageIndex
        }

        func attach(to pdfView: PDFView) {
            self.pdfView = pdfView
            NotificationCenter.default.removeObserver(
                self,
                name: Notification.Name.PDFViewPageChanged,
                object: pdfView
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handlePageChanged(_:)),
                name: Notification.Name.PDFViewPageChanged,
                object: pdfView
            )
        }

        func scheduleCurrentPageIndexUpdate() {
            guard !isPageIndexUpdateScheduled else { return }
            isPageIndexUpdateScheduled = true

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isPageIndexUpdateScheduled = false
                self.updateCurrentPageIndexIfNeeded()
            }
        }

        private func updateCurrentPageIndexIfNeeded() {
            guard let pdfView,
                  let document = pdfView.document,
                  let currentPage = pdfView.currentPage else {
                return
            }

            let currentIndex = document.index(for: currentPage)
            guard currentIndex != pageIndex.wrappedValue else { return }
            pageIndex.wrappedValue = currentIndex
        }

        @objc
        private func handlePageChanged(_ notification: Notification) {
            scheduleCurrentPageIndexUpdate()
        }
    }
}
