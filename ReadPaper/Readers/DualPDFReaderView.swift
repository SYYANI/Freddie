import AppKit
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
    var noteNavigationRequest: NoteNavigationRequest? = nil
    var selectionAssistantHistoryAnchors: [SelectionAssistantHistoryAnchor] = []
    var annotationSession: PDFAnnotationSession? = nil
    var debugRegionSelectionEnabled = false
    var onDebugRegionSelected: ((PDFDebugRegionSelection) -> Void)? = nil
    var onNoteSelectionChanged: ((NoteSelectionContext?) -> Void)? = nil
    var onArxivLinkActivated: ((URL) -> Void)? = nil
    @State private var translatedPageCount: Int = 0
    @State private var originalPageCount: Int = 0
    @State private var selectionOwnership = DualPDFSelectionOwnership()
    @State private var originalSelectionResetToken = 0
    @State private var translatedSelectionResetToken = 0
    @State private var automaticScalingRestoreToken = 0

    private var isPartialTranslation: Bool {
        PDFTranslationCoverage.isPartial(
            translatedLastPage: translatedLastPage,
            originalPageCount: originalPageCount
        )
    }

    var body: some View {
        StableHorizontalPDFSplitView(onDividerDragBegan: {
            automaticScalingRestoreToken &+= 1
        }) {
            originalReader
        } trailing: {
            translatedReader
        }
        .onChange(of: originalURL) { _, _ in
            originalPageCount = 0
            selectionOwnership.reset()
            onNoteSelectionChanged?(nil)
        }
        .onChange(of: translatedURL) { _, _ in
            translatedPageCount = 0
            selectionOwnership.reset()
            onNoteSelectionChanged?(nil)
        }
    }

    private var originalReader: some View {
        themedPDFReader(
            fileURL: originalURL,
            attachmentID: originalAttachmentID,
            pageIndex: $pageIndex,
            selectionResetToken: originalSelectionResetToken,
            noteNavigationRequest: originalNoteNavigationRequest,
            debugRegionSelectionEnabled: false,
            onDocumentPageCountChanged: { pageCount in
                guard originalPageCount != pageCount else { return }
                originalPageCount = pageCount
            }
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
            pageIndex: translatedPageIndexBinding,
            reloadToken: reloadToken,
            selectionResetToken: translatedSelectionResetToken,
            noteNavigationRequest: translatedNoteNavigationRequest,
            debugRegionSelectionEnabled: debugRegionSelectionEnabled,
            onDocumentPageCountChanged: { pageCount in
                guard translatedPageCount != pageCount else { return }
                translatedPageCount = pageCount
            }
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

    private var translatedPageIndexBinding: Binding<Int> {
        Binding(
            get: {
                DualPDFPageIndexSync.translatedPageIndex(
                    forOriginalPageIndex: pageIndex,
                    translatedPageCount: translatedPageCount
                )
            },
            set: { translatedPageIndex in
                guard let target = DualPDFPageIndexSync.originalPageIndex(
                    forTranslatedPageIndex: translatedPageIndex,
                    translatedPageCount: translatedPageCount
                ), pageIndex != target else {
                    return
                }
                pageIndex = target
            }
        )
    }

    private var originalNoteNavigationRequest: NoteNavigationRequest? {
        guard let request = noteNavigationRequest else { return nil }
        guard request.attachmentID == nil || request.attachmentID == originalAttachmentID else {
            return nil
        }
        return request
    }

    private var translatedNoteNavigationRequest: NoteNavigationRequest? {
        guard let request = noteNavigationRequest,
              request.attachmentID != nil,
              request.attachmentID == translatedAttachmentID else {
            return nil
        }
        return request
    }

    private func themedPDFReader(
        fileURL: URL?,
        attachmentID: UUID?,
        pageIndex: Binding<Int>,
        reloadToken: Int = 0,
        selectionResetToken: Int,
        noteNavigationRequest: NoteNavigationRequest?,
        debugRegionSelectionEnabled: Bool,
        onDocumentPageCountChanged: @escaping (Int) -> Void,
        onSelectionChanged: @escaping (NoteSelectionContext?) -> Void
    ) -> some View {
        PDFDisplaySurface(appearance: displayAppearance) {
            PDFReaderView(
                fileURL: fileURL,
                paperID: paperID,
                attachmentID: attachmentID,
                displayAppearance: displayAppearance,
                usesAutomaticScaling: true,
                automaticScalingRestoreToken: automaticScalingRestoreToken,
                pageIndex: pageIndex,
                reloadToken: reloadToken,
                selectionResetToken: selectionResetToken,
                noteNavigationRequest: noteNavigationRequest,
                selectionAssistantHistoryAnchors: selectionAssistantHistoryAnchors,
                annotationSession: annotationSession,
                onNoteSelectionChanged: onSelectionChanged,
                onArxivLinkActivated: onArxivLinkActivated,
                onDocumentPageCountChanged: onDocumentPageCountChanged,
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
    static let minimumDragUpdateInterval: TimeInterval = 1.0 / 60.0

    static func shouldEmitDragUpdate(
        lastTimestamp: TimeInterval?,
        currentTimestamp: TimeInterval
    ) -> Bool {
        guard let lastTimestamp else { return true }
        let timestampTolerance: TimeInterval = 0.000_001
        return currentTimestamp - lastTimestamp + timestampTolerance >= minimumDragUpdateInterval
    }

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
    private let onDividerDragBegan: () -> Void
    private let leading: Leading
    private let trailing: Trailing

    init(
        onDividerDragBegan: @escaping () -> Void = {},
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.onDividerDragBegan = onDividerDragBegan
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

                StablePDFSplitDivider(
                    onDragBegan: onDividerDragBegan,
                    onDrag: { delta in
                        leadingFraction = DualPDFSplitLayout.fraction(
                            afterDraggingBy: delta,
                            totalWidth: totalWidth,
                            currentFraction: leadingFraction
                        )
                    }
                )
                .frame(width: DualPDFSplitLayout.dividerWidth)

                trailing
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

private struct StablePDFSplitDivider: NSViewRepresentable {
    var onDragBegan: () -> Void
    var onDrag: (CGFloat) -> Void

    func makeNSView(context: Context) -> DividerView {
        let view = DividerView()
        view.onDragBegan = onDragBegan
        view.onDrag = onDrag
        return view
    }

    func updateNSView(_ nsView: DividerView, context: Context) {
        nsView.onDragBegan = onDragBegan
        nsView.onDrag = onDrag
    }

    final class DividerView: NSView {
        var onDragBegan: (() -> Void)?
        var onDrag: ((CGFloat) -> Void)?
        private var lastDragLocationX: CGFloat?
        private var pendingDragDelta: CGFloat = 0
        private var lastDragUpdateTimestamp: TimeInterval?

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
            pendingDragDelta = 0
            lastDragUpdateTimestamp = nil
            onDragBegan?()
            NSCursor.resizeLeftRight.set()
        }

        override func mouseDragged(with event: NSEvent) {
            let locationX = event.locationInWindow.x
            if let lastDragLocationX {
                pendingDragDelta += locationX - lastDragLocationX
            }
            self.lastDragLocationX = locationX
            if DualPDFSplitLayout.shouldEmitDragUpdate(
                lastTimestamp: lastDragUpdateTimestamp,
                currentTimestamp: event.timestamp
            ) {
                flushPendingDrag(at: event.timestamp)
            }
            NSCursor.resizeLeftRight.set()
        }

        override func mouseUp(with event: NSEvent) {
            flushPendingDrag(at: event.timestamp)
            lastDragLocationX = nil
            lastDragUpdateTimestamp = nil
            NSCursor.resizeLeftRight.set()
        }

        private func flushPendingDrag(at timestamp: TimeInterval) {
            guard pendingDragDelta != 0 else { return }
            let delta = pendingDragDelta
            pendingDragDelta = 0
            lastDragUpdateTimestamp = timestamp
            onDrag?(delta)
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
