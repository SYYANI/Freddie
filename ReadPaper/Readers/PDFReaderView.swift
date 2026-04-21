import PDFKit
import SwiftUI

struct PDFReaderView: NSViewRepresentable {
    var fileURL: URL?
    var attachmentID: UUID? = nil
    @Binding var pageIndex: Int
    var reloadToken: Int = 0
    var onNoteSelectionChanged: ((NoteSelectionContext?) -> Void)? = nil

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
        context.coordinator.attachmentID = attachmentID
        context.coordinator.onNoteSelectionChanged = onNoteSelectionChanged

        guard let fileURL else {
            view.document = nil
            context.coordinator.loadedURL = nil
            context.coordinator.lastReloadToken = reloadToken
            context.coordinator.publishSelection(nil)
            context.coordinator.scheduleCurrentPageIndexUpdate()
            return
        }
        if context.coordinator.loadedURL != fileURL || context.coordinator.lastReloadToken != reloadToken {
            view.document = PDFDocument(url: fileURL)
            context.coordinator.loadedURL = fileURL
            context.coordinator.lastReloadToken = reloadToken
            context.coordinator.publishSelection(nil)
        }
        if let page = view.document?.page(at: pageIndex), view.currentPage != page {
            view.go(to: page)
        }
        context.coordinator.scheduleCurrentPageIndexUpdate()
        context.coordinator.scheduleSelectionUpdate()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            attachmentID: attachmentID,
            pageIndex: $pageIndex,
            onNoteSelectionChanged: onNoteSelectionChanged
        )
    }

    @MainActor
    final class Coordinator: NSObject {
        var loadedURL: URL?
        var lastReloadToken: Int = 0
        var attachmentID: UUID?
        weak var pdfView: PDFView?
        var pageIndex: Binding<Int>
        var onNoteSelectionChanged: ((NoteSelectionContext?) -> Void)?
        private var isPageIndexUpdateScheduled = false
        private var isSelectionUpdateScheduled = false
        private var lastPublishedSelection: NoteSelectionContext?

        init(
            attachmentID: UUID?,
            pageIndex: Binding<Int>,
            onNoteSelectionChanged: ((NoteSelectionContext?) -> Void)?
        ) {
            self.attachmentID = attachmentID
            self.pageIndex = pageIndex
            self.onNoteSelectionChanged = onNoteSelectionChanged
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
            NotificationCenter.default.removeObserver(
                self,
                name: Notification.Name.PDFViewSelectionChanged,
                object: pdfView
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleSelectionChanged(_:)),
                name: Notification.Name.PDFViewSelectionChanged,
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

        func scheduleSelectionUpdate() {
            guard !isSelectionUpdateScheduled else { return }
            isSelectionUpdateScheduled = true

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isSelectionUpdateScheduled = false
                self.publishSelection(self.currentSelectionContext())
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

        @objc
        private func handleSelectionChanged(_ notification: Notification) {
            scheduleSelectionUpdate()
        }

        func publishSelection(_ selection: NoteSelectionContext?) {
            guard lastPublishedSelection != selection else { return }
            lastPublishedSelection = selection
            onNoteSelectionChanged?(selection)
        }

        private func currentSelectionContext() -> NoteSelectionContext? {
            guard let pdfView,
                  let document = pdfView.document,
                  let selection = pdfView.currentSelection else {
                return nil
            }

            let quote = selection.string?
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ") ?? ""
            guard quote.isEmpty == false else { return nil }

            let page = selection.pages.first ?? pdfView.currentPage
            guard let page else { return nil }
            let pageIndex = document.index(for: page)
            guard pageIndex != NSNotFound else { return nil }

            return NoteSelectionContext(
                attachmentID: attachmentID,
                quote: quote,
                pageIndex: pageIndex
            )
        }
    }
}
