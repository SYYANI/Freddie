import AppKit
import PDFKit
import SwiftUI

enum DualPDFSelectionSource: Equatable {
    case original
    case translated
}

struct DualPDFSelectionOwnership: Equatable {
    private(set) var activeSource: DualPDFSelectionSource?

    mutating func activate(_ source: DualPDFSelectionSource) -> DualPDFSelectionSource? {
        let sourceToClear = activeSource != source ? activeSource : nil
        activeSource = source
        return sourceToClear
    }

    mutating func clear(_ source: DualPDFSelectionSource) -> Bool {
        guard activeSource == source else { return false }
        activeSource = nil
        return true
    }

    mutating func reset() {
        activeSource = nil
    }
}

struct DualPDFReaderView: View {
    @Environment(\.localizationBundle) private var bundle
    var paperID: UUID? = nil
    var originalURL: URL?
    var originalAttachmentID: UUID? = nil
    var translatedURL: URL?
    var translatedAttachmentID: UUID? = nil
    var translatedLastPage: Int? = nil
    var displayAppearance: PDFDisplayAppearance = .defaultMode
    @Binding var pageIndex: Int
    var reloadToken: Int = 0
    var annotationSession: PDFAnnotationSession? = nil
    var debugRegionSelectionEnabled = false
    var onDebugRegionSelected: ((PDFDebugRegionSelection) -> Void)? = nil
    var onNoteSelectionChanged: ((NoteSelectionContext?) -> Void)? = nil
    var onArxivLinkActivated: ((URL) -> Void)? = nil
    @State private var translatedPageIndex = 0
    @State private var translatedPageCount: Int = 0
    @State private var originalPageCount: Int = 0
    @State private var selectionOwnership = DualPDFSelectionOwnership()
    @State private var originalSelectionResetToken = 0
    @State private var translatedSelectionResetToken = 0
    @State private var pendingProgrammaticTranslatedPageTargets: Set<Int> = []

    private var isPartialTranslation: Bool {
        PDFTranslationCoverage.isPartial(
            translatedLastPage: translatedLastPage,
            originalPageCount: originalPageCount
        )
    }

    var body: some View {
        StableHorizontalPDFSplitView {
            originalReader
        } trailing: {
            translatedReader
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
            selectionOwnership.reset()
            onNoteSelectionChanged?(nil)
        }
        .onChange(of: translatedURL) { _, _ in
            updateTranslatedPageCount()
            selectionOwnership.reset()
            onNoteSelectionChanged?(nil)
        }
        .onChange(of: translatedPageCount) { _, newCount in
            guard newCount > 0 else { return }
            syncTranslatedPageFromOriginal(pageIndex)
        }
    }

    private var originalReader: some View {
        themedPDFReader(
            fileURL: originalURL,
            attachmentID: originalAttachmentID,
            pageIndex: $pageIndex,
            selectionResetToken: originalSelectionResetToken,
            debugRegionSelectionEnabled: false
        ) { selection in
            handleSelectionChange(selection, source: .original)
        }
        .overlay(alignment: .topLeading) {
            readerLabel(String(localized: "Original", bundle: bundle))
        }
    }

    private var translatedReader: some View {
        themedPDFReader(
            fileURL: translatedURL,
            attachmentID: translatedAttachmentID,
            pageIndex: $translatedPageIndex,
            reloadToken: reloadToken,
            selectionResetToken: translatedSelectionResetToken,
            debugRegionSelectionEnabled: debugRegionSelectionEnabled
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
        selectionResetToken: Int,
        debugRegionSelectionEnabled: Bool,
        onSelectionChanged: @escaping (NoteSelectionContext?) -> Void
    ) -> some View {
        PDFDisplaySurface(appearance: displayAppearance) {
            PDFReaderView(
                fileURL: fileURL,
                paperID: paperID,
                attachmentID: attachmentID,
                displayAppearance: displayAppearance,
                pageIndex: pageIndex,
                reloadToken: reloadToken,
                selectionResetToken: selectionResetToken,
                annotationSession: annotationSession,
                onNoteSelectionChanged: onSelectionChanged,
                onArxivLinkActivated: onArxivLinkActivated,
                debugRegionSelectionEnabled: debugRegionSelectionEnabled,
                onDebugRegionSelected: onDebugRegionSelected
            )
        }
    }

    private func readerLabel(_ value: String) -> some View {
        Text(value)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .readPaperGlassEffect(in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .padding(8)
    }

    private func handleSelectionChange(
        _ selection: NoteSelectionContext?,
        source: DualPDFSelectionSource
    ) {
        if let selection {
            if let sourceToClear = selectionOwnership.activate(source) {
                switch sourceToClear {
                case .original:
                    originalSelectionResetToken &+= 1
                case .translated:
                    translatedSelectionResetToken &+= 1
                }
            }
            onNoteSelectionChanged?(selection)
            return
        }

        guard selectionOwnership.clear(source) else { return }
        onNoteSelectionChanged?(nil)
    }
}

struct DualPDFSplitLayout {
    static let dividerWidth: CGFloat = 8
    static let minimumPaneWidth: CGFloat = 180

    static func leadingWidth(totalWidth: CGFloat, fraction: CGFloat) -> CGFloat {
        let availableWidth = max(0, totalWidth - dividerWidth)
        guard availableWidth > 0 else { return 0 }
        return availableWidth * clampedFraction(fraction, availableWidth: availableWidth)
    }

    static func fraction(
        afterDraggingBy delta: CGFloat,
        totalWidth: CGFloat,
        currentFraction: CGFloat
    ) -> CGFloat {
        let availableWidth = max(0, totalWidth - dividerWidth)
        guard availableWidth > 0 else { return 0.5 }
        let currentWidth = leadingWidth(totalWidth: totalWidth, fraction: currentFraction)
        return clampedFraction(
            (currentWidth + delta) / availableWidth,
            availableWidth: availableWidth
        )
    }

    private static func clampedFraction(_ fraction: CGFloat, availableWidth: CGFloat) -> CGFloat {
        let minimumWidth = min(minimumPaneWidth, availableWidth / 2)
        let minimumFraction = minimumWidth / availableWidth
        return min(max(fraction, minimumFraction), 1 - minimumFraction)
    }
}

private struct StableHorizontalPDFSplitView<Leading: View, Trailing: View>: View {
    @State private var leadingFraction: CGFloat = 0.5
    private let leading: Leading
    private let trailing: Trailing

    init(
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        GeometryReader { proxy in
            let totalWidth = proxy.size.width
            let leadingWidth = DualPDFSplitLayout.leadingWidth(
                totalWidth: totalWidth,
                fraction: leadingFraction
            )

            HStack(spacing: 0) {
                leading
                    .frame(width: leadingWidth)

                StablePDFSplitDivider { delta in
                    leadingFraction = DualPDFSplitLayout.fraction(
                        afterDraggingBy: delta,
                        totalWidth: totalWidth,
                        currentFraction: leadingFraction
                    )
                }
                .frame(width: DualPDFSplitLayout.dividerWidth)

                trailing
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

private struct StablePDFSplitDivider: NSViewRepresentable {
    var onDrag: (CGFloat) -> Void

    func makeNSView(context: Context) -> DividerView {
        let view = DividerView()
        view.onDrag = onDrag
        return view
    }

    func updateNSView(_ nsView: DividerView, context: Context) {
        nsView.onDrag = onDrag
    }

    final class DividerView: NSView {
        var onDrag: ((CGFloat) -> Void)?
        private var lastDragLocationX: CGFloat?

        override var acceptsFirstResponder: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            NSColor.separatorColor.setFill()
            NSRect(x: bounds.midX - 0.5, y: bounds.minY, width: 1, height: bounds.height).fill()
        }

        override func resetCursorRects() {
            super.resetCursorRects()
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }

        override func cursorUpdate(with event: NSEvent) {
            NSCursor.resizeLeftRight.set()
        }

        override func mouseEntered(with event: NSEvent) {
            NSCursor.resizeLeftRight.set()
        }

        override func mouseDown(with event: NSEvent) {
            lastDragLocationX = event.locationInWindow.x
            NSCursor.resizeLeftRight.set()
        }

        override func mouseDragged(with event: NSEvent) {
            let locationX = event.locationInWindow.x
            if let lastDragLocationX {
                onDrag?(locationX - lastDragLocationX)
            }
            self.lastDragLocationX = locationX
            NSCursor.resizeLeftRight.set()
        }

        override func mouseUp(with event: NSEvent) {
            lastDragLocationX = nil
            NSCursor.resizeLeftRight.set()
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(
                NSTrackingArea(
                    rect: bounds,
                    options: [.activeInKeyWindow, .cursorUpdate, .mouseEnteredAndExited, .inVisibleRect],
                    owner: self
                )
            )
        }
    }
}
