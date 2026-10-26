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

/// Where the middle of a pane falls, as a page and a fraction of that page's height from its top.
struct DualPDFScrollAnchor: Equatable {
    var pageIndex: Int
    var fraction: CGFloat
}

/// Keeps the two panes scrolled to the same place within the page while the reader scrolls
/// either one. Page sync alone moves the other pane only when the page changes, and then to
/// the top of that page. Only the pane the reader scrolls leads; the other follows and does not
/// report its page, so differently scaled panes cannot pull the shared page back and forth.
/// A pane whose document has no such page (a partial translation) stays where it is.
@MainActor
final class DualPDFScrollSync: NSObject {
    private struct Pane {
        weak var view: PDFView?
        weak var scrollView: NSScrollView?
        var onUserScroll: () -> Void
    }

    private var panes: [DualPDFSelectionSource: Pane] = [:]
    private var programmaticDepth: [DualPDFSelectionSource: Int] = [:]
    /// Panes inside a trackpad, wheel or scroller gesture, momentum included.
    private var liveScrollingSides: Set<DualPDFSelectionSource> = []
    private var isApplying = false
    /// The pane the reader scrolled last; nil until either pane is scrolled.
    private(set) var leader: DualPDFSelectionSource?
    /// Tells a scroll by the reader from layout changes and programmatic navigation.
    var isUserScroll: @MainActor (PDFView, DualPDFSelectionSource, Bool) -> Bool = DualPDFScrollSync.isUserScrollEvent

    func register(_ view: PDFView, side: DualPDFSelectionSource, onUserScroll: @escaping () -> Void) {
        guard let scrollView = view.subviews.lazy.compactMap({ $0 as? NSScrollView }).first else { return }
        if let existing = panes[side], existing.view === view, existing.scrollView === scrollView {
            panes[side]?.onUserScroll = onUserScroll
            return
        }
        removePane(side)
        panes[side] = Pane(view: view, scrollView: scrollView, onUserScroll: onUserScroll)
        let clipView = scrollView.contentView
        clipView.postsBoundsChangedNotifications = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(clipViewBoundsChanged(_:)), name: NSView.boundsDidChangeNotification, object: clipView)
        center.addObserver(self, selector: #selector(liveScrollStarted(_:)), name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
        center.addObserver(self, selector: #selector(liveScrollEnded(_:)), name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
    }

    /// Removes the pane only while it is still this view: SwiftUI may set up a replacement first.
    func unregister(_ view: PDFView, side: DualPDFSelectionSource) {
        guard panes[side]?.view === view else { return }
        removePane(side)
    }

    private func removePane(_ side: DualPDFSelectionSource) {
        guard let pane = panes.removeValue(forKey: side) else { return }
        let center = NotificationCenter.default
        if let scrollView = pane.scrollView {
            center.removeObserver(self, name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
            center.removeObserver(self, name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
            center.removeObserver(self, name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
        }
        liveScrollingSides.remove(side)
        if leader == side {
            leader = nil
        }
    }

    func isFollowing(_ side: DualPDFSelectionSource) -> Bool {
        leader != nil && leader != side
    }

    /// Scrolls made by `body`, such as restoring a page or loading a document, do not lead.
    func withoutLeading(_ side: DualPDFSelectionSource, _ body: () -> Void) {
        programmaticDepth[side, default: 0] += 1
        defer { programmaticDepth[side, default: 1] -= 1 }
        body()
    }

    private func side(of notification: Notification) -> DualPDFSelectionSource? {
        panes.first { pane in
            pane.value.scrollView === notification.object as AnyObject
                || pane.value.scrollView?.contentView === notification.object as AnyObject
        }?.key
    }

    // AppKit tracks trackpad and wheel gestures outside the normal event dispatch, so
    // `NSApp.currentEvent` is stale for most of a gesture. Live-scroll notifications bracket
    // every scroll the reader makes with the trackpad, a wheel or the scroller, momentum included.
    @objc private func liveScrollStarted(_ notification: Notification) {
        guard let side = side(of: notification) else { return }
        // Scrolling one pane stops the other from leading, even while its momentum runs out.
        liveScrollingSides = [side]
    }

    @objc private func liveScrollEnded(_ notification: Notification) {
        guard let side = side(of: notification) else { return }
        liveScrollingSides.remove(side)
    }

    @objc private func clipViewBoundsChanged(_ notification: Notification) {
        guard let side = side(of: notification) else { return }
        paneDidScroll(side)
    }

    func paneDidScroll(_ side: DualPDFSelectionSource) {
        guard !isApplying,
              programmaticDepth[side, default: 0] == 0,
              let source = panes[side]?.view,
              isUserScroll(source, side, liveScrollingSides.contains(side))
        else { return }
        lead(side)
    }

    /// Makes this pane lead, also after it jumped on purpose, such as to a note or a find match.
    func lead(_ side: DualPDFSelectionSource) {
        guard let source = panes[side]?.view else { return }
        leader = side
        panes[side]?.onUserScroll()
        let otherSide: DualPDFSelectionSource = side == .original ? .translated : .original
        guard let target = panes[otherSide]?.view,
              let anchor = Self.anchor(in: source)
        else { return }
        isApplying = true
        defer { isApplying = false }
        Self.scroll(target, to: anchor)
    }

    static func anchor(in view: PDFView) -> DualPDFScrollAnchor? {
        guard let document = view.document,
              let clipView = view.subviews.lazy.compactMap({ $0 as? NSScrollView }).first?.contentView
        else { return nil }
        let visible = clipView.bounds
        let center = view.convert(NSPoint(x: visible.midX, y: visible.midY), from: clipView)
        guard let page = view.page(for: center, nearest: true) else { return nil }
        let pageIndex = document.index(for: page)
        let bounds = page.bounds(for: view.displayBox)
        guard pageIndex != NSNotFound, bounds.height > 0 else { return nil }
        let point = view.convert(center, to: page)
        return DualPDFScrollAnchor(pageIndex: pageIndex, fraction: (bounds.maxY - point.y) / bounds.height)
    }

    /// Scrolls vertically so the anchor sits in the middle of the pane.
    static func scroll(_ view: PDFView, to anchor: DualPDFScrollAnchor) {
        guard let document = view.document,
              anchor.pageIndex < document.pageCount,
              let page = document.page(at: anchor.pageIndex),
              let scrollView = view.subviews.lazy.compactMap({ $0 as? NSScrollView }).first
        else { return }
        let clipView = scrollView.contentView
        let bounds = page.bounds(for: view.displayBox)
        let pagePoint = CGPoint(x: bounds.midX, y: bounds.maxY - anchor.fraction * bounds.height)
        let target = clipView.convert(view.convert(pagePoint, from: page), from: view)
        var origin = clipView.bounds.origin
        origin.y += target.y - clipView.bounds.midY
        origin = clipView.constrainBoundsRect(NSRect(origin: origin, size: clipView.bounds.size)).origin
        guard abs(origin.y - clipView.bounds.origin.y) > 0.5 else { return }
        clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: origin.y))
        scrollView.reflectScrolledClipView(clipView)
    }

    /// A live scroll, or a key or click handled in this pane, such as arrow keys or Page Down.
    private static func isUserScrollEvent(_ view: PDFView, side: DualPDFSelectionSource, isLiveScrolling: Bool) -> Bool {
        if isLiveScrolling { return true }
        guard let event = NSApp.currentEvent, let window = view.window, event.window === window else { return false }
        switch event.type {
        case .keyDown:
            return (window.firstResponder as? NSView)?.isDescendant(of: view) == true
        case .leftMouseDown, .leftMouseDragged:
            return view.bounds.contains(view.convert(event.locationInWindow, from: nil))
        default:
            return false
        }
    }
}

struct DualPDFReaderView: View {
    @Environment(\.localizationBundle) private var bundle
    var paperID: UUID? = nil
    var originalURL: URL?
    var originalAttachmentID: UUID? = nil
    /// Replaces the Original label, such as a menu choosing the scan or its transcription.
    var originalLabel: AnyView? = nil
    var translatedURL: URL?
    var translatedAttachmentID: UUID? = nil
    var translatedLastPage: Int? = nil
    var displayAppearance: PDFDisplayAppearance = .defaultMode
    @Binding var pageIndex: Int
    var reloadToken: Int = 0
    var noteNavigationRequest: NoteNavigationRequest? = nil
    var selectionAssistantHistoryAnchors: [SelectionAssistantHistoryAnchor] = []
    var citationMarks: [WritingCitationMark] = []
    var onCitationMarksActivated: (([String]) -> Void)? = nil
    var annotationSession: PDFAnnotationSession? = nil
    var handToolEnabled = PDFReaderControlPreferences.defaultHandToolEnabled
    /// Briefly outlines the pane affected by the shared zoom buttons.
    var zoomHighlightAttachmentID: UUID? = nil
    var debugRegionSelectionEnabled = false
    var onDebugRegionSelected: ((PDFDebugRegionSelection) -> Void)? = nil
    var onNoteSelectionChanged: ((NoteSelectionContext?) -> Void)? = nil
    var onArxivLinkActivated: ((URL) -> Void)? = nil
    var findRequest: DocumentFindRequest? = nil
    var findTarget: DualPDFSelectionSource = .original
    var onFindStatusChanged: ((DocumentFindStatus) -> Void)? = nil
    @State private var translatedPageCount: Int = 0
    @State private var originalPageCount: Int = 0
    @State private var selectionOwnership = DualPDFSelectionOwnership()
    @State private var originalSelectionResetToken = 0
    @State private var translatedSelectionResetToken = 0
    @State private var automaticScalingRestoreToken = 0
    @State private var scrollSync = DualPDFScrollSync()

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
        .animation(.easeOut(duration: 0.14), value: zoomHighlightAttachmentID)
    }

    private var originalReader: some View {
        themedPDFReader(
            fileURL: originalURL,
            attachmentID: originalAttachmentID,
            pageIndex: $pageIndex,
            selectionResetToken: originalSelectionResetToken,
            noteNavigationRequest: originalNoteNavigationRequest,
            findRequest: findTarget == .original ? findRequest : nil,
            debugRegionSelectionEnabled: false,
            side: .original,
            onDocumentPageCountChanged: { pageCount in
                guard originalPageCount != pageCount else { return }
                originalPageCount = pageCount
            }
        ) { selection in
            handleSelectionChange(selection, source: .original)
        }
        .overlay(alignment: .topLeading) {
            if let originalLabel {
                originalLabel
            } else {
                readerLabel(String(localized: "Original", bundle: bundle))
            }
        }
        .overlay {
            zoomTargetOverlay(for: originalAttachmentID)
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
            findRequest: findTarget == .translated ? findRequest : nil,
            debugRegionSelectionEnabled: debugRegionSelectionEnabled,
            side: .translated,
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
        .overlay {
            zoomTargetOverlay(for: translatedAttachmentID)
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
        findRequest: DocumentFindRequest?,
        debugRegionSelectionEnabled: Bool,
        side: DualPDFSelectionSource,
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
                handToolEnabled: handToolEnabled,
                onNoteSelectionChanged: onSelectionChanged,
                onArxivLinkActivated: onArxivLinkActivated,
                onDocumentPageCountChanged: onDocumentPageCountChanged,
                debugRegionSelectionEnabled: debugRegionSelectionEnabled,
                onDebugRegionSelected: onDebugRegionSelected,
                findRequest: findRequest,
                onFindStatusChanged: onFindStatusChanged,
                citationMarks: citationMarks,
                onCitationMarksActivated: onCitationMarksActivated,
                scrollSync: scrollSync,
                scrollSyncSide: side
            )
        }
    }

    @ViewBuilder
    private func zoomTargetOverlay(for attachmentID: UUID?) -> some View {
        if let attachmentID, zoomHighlightAttachmentID == attachmentID {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor.opacity(0.05))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.accentColor.opacity(0.7), lineWidth: 2)
                }
                .padding(5)
                .allowsHitTesting(false)
                .transition(.opacity)
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
