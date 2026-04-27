import PDFKit
import SwiftUI

enum PDFDisplayAppearance: String, CaseIterable, Identifiable {
    case defaultMode = "default"
    case dark
    case paper

    static let userDefaultsKey = "ReadPaper.Reader.PDFDisplayAppearance"
    static let defaultValue: Self = .defaultMode

    var id: String { rawValue }

    static func resolve(rawValue: String) -> Self {
        Self(rawValue: rawValue) ?? defaultValue
    }
}

extension PDFDisplayAppearance {
    var pdfBackgroundColor: NSColor {
        switch self {
        case .defaultMode:
            return .textBackgroundColor
        case .dark:
            // Keep the PDFView background light so the difference blend can invert
            // both the page and the surrounding canvas into a dark reading surface.
            return NSColor(calibratedWhite: 0.96, alpha: 1)
        case .paper:
            return NSColor(calibratedRed: 0.96, green: 0.93, blue: 0.86, alpha: 1)
        }
    }

    var surfaceColor: Color {
        Color(nsColor: pdfBackgroundColor)
    }
}

struct PDFDisplaySurface<Content: View>: View {
    var appearance: PDFDisplayAppearance
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .background(appearance.surfaceColor)
            .compositingGroup()
            .overlay {
                overlay
            }
    }

    @ViewBuilder
    private var overlay: some View {
        switch appearance {
        case .defaultMode:
            EmptyView()
        case .dark:
            Rectangle()
                .fill(Color.white)
                .blendMode(.difference)
                .allowsHitTesting(false)
        case .paper:
            LinearGradient(
                colors: [
                    Color(red: 0.99, green: 0.97, blue: 0.91),
                    Color(red: 0.92, green: 0.88, blue: 0.77)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .blendMode(.multiply)
            .opacity(0.38)
            .allowsHitTesting(false)
        }
    }
}

struct PDFReadingPosition: Equatable {
    var pageIndex: Int
    var point: CGPoint?

    var normalized: Self {
        Self(pageIndex: max(0, pageIndex), point: point)
    }

    func clamped(pageCount: Int) -> Self {
        Self(
            pageIndex: min(max(0, pageIndex), max(pageCount - 1, 0)),
            point: point
        )
    }
}

struct PDFReaderView: NSViewRepresentable {
    var fileURL: URL?
    var attachmentID: UUID? = nil
    var displayAppearance: PDFDisplayAppearance = .defaultMode
    @Binding var pageIndex: Int
    var reloadToken: Int = 0
    var onNoteSelectionChanged: ((NoteSelectionContext?) -> Void)? = nil

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        applyDisplayAppearance(displayAppearance, to: view)
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        applyDisplayAppearance(displayAppearance, to: view)
        context.coordinator.attachmentID = attachmentID
        context.coordinator.onNoteSelectionChanged = onNoteSelectionChanged

        guard let fileURL else {
            view.document = nil
            context.coordinator.loadedURL = nil
            context.coordinator.lastReloadToken = reloadToken
            context.coordinator.clearProgrammaticPageRestore()
            context.coordinator.publishSelection(nil)
            context.coordinator.scheduleCurrentPageIndexUpdate()
            return
        }
        let shouldReloadDocument = context.coordinator.loadedURL != fileURL || context.coordinator.lastReloadToken != reloadToken
        let restorePosition = context.coordinator.readingPosition(
            fallbackPageIndex: pageIndex,
            in: view
        )
        if shouldReloadDocument {
            context.coordinator.prepareForProgrammaticPageRestore(to: restorePosition)
            view.document = PDFDocument(url: fileURL)
            context.coordinator.loadedURL = fileURL
            context.coordinator.lastReloadToken = reloadToken
            context.coordinator.publishSelection(nil)
        }
        context.coordinator.restoreReadingPosition(
            shouldReloadDocument ? restorePosition : PDFReadingPosition(pageIndex: pageIndex),
            in: view,
            suppressIntermediateUpdates: shouldReloadDocument
        )
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

    private func applyDisplayAppearance(_ appearance: PDFDisplayAppearance, to view: PDFView) {
        view.backgroundColor = appearance.pdfBackgroundColor
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
        private var pendingProgrammaticPosition: PDFReadingPosition?

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

        func readingPosition(fallbackPageIndex: Int, in pdfView: PDFView) -> PDFReadingPosition {
            if let document = pdfView.document,
               let destination = pdfView.currentDestination,
               let page = destination.page {
                let currentIndex = document.index(for: page)
                if currentIndex != NSNotFound {
                    return PDFReadingPosition(pageIndex: currentIndex, point: destination.point)
                }
            }

            return PDFReadingPosition(pageIndex: fallbackPageIndex)
        }

        func prepareForProgrammaticPageRestore(to position: PDFReadingPosition) {
            pendingProgrammaticPosition = position.normalized
        }

        func clearProgrammaticPageRestore() {
            pendingProgrammaticPosition = nil
        }

        func restoreReadingPosition(
            _ requestedPosition: PDFReadingPosition,
            in pdfView: PDFView,
            suppressIntermediateUpdates: Bool
        ) {
            guard let document = pdfView.document, document.pageCount > 0 else {
                clearProgrammaticPageRestore()
                return
            }

            let targetPosition = requestedPosition.clamped(pageCount: document.pageCount)
            let targetIndex = targetPosition.pageIndex
            guard let page = document.page(at: targetIndex) else {
                clearProgrammaticPageRestore()
                return
            }

            if suppressIntermediateUpdates || pdfView.currentPage != page {
                pendingProgrammaticPosition = targetPosition
            }

            if let point = targetPosition.point {
                pdfView.go(to: PDFDestination(page: page, at: point))
            } else if pdfView.currentPage != page {
                pdfView.go(to: page)
            }

            guard suppressIntermediateUpdates else { return }
            Task { @MainActor [weak self, weak pdfView] in
                guard let self, let pdfView else { return }
                self.restoreDeferredReadingPosition(targetPosition, in: pdfView)
            }
        }

        private func restoreDeferredReadingPosition(_ position: PDFReadingPosition, in pdfView: PDFView) {
            guard pendingProgrammaticPosition?.pageIndex == position.pageIndex,
                  let document = pdfView.document,
                  document.pageCount > 0
            else {
                return
            }

            let targetPosition = position.clamped(pageCount: document.pageCount)
            guard let page = document.page(at: targetPosition.pageIndex) else { return }

            if let point = targetPosition.point {
                pdfView.go(to: PDFDestination(page: page, at: point))
            } else if pdfView.currentPage != page {
                pdfView.go(to: page)
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

        func updateCurrentPageIndexIfNeeded() {
            guard let pdfView,
                  let document = pdfView.document,
                  let currentPage = pdfView.currentPage else {
                return
            }

            let currentIndex = document.index(for: currentPage)
            guard currentIndex != NSNotFound else { return }

            if let pendingProgrammaticPosition {
                guard currentIndex == pendingProgrammaticPosition.pageIndex else { return }
                self.pendingProgrammaticPosition = nil
            }

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
