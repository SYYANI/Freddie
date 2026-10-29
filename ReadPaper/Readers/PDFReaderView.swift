import PDFKit
import OSLog
import SwiftUI

#if os(macOS)
import AppKit
import CoreImage
private typealias PlatformOutlineScrollView = NSScrollView
private typealias PlatformOutlineView = NSView
private typealias PlatformPDFColor = NSColor
private typealias PlatformPDFViewRepresentable = NSViewRepresentable
#else
import UIKit
private typealias PlatformOutlineScrollView = UIScrollView
private typealias PlatformOutlineView = UIView
private typealias PlatformPDFColor = UIColor
private typealias PlatformPDFViewRepresentable = UIViewRepresentable
#endif

enum PDFDisplayAppearance: String, CaseIterable, Identifiable {
    case defaultMode = "default"
    case paper

    static let userDefaultsKey = "ReadPaper.Reader.PDFDisplayAppearance"
    static let lastSynchronizedSystemDarkModeKey =
        "ReadPaper.Reader.LastSynchronizedSystemDarkMode"
    static let defaultValue: Self = .defaultMode

    var id: String { rawValue }

    static func synchronized(isSystemDarkMode: Bool) -> Self {
        isSystemDarkMode ? .paper : .defaultMode
    }

    static func resolve(rawValue: String) -> Self {
        Self(rawValue: rawValue) ?? defaultValue
    }

    static func synchronizeStoredPreference(
        in defaults: UserDefaults = .standard,
        isSystemDarkMode: Bool
    ) {
        let previousSystemDarkMode = defaults.object(
            forKey: lastSynchronizedSystemDarkModeKey
        ) as? Bool
        let storedPreference = defaults.string(forKey: userDefaultsKey)
        let shouldSynchronize = previousSystemDarkMode.map { $0 != isSystemDarkMode }
            ?? (storedPreference != Self.paper.rawValue)

        if shouldSynchronize {
            defaults.set(
                synchronized(isSystemDarkMode: isSystemDarkMode).rawValue,
                forKey: userDefaultsKey
            )
        }
        defaults.set(isSystemDarkMode, forKey: lastSynchronizedSystemDarkModeKey)
    }

    var requiresOverlayCompositing: Bool {
        #if os(macOS)
        false
        #else
        self == .paper
        #endif
    }

    var usesNativeContentFilter: Bool {
        #if os(macOS)
        self == .paper
        #else
        false
        #endif
    }
}

enum PDFReaderControlPreferences {
    static let handToolEnabledKey = "ReadPaper.Reader.PDFHandToolEnabled"
    static let showZoomButtonsKey = "ReadPaper.Reader.ShowPDFZoomButtons"
    static let defaultHandToolEnabled = false
    static let defaultShowZoomButtons = false
}

private struct PDFDisplayAppearanceEnvironmentKey: EnvironmentKey {
    static let defaultValue = PDFDisplayAppearance.defaultValue
}

extension EnvironmentValues {
    var pdfDisplayAppearance: PDFDisplayAppearance {
        get { self[PDFDisplayAppearanceEnvironmentKey.self] }
        set { self[PDFDisplayAppearanceEnvironmentKey.self] = newValue }
    }
}

extension PDFDisplayAppearance {
    fileprivate var pdfBackgroundColor: PlatformPDFColor {
        switch self {
        case .defaultMode:
            #if os(macOS)
            // Let the reader column's native glass material show through around
            // the PDF pages. PDFKit still renders each page on its own paper.
            return .clear
            #else
            return .systemBackground
            #endif
        case .paper:
            #if os(macOS)
            return .white
            #else
            return UIColor(red: 0.96, green: 0.93, blue: 0.86, alpha: 1)
            #endif
        }
    }

    var surfaceColor: Color {
        #if os(macOS)
        switch self {
        case .defaultMode:
            Color(nsColor: pdfBackgroundColor)
        case .paper:
            Color(red: 0.96, green: 0.93, blue: 0.86)
        }
        #else
        Color(uiColor: pdfBackgroundColor)
        #endif
    }

    #if os(macOS)
    fileprivate func makeNativeContentFilters() -> [CIFilter] {
        switch self {
        case .defaultMode:
            return []
        case .paper:
            guard let filter = CIFilter(name: "CIColorMatrix") else { return [] }
            filter.setValue(CIVector(x: 0.96, y: 0, z: 0, w: 0), forKey: "inputRVector")
            filter.setValue(CIVector(x: 0, y: 0.93, z: 0, w: 0), forKey: "inputGVector")
            filter.setValue(CIVector(x: 0, y: 0, z: 0.86, w: 0), forKey: "inputBVector")
            filter.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
            return [filter]
        }
    }
    #endif
}

struct PDFDisplaySurface<Content: View>: View {
    var appearance: PDFDisplayAppearance
    @ViewBuilder var content: () -> Content

    @ViewBuilder
    var body: some View {
        if appearance.requiresOverlayCompositing {
            content()
                .background(appearance.surfaceColor)
                .overlay {
                    overlay
                }
                // Keep difference/multiply blending local to the reader. Otherwise
                // the overlay can blend with macOS 26's floating sidebar backdrop.
                .compositingGroup()
                .clipped()
        } else {
            // Avoid forcing a continuously scrolling PDFView through an offscreen
            // compositing pass when no appearance overlay needs one.
            content()
                .background(appearance.surfaceColor)
                .clipped()
        }
    }

    @ViewBuilder
    private var overlay: some View {
        switch appearance {
        case .defaultMode:
            EmptyView()
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

enum PDFAutomaticScalingPolicy {
    static let relativeTolerance: CGFloat = 0.12

    static func shouldRestore(
        currentScale: CGFloat,
        fittedScale: CGFloat,
        tolerance: CGFloat = relativeTolerance
    ) -> Bool {
        guard currentScale.isFinite,
              fittedScale.isFinite,
              fittedScale > 0,
              tolerance >= 0 else {
            return false
        }
        return abs(currentScale - fittedScale) / fittedScale <= tolerance
    }

    /// A manual zoom that fit the pane when the divider was grabbed shrinks with a narrowing
    /// pane instead of clipping the page, and returns to the reader's zoom as the pane widens.
    static func displayedScale(preferredScale: CGFloat, fittedScale: CGFloat) -> CGFloat {
        guard fittedScale.isFinite, fittedScale > 0 else { return preferredScale }
        return min(preferredScale, fittedScale)
    }
}

/// PDF views that keep a manual zoom within the pane width (see `PDFAutomaticScalingPolicy`).
@MainActor
protocol PDFPreferredManualScaling: PDFView {
    /// The reader's own zoom while it is capped at fit; nil once the reader zooms again.
    var preferredManualScale: CGFloat? { get set }
}

extension PDFPreferredManualScaling {
    func applyPreferredManualScale() {
        guard let preferredManualScale, autoScales == false, document != nil else { return }
        let scale = PDFAutomaticScalingPolicy.displayedScale(
            preferredScale: preferredManualScale,
            fittedScale: scaleFactorForSizeToFit
        )
        guard abs(scale - scaleFactor) > 0.0001 else { return }
        scaleFactor = scale
    }
}

enum PDFNoteNavigationTextMatcher {
    static func range(of quote: String, in pageText: String) -> NSRange? {
        let normalizedQuote = normalize(quote).text
        guard normalizedQuote.isEmpty == false else { return nil }

        let normalizedPage = normalize(pageText)
        let match = (normalizedPage.text as NSString).range(of: normalizedQuote)
        guard match.location != NSNotFound,
              match.length > 0,
              match.location < normalizedPage.sourceRanges.count,
              NSMaxRange(match) <= normalizedPage.sourceRanges.count
        else {
            return nil
        }

        let first = normalizedPage.sourceRanges[match.location]
        let last = normalizedPage.sourceRanges[NSMaxRange(match) - 1]
        return NSRange(
            location: first.location,
            length: NSMaxRange(last) - first.location
        )
    }

    private static func normalize(_ text: String) -> (text: String, sourceRanges: [NSRange]) {
        let source = text as NSString
        var normalized = ""
        var sourceRanges: [NSRange] = []
        var pendingWhitespaceRange: NSRange?

        source.enumerateSubstrings(
            in: NSRange(location: 0, length: source.length),
            options: [.byComposedCharacterSequences]
        ) { substring, substringRange, _, _ in
            guard let substring else { return }
            if substring.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
                if normalized.isEmpty == false, pendingWhitespaceRange == nil {
                    pendingWhitespaceRange = substringRange
                } else if let currentWhitespaceRange = pendingWhitespaceRange {
                    pendingWhitespaceRange = NSRange(
                        location: currentWhitespaceRange.location,
                        length: NSMaxRange(substringRange) - currentWhitespaceRange.location
                    )
                }
                return
            }

            if let pendingWhitespaceRange {
                normalized.append(" ")
                sourceRanges.append(pendingWhitespaceRange)
            }
            pendingWhitespaceRange = nil

            normalized.append(substring)
            sourceRanges.append(contentsOf: repeatElement(substringRange, count: (substring as NSString).length))
        }

        return (normalized, sourceRanges)
    }
}

struct PDFDebugRegionSelection: Equatable, Sendable {
    var pageIndex: Int
    var pageBounds: CGRect
    var selectedBounds: CGRect
}

struct PDFReaderView: PlatformPDFViewRepresentable {
    var fileURL: URL?
    var paperID: UUID? = nil
    var attachmentID: UUID? = nil
    var displayAppearance: PDFDisplayAppearance = .defaultMode
    var usesAutomaticScaling = false
    var automaticScalingRestoreToken = 0
    @Binding var pageIndex: Int
    var reloadToken: Int = 0
    var selectionResetToken: Int = 0
    var noteNavigationRequest: NoteNavigationRequest? = nil
    var selectionAssistantHistoryAnchors: [SelectionAssistantHistoryAnchor] = []
    var annotationSession: PDFAnnotationSession? = nil
    var handToolEnabled = PDFReaderControlPreferences.defaultHandToolEnabled
    var onNoteSelectionChanged: ((NoteSelectionContext?) -> Void)? = nil
    var onArxivLinkActivated: ((URL) -> Void)? = nil
    var onDocumentPageCountChanged: ((Int) -> Void)? = nil
    var debugRegionSelectionEnabled = false
    var onDebugRegionSelected: ((PDFDebugRegionSelection) -> Void)? = nil
    var findRequest: DocumentFindRequest? = nil
    var onFindStatusChanged: ((DocumentFindStatus) -> Void)? = nil
    var sidenoteAnchors: [PDFSidenoteAnchor] = []
    var sidenoteLayout: PDFSidenoteLayoutModel? = nil
    /// Passages cited in writings, underlined in the document.
    var citationMarks: [WritingCitationMark] = []
    /// A single click on cited passages, with the marks under the pointer.
    var onCitationMarksActivated: (([String]) -> Void)? = nil
    var onOutlineLocationChanged: ((Int, Double) -> Void)? = nil
    #if os(macOS)
    /// Scrolls the other pane of a side-by-side reader along with this one.
    var scrollSync: DualPDFScrollSync? = nil
    var scrollSyncSide: DualPDFSelectionSource = .original
    #endif

    #if os(macOS)
    func makeNSView(context: Context) -> PDFView {
        makeView(context: context)
    }

    func updateNSView(_ view: PDFView, context: Context) {
        updateView(view, context: context)
    }

    static func dismantleNSView(_ nsView: PDFView, coordinator: Coordinator) {
        coordinator.detach()
    }
    #else
    func makeUIView(context: Context) -> PDFView {
        makeView(context: context)
    }

    func updateUIView(_ view: PDFView, context: Context) {
        updateView(view, context: context)
    }

    static func dismantleUIView(_ uiView: PDFView, coordinator: Coordinator) {
        coordinator.detach()
    }
    #endif

    private func makeView(context: Context) -> PDFView {
        #if os(macOS)
        let view = InteractivePDFView()
        #else
        let view = TouchPDFView()
        #endif
        context.coordinator.applyScalingPreference(usesAutomaticScaling, to: view)
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        context.coordinator.applyDisplayAppearance(displayAppearance, to: view)
        context.coordinator.attach(to: view)
        return view
    }

    private func updateView(_ view: PDFView, context: Context) {
        let updateSignpostID = context.coordinator.beginViewUpdateSignpost()
        defer {
            context.coordinator.endViewUpdateSignpost(updateSignpostID)
        }

        context.coordinator.applyScalingPreference(usesAutomaticScaling, to: view)
        if context.coordinator.lastAutomaticScalingRestoreToken != automaticScalingRestoreToken {
            context.coordinator.lastAutomaticScalingRestoreToken = automaticScalingRestoreToken
            context.coordinator.restoreAutomaticScalingIfNearFit(in: view)
        }
        context.coordinator.applyDisplayAppearance(displayAppearance, to: view)
        context.coordinator.configure(
            paperID: paperID,
            attachmentID: attachmentID,
            annotationSession: annotationSession
        )
        context.coordinator.onNoteSelectionChanged = onNoteSelectionChanged
        context.coordinator.onArxivLinkActivated = onArxivLinkActivated
        context.coordinator.onDocumentPageCountChanged = onDocumentPageCountChanged
        context.coordinator.onFindStatusChanged = onFindStatusChanged
        context.coordinator.onCitationMarksActivated = onCitationMarksActivated
        context.coordinator.onOutlineLocationChanged = onOutlineLocationChanged
        if context.coordinator.lastSelectionResetToken != selectionResetToken {
            context.coordinator.lastSelectionResetToken = selectionResetToken
            view.clearSelection()
            context.coordinator.publishSelection(nil)
        }
        #if os(macOS)
        if let interactiveView = view as? InteractivePDFView {
            context.coordinator.applyInteractionConfiguration(
                debugRegionSelectionEnabled: debugRegionSelectionEnabled,
                annotationSession: annotationSession,
                displayAppearance: displayAppearance,
                handToolEnabled: handToolEnabled,
                to: interactiveView
            )
            interactiveView.onDebugRegionSelected = onDebugRegionSelected
        }
        context.coordinator.attachScrollSync(scrollSync, side: scrollSyncSide, to: view)
        #else
        if let touchView = view as? TouchPDFView {
            touchView.annotationInteractionMode = annotationSession?.interactionMode ?? .browse
            touchView.annotationColorPreset = annotationSession?.colorPreset ?? .yellow
            context.coordinator.applyPencilInteractionConfiguration(
                annotationSession: annotationSession
            )
        }
        #endif

        guard let fileURL else {
            let hadLoadedDocument = view.document != nil || context.coordinator.loadedURL != nil
            if hadLoadedDocument {
                context.coordinator.invalidateFindDocument(in: view, keepingPosition: false)
                view.document = nil
                context.coordinator.clearLoadedAnnotations()
                context.coordinator.clearProgrammaticPageRestore()
                context.coordinator.publishSelection(nil)
            }
            context.coordinator.loadedURL = nil
            context.coordinator.loadedPaperID = paperID
            context.coordinator.loadedAttachmentID = attachmentID
            context.coordinator.lastReloadToken = reloadToken
            context.coordinator.scheduleDocumentPageCountUpdate(0)
            context.coordinator.applyFindRequest(nil, in: view)
            context.coordinator.applySidenoteAnchors(
                [],
                layout: sidenoteLayout,
                documentReloaded: hadLoadedDocument,
                in: view
            )
            return
        }
        let shouldReloadDocument = context.coordinator.loadedURL != fileURL ||
            context.coordinator.lastReloadToken != reloadToken ||
            context.coordinator.loadedPaperID != paperID ||
            context.coordinator.loadedAttachmentID != attachmentID
        if shouldReloadDocument {
            // Only a reload of the same attachment keeps the current scroll position, also when
            // a translation update writes a new file. Another paper opens at `pageIndex`: its
            // restored page, or the page of a citation opened from a writing.
            let isSameDocument = context.coordinator.loadedPaperID == paperID &&
                context.coordinator.loadedAttachmentID == attachmentID
            let restorePosition = isSameDocument
                ? context.coordinator.readingPosition(fallbackPageIndex: pageIndex, in: view)
                : PDFReadingPosition(pageIndex: pageIndex)
            context.coordinator.prepareForProgrammaticPageRestore(to: restorePosition)
            context.coordinator.clearSelectionAssistantHistoryAnnotations()
            context.coordinator.clearCitationMarkAnnotations()
            context.coordinator.invalidateFindDocument(
                in: view,
                keepingPosition: context.coordinator.loadedURL == fileURL &&
                    context.coordinator.loadedAttachmentID == attachmentID
            )
            let document = PDFDocument(url: fileURL)
            context.coordinator.withoutLeadingScrollSync {
                view.document = document
            }
            context.coordinator.loadedURL = fileURL
            context.coordinator.loadedPaperID = paperID
            context.coordinator.loadedAttachmentID = attachmentID
            context.coordinator.lastReloadToken = reloadToken
            context.coordinator.scheduleDocumentPageCountUpdate(
                document?.pageCount ?? 0,
                force: true
            )
            context.coordinator.loadAnnotations(in: view)
            context.coordinator.publishSelection(nil)
            context.coordinator.restoreReadingPosition(
                restorePosition,
                in: view,
                suppressIntermediateUpdates: true
            )
            context.coordinator.scheduleCurrentPageIndexUpdate()
        } else if context.coordinator.shouldRestorePageIndex(pageIndex, in: view) {
            context.coordinator.restoreReadingPosition(
                PDFReadingPosition(pageIndex: pageIndex),
                in: view,
                suppressIntermediateUpdates: false
            )
            context.coordinator.scheduleCurrentPageIndexUpdate()
        }
        context.coordinator.applySelectionAssistantHistoryAnchors(
            selectionAssistantHistoryAnchors,
            in: view,
            force: shouldReloadDocument
        )
        context.coordinator.applyCitationMarks(citationMarks, in: view, force: shouldReloadDocument)
        context.coordinator.applyNoteNavigationIfNeeded(noteNavigationRequest, in: view)
        context.coordinator.observeOutlineGeometry(in: view)
        context.coordinator.applyFindRequest(findRequest, in: view)
        context.coordinator.applySidenoteAnchors(
            sidenoteAnchors,
            layout: sidenoteLayout,
            documentReloaded: shouldReloadDocument,
            in: view
        )
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            paperID: paperID,
            attachmentID: attachmentID,
            pageIndex: $pageIndex,
            onNoteSelectionChanged: onNoteSelectionChanged,
            onArxivLinkActivated: onArxivLinkActivated,
            annotationSession: annotationSession
        )
    }

    @MainActor
    final class Coordinator: NSObject, PDFAnnotationSessionHandler {
        #if os(macOS)
        private struct InteractionConfiguration: Equatable {
            var mode: PDFInteractionMode
            var colorPreset: PDFAnnotationColorPreset
            var lineWidth: Double
            var displayAppearance: PDFDisplayAppearance
            var handToolEnabled: Bool
        }
        #else
        private struct PencilInteractionConfiguration: Equatable {
            var mode: PDFInteractionMode
            var colorPreset: PDFAnnotationColorPreset
            var lineWidth: Double
        }
        #endif

        private static let performanceLog = OSLog(
            subsystem: "com.yiyan.ReadPaper",
            category: .pointsOfInterest
        )

        private enum AnnotationHistoryEntry {
            case add([PDFAnnotationRecord])
            case remove([PDFAnnotationRecord])
        }

        var loadedURL: URL?
        var loadedPaperID: UUID?
        var loadedAttachmentID: UUID?
        var lastReloadToken: Int = 0
        var lastSelectionResetToken: Int = 0
        var lastAutomaticScalingRestoreToken: Int = 0
        var paperID: UUID?
        var attachmentID: UUID?
        weak var pdfView: PDFView?
        var pageIndex: Binding<Int>
        var onNoteSelectionChanged: ((NoteSelectionContext?) -> Void)?
        var onArxivLinkActivated: ((URL) -> Void)?
        var onOutlineLocationChanged: ((Int, Double) -> Void)?
        private var outlineGeometryObservation: NSKeyValueObservation?
        #if os(macOS)
        private var outlineGeometryNotification: NSObjectProtocol?
        #endif
        private weak var outlineScrollView: PlatformOutlineScrollView?
        var onDocumentPageCountChanged: ((Int) -> Void)?
        private weak var annotationSession: PDFAnnotationSession?
        private weak var registeredAnnotationSession: PDFAnnotationSession?
        private var registeredAnnotationAttachmentID: UUID?
        private var annotationStore: PDFAnnotationStore
        private var annotationRecords: [PDFAnnotationRecord] = []
        private var renderedAnnotations: [UUID: PDFAnnotation] = [:]
        private var undoAnnotationHistory: [AnnotationHistoryEntry] = []
        private var redoAnnotationHistory: [AnnotationHistoryEntry] = []
        private var isPageIndexUpdateScheduled = false
        private var isSelectionUpdateScheduled = false
        private var lastPublishedSelection: NoteSelectionContext?
        private var pendingProgrammaticPosition: PDFReadingPosition?
        private var appliedAutomaticScaling: Bool?
        private var appliedDisplayAppearance: PDFDisplayAppearance?
        #if os(macOS)
        private var appliedInteractionConfiguration: InteractionConfiguration?
        #else
        private var appliedPencilInteractionConfiguration: PencilInteractionConfiguration?
        private let pencilPageOverlays = NSHashTable<PDFPencilPageOverlayView>.weakObjects()
        #endif
        private var pendingDocumentPageCount: Int?
        private var pendingDocumentPageCountForce = false
        private var lastPublishedDocumentPageCount: Int?
        private var isDocumentPageCountUpdateScheduled = false
        private var lastAppliedNoteNavigationID: UUID?
        private var noteNavigationHighlightAnnotations: [PDFAnnotation] = []
        private var noteNavigationHighlightTask: Task<Void, Never>?
        private var selectionAssistantHistoryRenderTask: Task<Void, Never>?
        private var receivedSelectionAssistantHistoryAnchors: [SelectionAssistantHistoryAnchor] = []
        private var appliedSelectionAssistantHistoryAnchors: [SelectionAssistantHistoryAnchor] = []
        private var renderedSelectionAssistantHistoryAnchorIDs: Set<String> = []
        private var selectionAssistantHistoryAnnotations: [(SelectionAssistantHistoryAnchor, PDFAnnotation)] = []
        var onCitationMarksActivated: (([String]) -> Void)?
        private var citationMarkRenderTask: Task<Void, Never>?
        private var appliedCitationMarks: [WritingCitationMark] = []
        private var renderedCitationMarkIDs: Set<String> = []
        private var citationMarkAnnotations: [(markID: String, annotation: PDFAnnotation)] = []
        var onFindStatusChanged: ((DocumentFindStatus) -> Void)?
        private var findDocumentGeneration = 0
        private var findPageTexts: [DocumentSearchText]?
        private var findPageTextsKey: FindDocumentKey?
        private var findTextLoadingKey: FindDocumentKey?
        private var findTextLoadTask: Task<Void, Never>?
        private var latestFindRequest: DocumentFindRequest?
        private var appliedFindRequest: DocumentFindRequest?
        private var findResultsNeedRefresh = false
        private var findMatches: [(pageIndex: Int, selection: PDFSelection)] = []
        private var currentFindMatchIndex: Int?
        private var lastPublishedFindStatus: DocumentFindStatus?
        private var sidenoteAnchors: [PDFSidenoteAnchor] = []
        private weak var sidenoteLayout: PDFSidenoteLayoutModel?
        private var sidenotePageRects: [UUID: (pageIndex: Int, rect: CGRect)] = [:]
        private var sidenoteHighlightAnnotations: [UUID: [PDFAnnotation]] = [:]
        private var sidenotePageTexts: [Int: String] = [:]
        private var isSidenotePositionUpdateScheduled = false
        #if os(macOS)
        private weak var observedSidenoteScrollView: NSScrollView?
        private(set) weak var scrollSync: DualPDFScrollSync?
        private var scrollSyncSide: DualPDFSelectionSource = .original
        #endif

        init(
            paperID: UUID? = nil,
            attachmentID: UUID?,
            pageIndex: Binding<Int>,
            onNoteSelectionChanged: ((NoteSelectionContext?) -> Void)?,
            onArxivLinkActivated: ((URL) -> Void)? = nil,
            annotationSession: PDFAnnotationSession? = nil,
            annotationStore: PDFAnnotationStore = PDFAnnotationStore()
        ) {
            self.paperID = paperID
            self.attachmentID = attachmentID
            self.pageIndex = pageIndex
            self.onNoteSelectionChanged = onNoteSelectionChanged
            self.onArxivLinkActivated = onArxivLinkActivated
            self.annotationSession = annotationSession
            self.annotationStore = annotationStore
        }

        var annotationAttachmentID: UUID? { attachmentID }

        var hasPDFTextSelection: Bool {
            currentSelectionContext()?.trimmedQuote != nil
        }

        var canUndoPDFAnnotation: Bool { undoAnnotationHistory.isEmpty == false }
        var canRedoPDFAnnotation: Bool { redoAnnotationHistory.isEmpty == false }
        var hasPDFAnnotations: Bool { annotationRecords.isEmpty == false }

        func beginViewUpdateSignpost() -> OSSignpostID {
            let signpostID = OSSignpostID(log: Self.performanceLog)
            os_signpost(
                .begin,
                log: Self.performanceLog,
                name: "PDF View Update",
                signpostID: signpostID
            )
            return signpostID
        }

        func endViewUpdateSignpost(_ signpostID: OSSignpostID) {
            os_signpost(
                .end,
                log: Self.performanceLog,
                name: "PDF View Update",
                signpostID: signpostID
            )
        }

        #if os(macOS)
        func attachScrollSync(_ scrollSync: DualPDFScrollSync?, side: DualPDFSelectionSource, to pdfView: PDFView) {
            if self.scrollSync !== scrollSync || scrollSyncSide != side {
                self.scrollSync?.unregister(pdfView, side: scrollSyncSide)
            }
            self.scrollSync = scrollSync
            scrollSyncSide = side
            // A pane the reader scrolls no longer waits for an earlier programmatic page.
            scrollSync?.register(pdfView, side: side) { [weak self] in
                self?.clearProgrammaticPageRestore()
                self?.activateAnnotationDocument()
            }
        }
        #endif

        /// Restoring a page or loading a document moves this pane without leading the other one.
        func withoutLeadingScrollSync(_ body: () -> Void) {
            #if os(macOS)
            if let scrollSync {
                scrollSync.withoutLeading(scrollSyncSide, body)
                return
            }
            #endif
            body()
        }

        /// After a jump to a note or a find match, the other pane follows this one.
        private func leadScrollSync() {
            #if os(macOS)
            scrollSync?.lead(scrollSyncSide)
            #endif
        }

        /// A following pane is placed by the pane the reader scrolls, not by the page it reports.
        private var isFollowingScrollSync: Bool {
            #if os(macOS)
            return scrollSync?.isFollowing(scrollSyncSide) == true
            #else
            return false
            #endif
        }

        func applyScalingPreference(_ usesAutomaticScaling: Bool, to pdfView: PDFView) {
            guard appliedAutomaticScaling != usesAutomaticScaling else { return }
            appliedAutomaticScaling = usesAutomaticScaling
            pdfView.autoScales = usesAutomaticScaling
            (pdfView as? PDFPreferredManualScaling)?.preferredManualScale = nil
            if usesAutomaticScaling == false {
                pdfView.scaleFactor = 1
            }
        }

        /// Called when the split divider is grabbed: a zoom near fit goes back to fitting the
        /// pane, and a smaller one is kept but shrinks if the pane becomes narrower than it.
        func restoreAutomaticScalingIfNearFit(in pdfView: PDFView) {
            guard pdfView.autoScales == false else { return }
            let scalingView = pdfView as? PDFPreferredManualScaling
            let preferredScale = scalingView?.preferredManualScale ?? pdfView.scaleFactor
            let fittedScale = pdfView.scaleFactorForSizeToFit
            if PDFAutomaticScalingPolicy.shouldRestore(
                currentScale: preferredScale,
                fittedScale: fittedScale
            ) {
                scalingView?.preferredManualScale = nil
                pdfView.autoScales = true
                return
            }
            // A zoom wider than the pane was already clipped on purpose; leave it alone.
            scalingView?.preferredManualScale = preferredScale < fittedScale ? preferredScale : nil
        }

        func applyDisplayAppearance(_ appearance: PDFDisplayAppearance, to pdfView: PDFView) {
            let appearanceChanged = appliedDisplayAppearance != appearance
            if appearanceChanged {
                appliedDisplayAppearance = appearance
                pdfView.backgroundColor = appearance.pdfBackgroundColor
            }
            #if os(macOS)
            if appearanceChanged {
                pdfView.contentFilters = appearance.makeNativeContentFilters()
            }
            configureCanvasBackground(appearance, in: pdfView)
            #endif
        }

        #if os(macOS)
        private func configureCanvasBackground(
            _ appearance: PDFDisplayAppearance,
            in pdfView: PDFView
        ) {
            let isTransparent = appearance == .defaultMode

            // PDFKit owns a nested PDFScrollView/PDFClipView pair which keeps
            // painting its own canvas even when PDFView.backgroundColor is clear.
            // Disable those public AppKit background layers so the reader's glass
            // material is visible around the document pages.
            for scrollView in pdfView.subviews.compactMap({ $0 as? NSScrollView }) {
                scrollView.drawsBackground = !isTransparent
                scrollView.backgroundColor = appearance.pdfBackgroundColor
                scrollView.contentView.drawsBackground = !isTransparent
                scrollView.contentView.backgroundColor = appearance.pdfBackgroundColor
            }
        }

        fileprivate func applyInteractionConfiguration(
            debugRegionSelectionEnabled: Bool,
            annotationSession: PDFAnnotationSession?,
            displayAppearance: PDFDisplayAppearance,
            handToolEnabled: Bool,
            to pdfView: InteractivePDFView
        ) {
            let configuration = InteractionConfiguration(
                mode: debugRegionSelectionEnabled
                    ? .debugRegion
                    : annotationSession?.interactionMode ?? .browse,
                colorPreset: annotationSession?.colorPreset ?? .yellow,
                lineWidth: annotationSession?.lineWidth ?? PDFAnnotationLineWidthPreset.defaultValue,
                displayAppearance: displayAppearance,
                handToolEnabled: handToolEnabled
            )
            guard appliedInteractionConfiguration != configuration else { return }
            appliedInteractionConfiguration = configuration
            pdfView.interactionMode = configuration.mode
            pdfView.inkPreviewColor = configuration.colorPreset
                .color(for: .ink)
                .platformColor(inverted: false)
            pdfView.inkPreviewLineWidth = configuration.lineWidth
            pdfView.handToolEnabled = configuration.handToolEnabled
        }
        #endif

        #if os(iOS)
        fileprivate func applyPencilInteractionConfiguration(
            annotationSession: PDFAnnotationSession?
        ) {
            let configuration = PencilInteractionConfiguration(
                mode: annotationSession?.interactionMode ?? .browse,
                colorPreset: annotationSession?.colorPreset ?? .yellow,
                lineWidth: annotationSession?.lineWidth ?? PDFAnnotationLineWidthPreset.defaultValue
            )
            guard appliedPencilInteractionConfiguration != configuration else { return }
            appliedPencilInteractionConfiguration = configuration
            for overlay in pencilPageOverlays.allObjects {
                configurePencilOverlay(overlay, with: configuration)
            }
        }

        private func configurePencilOverlay(
            _ overlay: PDFPencilPageOverlayView,
            with configuration: PencilInteractionConfiguration
        ) {
            overlay.interactionMode = configuration.mode
            overlay.inkColor = configuration.colorPreset
                .color(for: .ink)
                .platformColor(inverted: false)
            overlay.inkLineWidth = max(0.5, configuration.lineWidth)
        }

        private func refreshPencilInkOverlays(in pdfView: PDFView) {
            for overlay in pencilPageOverlays.allObjects {
                guard let page = overlay.pdfPage else { continue }
                refreshPencilInk(on: overlay, for: page, in: pdfView)
            }
        }

        private func refreshPencilInk(
            on overlay: PDFPencilPageOverlayView,
            for page: PDFPage,
            in pdfView: PDFView
        ) {
            guard let document = pdfView.document else {
                overlay.displayPersistedInk([])
                return
            }
            let pageIndex = document.index(for: page)
            guard pageIndex != NSNotFound else {
                overlay.displayPersistedInk([])
                return
            }
            overlay.displayPersistedInk(
                annotationRecords.filter { $0.pageIndex == pageIndex && $0.kind == .ink }
            )
        }

        private func pencilPagePoint(
            for overlayPoint: CGPoint,
            overlay: PDFPencilPageOverlayView,
            pdfView: PDFView,
            page: PDFPage
        ) -> CGPoint {
            pdfView.convert(overlay.convert(overlayPoint, to: pdfView), to: page)
        }

        private func pencilPageWidth(
            at overlayPoint: CGPoint,
            displayWidth: CGFloat,
            overlay: PDFPencilPageOverlayView,
            pdfView: PDFView,
            page: PDFPage
        ) -> CGFloat {
            let pageStart = pencilPagePoint(
                for: overlayPoint,
                overlay: overlay,
                pdfView: pdfView,
                page: page
            )
            let pageEnd = pencilPagePoint(
                for: CGPoint(x: overlayPoint.x + displayWidth, y: overlayPoint.y),
                overlay: overlay,
                pdfView: pdfView,
                page: page
            )
            return max(0.1, hypot(pageEnd.x - pageStart.x, pageEnd.y - pageStart.y))
        }
        #endif

        func configure(
            paperID: UUID?,
            attachmentID: UUID?,
            annotationSession: PDFAnnotationSession?
        ) {
            let oldPaperID = self.paperID
            let oldAttachmentID = self.attachmentID
            let scopeChanged = oldPaperID != paperID || oldAttachmentID != attachmentID
            let registrationChanged = registeredAnnotationAttachmentID != attachmentID ||
                registeredAnnotationSession !== annotationSession

            if registrationChanged,
               let registeredAnnotationAttachmentID,
               let registeredAnnotationSession {
                Task { @MainActor [weak self, weak registeredAnnotationSession] in
                    guard let self, let registeredAnnotationSession else { return }
                    registeredAnnotationSession.unregister(
                        self,
                        for: registeredAnnotationAttachmentID
                    )
                }
            }

            self.paperID = paperID
            self.attachmentID = attachmentID
            self.annotationSession = annotationSession

            if scopeChanged {
                annotationRecords = []
                renderedAnnotations = [:]
                undoAnnotationHistory = []
                redoAnnotationHistory = []
            }

            if registrationChanged {
                registeredAnnotationAttachmentID = attachmentID
                registeredAnnotationSession = annotationSession
                if let attachmentID, let annotationSession {
                    Task { @MainActor [weak self, weak annotationSession] in
                        guard let self,
                              let annotationSession,
                              self.registeredAnnotationAttachmentID == attachmentID,
                              self.registeredAnnotationSession === annotationSession
                        else {
                            return
                        }
                        annotationSession.register(self, for: attachmentID)
                    }
                }
            }
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
            #if os(macOS)
            if let interactiveView = pdfView as? InteractivePDFView {
                interactiveView.onLinkActivated = { [weak self] url in
                    self?.handleLinkActivation(url) ?? false
                }
                interactiveView.onInteractionBegan = { [weak self] in
                    self?.activateAnnotationDocument()
                }
                interactiveView.onBrowseClick = { [weak self] page, point in
                    guard let self else { return false }
                    self.flashSidenote(on: page, at: point)
                    return self.handleSelectionAssistantHistoryClick(on: page, at: point)
                }
                interactiveView.onBrowseSingleClick = { [weak self] page, point in
                    self?.handleCitationMarkClick(on: page, at: point)
                }
                interactiveView.onInkStrokeCompleted = { [weak self] page, points in
                    self?.addInkAnnotation(on: page, points: points)
                }
                interactiveView.onEraseRequested = { [weak self] page, point in
                    self?.eraseAnnotation(on: page, at: point)
                }
                interactiveView.onTextNoteRequested = { [weak self] page, point in
                    self?.requestTextNote(on: page, at: point)
                }
            }
            #else
            if let touchView = pdfView as? TouchPDFView {
                touchView.pageOverlayViewProvider = self
                touchView.onPencilDoubleTap = { [weak self] in
                    guard let self else { return }
                    self.activateAnnotationDocument()
                    self.annotationSession?.toggleInkAndEraser()
                }
                touchView.onPencilShortcutAction = { [weak self] action in
                    guard let self else { return }
                    self.activateAnnotationDocument()
                    switch action {
                    case .undo:
                        self.annotationSession?.undo()
                    case .selectTool(let mode):
                        self.annotationSession?.selectInteractionMode(mode)
                    case .selectColor(let preset):
                        self.annotationSession?.selectInkColor(preset)
                    }
                }
                NotificationCenter.default.removeObserver(
                    self,
                    name: Notification.Name.PDFViewScaleChanged,
                    object: touchView
                )
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(handlePencilScaleChanged(_:)),
                    name: Notification.Name.PDFViewScaleChanged,
                    object: touchView
                )
            }
            #endif
        }

        func detach() {
            #if os(macOS)
            if let outlineGeometryNotification { NotificationCenter.default.removeObserver(outlineGeometryNotification) }
            outlineGeometryNotification = nil
            #endif
            outlineGeometryObservation = nil
            outlineScrollView = nil
            findTextLoadTask?.cancel()
            findTextLoadTask = nil
            #if os(macOS)
            stopObservingSidenoteGeometry()
            if let pdfView {
                scrollSync?.unregister(pdfView, side: scrollSyncSide)
            }
            scrollSync = nil
            #else
            if let touchView = pdfView as? TouchPDFView,
               touchView.pageOverlayViewProvider === self {
                touchView.pageOverlayViewProvider = nil
                touchView.onPencilDoubleTap = nil
                touchView.onPencilShortcutAction = nil
                touchView.cancelPencilShortcutPalette()
            }
            for overlay in pencilPageOverlays.allObjects {
                overlay.cancelInteraction()
            }
            pencilPageOverlays.removeAllObjects()
            #endif
            removeSidenoteHighlights()
            clearNoteNavigationHighlight()
            clearSelectionAssistantHistoryAnnotations()
            clearCitationMarkAnnotations()
            if let pdfView {
                NotificationCenter.default.removeObserver(
                    self,
                    name: Notification.Name.PDFViewPageChanged,
                    object: pdfView
                )
                NotificationCenter.default.removeObserver(
                    self,
                    name: Notification.Name.PDFViewSelectionChanged,
                    object: pdfView
                )
                #if os(iOS)
                NotificationCenter.default.removeObserver(
                    self,
                    name: Notification.Name.PDFViewScaleChanged,
                    object: pdfView
                )
                #endif
            }
            if let registeredAnnotationAttachmentID, let registeredAnnotationSession {
                Task { @MainActor [weak self, weak registeredAnnotationSession] in
                    guard let self, let registeredAnnotationSession else { return }
                    registeredAnnotationSession.unregister(
                        self,
                        for: registeredAnnotationAttachmentID
                    )
                }
            }
            registeredAnnotationAttachmentID = nil
            registeredAnnotationSession = nil
            pendingDocumentPageCount = nil
            pendingDocumentPageCountForce = false
            isDocumentPageCountUpdateScheduled = false
            onDocumentPageCountChanged = nil
            self.pdfView = nil
        }

        /// Resolves margin-note anchors to page rects and keeps the rail's
        /// positions in step with scrolling, zooming, and resizing.
        func applySidenoteAnchors(
            _ anchors: [PDFSidenoteAnchor],
            layout: PDFSidenoteLayoutModel?,
            documentReloaded: Bool,
            in pdfView: PDFView
        ) {
            guard documentReloaded || sidenoteLayout !== layout || anchors != sidenoteAnchors else { return }
            if documentReloaded {
                sidenotePageTexts = [:]
            }
            sidenoteAnchors = anchors
            if sidenoteLayout !== layout {
                sidenoteLayout?.onActiveNoteChanged = nil
                layout?.onActiveNoteChanged = { [weak self] noteID in
                    self?.emphasizeSidenoteHighlight(noteID)
                }
            }
            sidenoteLayout = layout
            resolveSidenoteAnchors(in: pdfView)
            #if os(macOS)
            observeSidenoteGeometry(of: pdfView)
            #endif
            scheduleSidenotePositionUpdate()
        }

        private func resolveSidenoteAnchors(in pdfView: PDFView) {
            sidenotePageRects = [:]
            removeSidenoteHighlights()
            guard sidenoteLayout != nil, let document = pdfView.document else { return }
            for anchor in sidenoteAnchors {
                let resolution = PDFSidenoteAnchorResolver.resolve(anchor, in: document) { pageIndex in
                    sidenotePageText(at: pageIndex, in: document)
                }
                guard let resolution, let page = document.page(at: anchor.pageIndex) else { continue }
                sidenotePageRects[anchor.id] = (anchor.pageIndex, resolution.anchorRect)
                sidenoteHighlightAnnotations[anchor.id] = resolution.quoteLineRects.map { rect in
                    let annotation = PDFAnnotation(bounds: rect, forType: .highlight, withProperties: nil)
                    annotation.color = sidenoteHighlightColor(isActive: false)
                    page.addAnnotation(annotation)
                    return annotation
                }
            }
            emphasizeSidenoteHighlight(sidenoteLayout?.activeNoteID)
        }

        /// Note highlights are in-memory annotations, like the selection
        /// assistant's history underlines: annotation export reopens the PDF
        /// from disk and erasing only touches user annotation records.
        private func removeSidenoteHighlights() {
            for annotation in sidenoteHighlightAnnotations.values.joined() {
                annotation.page?.removeAnnotation(annotation)
            }
            sidenoteHighlightAnnotations = [:]
        }

        private func emphasizeSidenoteHighlight(_ activeNoteID: UUID?) {
            for (noteID, annotations) in sidenoteHighlightAnnotations {
                let color = sidenoteHighlightColor(isActive: noteID == activeNoteID)
                for annotation in annotations where annotation.color != color {
                    annotation.color = color
                }
            }
        }

        private func sidenoteHighlightColor(isActive: Bool) -> PlatformPDFColor {
            let alpha: CGFloat = isActive ? 0.55 : 0.28
            #if os(macOS)
            return NSColor(srgbRed: 0.90, green: 0.67, blue: 0.24, alpha: alpha)
            #else
            return UIColor(red: 0.90, green: 0.67, blue: 0.24, alpha: alpha)
            #endif
        }

        private func flashSidenote(on page: PDFPage, at point: CGPoint) {
            guard let layout = sidenoteLayout else { return }
            let hit = sidenoteHighlightAnnotations.first { _, annotations in
                annotations.contains { $0.page === page && $0.bounds.insetBy(dx: -2, dy: -2).contains(point) }
            }
            if let noteID = hit?.key {
                layout.flash(noteID)
            }
        }

        private func sidenotePageText(at pageIndex: Int, in document: PDFDocument) -> String? {
            if let cached = sidenotePageTexts[pageIndex] {
                return cached
            }
            let text = document.page(at: pageIndex)?.string
            sidenotePageTexts[pageIndex] = text ?? ""
            return text
        }

        private func scheduleSidenotePositionUpdate() {
            guard isSidenotePositionUpdateScheduled == false else { return }
            isSidenotePositionUpdateScheduled = true
            // Run after the current view update or scroll event, before the next
            // frame, so the rail moves together with the pages.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isSidenotePositionUpdateScheduled = false
                self.updateSidenotePositions()
            }
        }

        private func updateSidenotePositions() {
            guard let layout = sidenoteLayout else { return }
            guard let pdfView, let document = pdfView.document else {
                layout.update(anchorTops: [:])
                return
            }
            var tops: [UUID: CGFloat] = [:]
            for (id, anchor) in sidenotePageRects {
                guard let page = document.page(at: anchor.pageIndex) else { continue }
                let viewRect = pdfView.convert(anchor.rect, from: page)
                #if os(macOS)
                tops[id] = pdfView.isFlipped ? viewRect.minY : pdfView.bounds.height - viewRect.maxY
                #else
                tops[id] = viewRect.minY
                #endif
            }
            layout.update(anchorTops: tops)
        }

        #if os(macOS)
        private func observeSidenoteGeometry(of pdfView: PDFView) {
            guard let layout = sidenoteLayout,
                  let scrollView = pdfView.subviews.lazy.compactMap({ $0 as? NSScrollView }).first else {
                stopObservingSidenoteGeometry()
                return
            }
            layout.scrollView = scrollView
            guard observedSidenoteScrollView !== scrollView else { return }
            stopObservingSidenoteGeometry()
            observedSidenoteScrollView = scrollView
            scrollView.contentView.postsBoundsChangedNotifications = true
            let center = NotificationCenter.default
            let selector = #selector(handleSidenoteGeometryChanged(_:))
            center.addObserver(self, selector: selector, name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
            center.addObserver(self, selector: selector, name: NSView.frameDidChangeNotification, object: scrollView.contentView)
            center.addObserver(self, selector: selector, name: Notification.Name.PDFViewScaleChanged, object: pdfView)
            center.addObserver(self, selector: selector, name: Notification.Name.PDFViewDocumentChanged, object: pdfView)
        }

        private func stopObservingSidenoteGeometry() {
            let center = NotificationCenter.default
            if let contentView = observedSidenoteScrollView?.contentView {
                center.removeObserver(self, name: NSView.boundsDidChangeNotification, object: contentView)
                center.removeObserver(self, name: NSView.frameDidChangeNotification, object: contentView)
            }
            if let pdfView {
                center.removeObserver(self, name: Notification.Name.PDFViewScaleChanged, object: pdfView)
                center.removeObserver(self, name: Notification.Name.PDFViewDocumentChanged, object: pdfView)
            }
            observedSidenoteScrollView = nil
        }

        @objc private func handleSidenoteGeometryChanged(_ notification: Notification) {
            scheduleSidenotePositionUpdate()
        }
        #endif

        func applyNoteNavigationIfNeeded(
            _ request: NoteNavigationRequest?,
            in pdfView: PDFView
        ) {
            guard let request,
                  request.id != lastAppliedNoteNavigationID,
                  request.attachmentID == nil || request.attachmentID == attachmentID,
                  let pageIndex = request.pageIndex,
                  let document = pdfView.document,
                  document.pageCount > 0
            else {
                return
            }

            lastAppliedNoteNavigationID = request.id
            clearNoteNavigationHighlight()

            let targetPageIndex = min(max(0, pageIndex), document.pageCount - 1)
            guard let page = document.page(at: targetPageIndex) else { return }
            defer { leadScrollSync() }

            if let fraction = request.outlineFraction {
                let bounds = page.bounds(for: .cropBox)
                pdfView.go(to: PDFDestination(page: page, at: CGPoint(x: bounds.minX, y: bounds.maxY - bounds.height * min(max(fraction, 0), 1))))
                return
            }
            guard let quote = request.quote,
                  let pageText = page.string,
                  let range = PDFNoteNavigationTextMatcher.range(of: quote, in: pageText),
                  let selection = page.selection(for: range)
            else {
                if pdfView.currentPage != page {
                    pdfView.go(to: page)
                }
                return
            }

            pdfView.go(to: selection)
            noteNavigationHighlightAnnotations = selection.selectionsByLine().compactMap { line in
                let bounds = line.bounds(for: page).intersection(page.bounds(for: .cropBox))
                guard bounds.isNull == false, bounds.width > 0, bounds.height > 0 else {
                    return nil
                }
                let annotation = PDFAnnotation(
                    bounds: bounds,
                    forType: .highlight,
                    withProperties: nil
                )
                #if os(macOS)
                let highlightColor = NSColor.systemYellow.withAlphaComponent(0.55)
                #else
                let highlightColor = UIColor.systemYellow.withAlphaComponent(0.55)
                #endif
                annotation.color = highlightColor
                page.addAnnotation(annotation)
                return annotation
            }

            noteNavigationHighlightTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(1_400))
                guard Task.isCancelled == false else { return }
                self?.clearNoteNavigationHighlight()
            }
        }

        private struct FindDocumentKey: Equatable {
            var url: URL
            var generation: Int
        }

        func invalidateFindDocument(in pdfView: PDFView, keepingPosition: Bool) {
            findDocumentGeneration += 1
            findTextLoadTask?.cancel()
            findTextLoadTask = nil
            findTextLoadingKey = nil
            findPageTexts = nil
            findPageTextsKey = nil
            findMatches = []
            pdfView.highlightedSelections = nil
            // Keep the current match position when the same search is re-run on
            // the reloaded document (e.g. a translated PDF that grew by a batch);
            // a different document starts a fresh search from the visible page.
            if keepingPosition == false {
                appliedFindRequest = nil
                currentFindMatchIndex = nil
            }
            findResultsNeedRefresh = appliedFindRequest != nil
        }

        func applyFindRequest(_ request: DocumentFindRequest?, in pdfView: PDFView) {
            latestFindRequest = request
            guard let request,
                  DocumentSearchQuery(request.query).isEmpty == false,
                  let url = loadedURL
            else {
                clearFind(in: pdfView)
                return
            }
            guard let document = pdfView.document else {
                publishFindStatus(DocumentFindStatus(
                    query: request.query,
                    options: request.options,
                    matchCount: 0,
                    currentIndex: nil,
                    isSearching: false
                ))
                return
            }

            let key = FindDocumentKey(url: url, generation: findDocumentGeneration)
            guard let pageTexts = findPageTexts, findPageTextsKey == key else {
                loadFindPageTexts(for: key)
                publishFindStatus(.searching(request))
                return
            }

            let isNewSearch = findResultsNeedRefresh ||
                appliedFindRequest?.query != request.query ||
                appliedFindRequest?.options != request.options
            if isNewSearch {
                let isRefresh = findResultsNeedRefresh &&
                    appliedFindRequest?.query == request.query &&
                    appliedFindRequest?.options == request.options
                let previousIndex = currentFindMatchIndex
                findResultsNeedRefresh = false
                findMatches = Self.findMatches(for: request, pageTexts: pageTexts, in: document)
                appliedFindRequest = request

                if findMatches.isEmpty {
                    currentFindMatchIndex = nil
                } else if isRefresh {
                    currentFindMatchIndex = min(previousIndex ?? 0, findMatches.count - 1)
                } else {
                    let visiblePageIndex = pdfView.currentPage.map { document.index(for: $0) } ?? 0
                    currentFindMatchIndex = findMatches.firstIndex { $0.pageIndex >= visiblePageIndex } ?? 0
                    revealCurrentFindMatch(in: pdfView)
                }
            } else if appliedFindRequest?.navigationToken != request.navigationToken {
                appliedFindRequest = request
                guard findMatches.isEmpty == false else { return }
                let step = request.navigationDirection == .forward ? 1 : -1
                let current = currentFindMatchIndex ?? (step > 0 ? -1 : 0)
                currentFindMatchIndex = (current + step + findMatches.count) % findMatches.count
                revealCurrentFindMatch(in: pdfView)
            } else {
                return
            }

            renderFindHighlights(in: pdfView)
            publishFindStatus(DocumentFindStatus(
                query: request.query,
                options: request.options,
                matchCount: findMatches.count,
                currentIndex: currentFindMatchIndex,
                isSearching: false
            ))
        }

        private static func findMatches(
            for request: DocumentFindRequest,
            pageTexts: [DocumentSearchText],
            in document: PDFDocument
        ) -> [(pageIndex: Int, selection: PDFSelection)] {
            let query = DocumentSearchQuery(request.query)
            var matches: [(pageIndex: Int, selection: PDFSelection)] = []
            for (pageIndex, pageText) in pageTexts.enumerated() where pageIndex < document.pageCount {
                let pageMatches = pageText.matches(of: query, options: request.options)
                guard pageMatches.isEmpty == false, let page = document.page(at: pageIndex) else { continue }
                for match in pageMatches {
                    if let selection = page.selection(for: match.sourceRange) {
                        matches.append((pageIndex, selection))
                    }
                }
            }
            return matches
        }

        private func loadFindPageTexts(for key: FindDocumentKey) {
            guard findTextLoadingKey != key else { return }
            findTextLoadTask?.cancel()
            findTextLoadingKey = key
            findTextLoadTask = Task { @MainActor [weak self] in
                let pageTexts = await PDFDocumentSearchTextLoader.loadPages(from: key.url)
                guard let self, Task.isCancelled == false, self.findTextLoadingKey == key else { return }
                self.findTextLoadTask = nil
                self.findTextLoadingKey = nil
                self.findPageTexts = pageTexts ?? []
                self.findPageTextsKey = key
                if let pdfView = self.pdfView {
                    self.applyFindRequest(self.latestFindRequest, in: pdfView)
                }
            }
        }

        private func clearFind(in pdfView: PDFView) {
            guard appliedFindRequest != nil || findMatches.isEmpty == false ||
                pdfView.highlightedSelections != nil
            else {
                return
            }
            findMatches = []
            appliedFindRequest = nil
            currentFindMatchIndex = nil
            findResultsNeedRefresh = false
            lastPublishedFindStatus = nil
            pdfView.highlightedSelections = nil
        }

        private func revealCurrentFindMatch(in pdfView: PDFView) {
            guard let currentFindMatchIndex, findMatches.indices.contains(currentFindMatchIndex) else { return }
            pdfView.go(to: findMatches[currentFindMatchIndex].selection)
            leadScrollSync()
            scheduleCurrentPageIndexUpdate()
        }

        private func renderFindHighlights(in pdfView: PDFView) {
            guard findMatches.isEmpty == false else {
                pdfView.highlightedSelections = nil
                return
            }
            for (index, match) in findMatches.enumerated() {
                match.selection.color = index == currentFindMatchIndex
                    ? PlatformPDFColor.systemOrange.withAlphaComponent(0.7)
                    : PlatformPDFColor.systemYellow.withAlphaComponent(0.45)
            }
            pdfView.highlightedSelections = findMatches.map(\.selection)
        }

        private func publishFindStatus(_ status: DocumentFindStatus) {
            guard lastPublishedFindStatus != status else { return }
            lastPublishedFindStatus = status
            // Defer so SwiftUI state is not mutated during a view update.
            Task { @MainActor [weak self] in
                self?.onFindStatusChanged?(status)
            }
        }

        private func clearNoteNavigationHighlight() {
            noteNavigationHighlightTask?.cancel()
            noteNavigationHighlightTask = nil
            for annotation in noteNavigationHighlightAnnotations {
                annotation.page?.removeAnnotation(annotation)
            }
            noteNavigationHighlightAnnotations = []
        }

        func applySelectionAssistantHistoryAnchors(
            _ anchors: [SelectionAssistantHistoryAnchor],
            in pdfView: PDFView,
            force: Bool = false
        ) {
            guard force || anchors != receivedSelectionAssistantHistoryAnchors else { return }
            let matchingAnchors = anchors.filter {
                $0.attachmentID == nil || $0.attachmentID == attachmentID
            }
            if !force, matchingAnchors == appliedSelectionAssistantHistoryAnchors {
                receivedSelectionAssistantHistoryAnchors = anchors
                return
            }

            clearSelectionAssistantHistoryAnnotations()
            receivedSelectionAssistantHistoryAnchors = anchors
            appliedSelectionAssistantHistoryAnchors = matchingAnchors
            scheduleSelectionAssistantHistoryRendering(in: pdfView)
        }

        private func scheduleSelectionAssistantHistoryRendering(in pdfView: PDFView) {
            selectionAssistantHistoryRenderTask?.cancel()
            guard !appliedSelectionAssistantHistoryAnchors.isEmpty else { return }

            selectionAssistantHistoryRenderTask = Task { @MainActor [weak self, weak pdfView] in
                do {
                    try await Task.sleep(for: .milliseconds(120))
                } catch {
                    return
                }
                guard Task.isCancelled == false, let self, let pdfView else { return }
                self.renderSelectionAssistantHistoryAnchorsNearCurrentPage(in: pdfView)
                self.selectionAssistantHistoryRenderTask = nil
            }
        }

        private func renderSelectionAssistantHistoryAnchorsNearCurrentPage(in pdfView: PDFView) {
            guard let document = pdfView.document,
                  document.pageCount > 0,
                  let currentPage = pdfView.currentPage else {
                return
            }
            let currentPageIndex = document.index(for: currentPage)
            guard currentPageIndex != NSNotFound else { return }
            let nearbyPageIndexes = max(0, currentPageIndex - 1)...min(
                document.pageCount - 1,
                currentPageIndex + 1
            )

            for anchor in appliedSelectionAssistantHistoryAnchors {
                guard let pageIndex = anchor.pageIndex,
                      renderedSelectionAssistantHistoryAnchorIDs.contains(anchor.id) == false else {
                    continue
                }
                let clampedPageIndex = min(max(0, pageIndex), document.pageCount - 1)
                guard nearbyPageIndexes.contains(clampedPageIndex),
                      let passage = Self.passageLineBounds(of: anchor.quote, onPageAt: clampedPageIndex, in: document) else {
                    continue
                }
                for bounds in passage.lines {
                    let annotation = Self.underline(bounds, color: selectionAssistantHistoryColor, lineWidth: 1)
                    passage.page.addAnnotation(annotation)
                    selectionAssistantHistoryAnnotations.append((anchor, annotation))
                }
                renderedSelectionAssistantHistoryAnchorIDs.insert(anchor.id)
            }
        }

        /// The line rects of `quote` on a page, for in-memory underlines.
        static func passageLineBounds(
            of quote: String,
            onPageAt pageIndex: Int,
            in document: PDFDocument
        ) -> (page: PDFPage, lines: [CGRect])? {
            guard let page = document.page(at: pageIndex),
                  let pageText = page.string,
                  let range = PDFNoteNavigationTextMatcher.range(of: quote, in: pageText),
                  let selection = page.selection(for: range) else {
                return nil
            }
            let lineSelections = selection.selectionsByLine()
            let lines = (lineSelections.isEmpty ? [selection] : lineSelections).compactMap { line -> CGRect? in
                let bounds = line.bounds(for: page)
                    .intersection(page.bounds(for: .cropBox))
                    .standardized
                return bounds.isNull || bounds.width <= 0 || bounds.height <= 0 ? nil : bounds
            }
            return lines.isEmpty ? nil : (page, lines)
        }

        private static func underline(_ bounds: CGRect, color: PlatformPDFColor, lineWidth: CGFloat) -> PDFAnnotation {
            let annotation = PDFAnnotation(bounds: bounds, forType: .underline, withProperties: nil)
            annotation.color = color
            let border = PDFBorder()
            border.lineWidth = lineWidth
            annotation.border = border
            return annotation
        }

        // MARK: Citation marks

        /// Underlines passages cited in writings, like the assistant history: in-memory
        /// annotations on the pages around the current one.
        func applyCitationMarks(_ marks: [WritingCitationMark], in pdfView: PDFView, force: Bool = false) {
            let matchingMarks = marks.filter { mark in
                mark.record.pageIndex != nil
                    && (mark.record.attachmentID == nil || mark.record.attachmentID == attachmentID)
            }
            guard force || matchingMarks != appliedCitationMarks else { return }
            clearCitationMarkAnnotations()
            appliedCitationMarks = matchingMarks
            scheduleCitationMarkRendering(in: pdfView)
        }

        private func scheduleCitationMarkRendering(in pdfView: PDFView) {
            citationMarkRenderTask?.cancel()
            guard appliedCitationMarks.isEmpty == false else { return }
            citationMarkRenderTask = Task { @MainActor [weak self, weak pdfView] in
                do {
                    try await Task.sleep(for: .milliseconds(120))
                } catch {
                    return
                }
                guard Task.isCancelled == false, let self, let pdfView else { return }
                self.renderCitationMarksNearCurrentPage(in: pdfView)
                self.citationMarkRenderTask = nil
            }
        }

        private func renderCitationMarksNearCurrentPage(in pdfView: PDFView) {
            guard let document = pdfView.document,
                  document.pageCount > 0,
                  let currentPage = pdfView.currentPage else {
                return
            }
            let currentPageIndex = document.index(for: currentPage)
            guard currentPageIndex != NSNotFound else { return }
            let nearbyPageIndexes = max(0, currentPageIndex - 1)...min(document.pageCount - 1, currentPageIndex + 1)

            for mark in appliedCitationMarks {
                guard let pageIndex = mark.record.pageIndex,
                      renderedCitationMarkIDs.contains(mark.id) == false else {
                    continue
                }
                let clampedPageIndex = min(max(0, pageIndex), document.pageCount - 1)
                guard nearbyPageIndexes.contains(clampedPageIndex) else { continue }
                // A passage that runs onto the next page is only found by its start.
                let candidates = [mark.record.markedText, mark.record.quotePrefix].compactMap { $0 }
                guard let passage = candidates.lazy.compactMap({
                    Self.passageLineBounds(of: $0, onPageAt: clampedPageIndex, in: document)
                }).first else {
                    continue
                }
                for bounds in passage.lines {
                    let annotation = Self.underline(bounds, color: Self.citationMarkColor, lineWidth: 1.5)
                    passage.page.addAnnotation(annotation)
                    citationMarkAnnotations.append((mark.id, annotation))
                }
                renderedCitationMarkIDs.insert(mark.id)
            }
        }

        func clearCitationMarkAnnotations() {
            citationMarkRenderTask?.cancel()
            citationMarkRenderTask = nil
            for (_, annotation) in citationMarkAnnotations {
                annotation.page?.removeAnnotation(annotation)
            }
            citationMarkAnnotations = []
            appliedCitationMarks = []
            renderedCitationMarkIDs = []
        }

        fileprivate static var citationMarkColor: PlatformPDFColor {
            #if os(macOS)
            NSColor(srgbRed: 0.49, green: 0.36, blue: 0.84, alpha: 0.62)
            #else
            UIColor(red: 0.49, green: 0.36, blue: 0.84, alpha: 0.62)
            #endif
        }

        /// The citation marks under a click, most recently rendered last.
        func citationMarkIDs(on page: PDFPage, at point: CGPoint) -> [String] {
            var ids: [String] = []
            for (markID, annotation) in citationMarkAnnotations
            where annotation.page === page && annotation.bounds.insetBy(dx: -2, dy: -2).contains(point) {
                if ids.contains(markID) == false {
                    ids.append(markID)
                }
            }
            return ids
        }

        private func handleCitationMarkClick(on page: PDFPage, at point: CGPoint) {
            let ids = citationMarkIDs(on: page, at: point)
            guard ids.isEmpty == false else { return }
            onCitationMarksActivated?(ids)
        }

        func clearSelectionAssistantHistoryAnnotations() {
            selectionAssistantHistoryRenderTask?.cancel()
            selectionAssistantHistoryRenderTask = nil
            for (_, annotation) in selectionAssistantHistoryAnnotations {
                annotation.page?.removeAnnotation(annotation)
            }
            selectionAssistantHistoryAnnotations = []
            receivedSelectionAssistantHistoryAnchors = []
            appliedSelectionAssistantHistoryAnchors = []
            renderedSelectionAssistantHistoryAnchorIDs = []
        }

        private var selectionAssistantHistoryColor: PlatformPDFColor {
            #if os(macOS)
            let color = NSColor.systemBlue.withAlphaComponent(0.58)
            #else
            let color = UIColor.systemBlue.withAlphaComponent(0.58)
            #endif
            return color
        }

        private func handleSelectionAssistantHistoryClick(
            on page: PDFPage,
            at point: CGPoint
        ) -> Bool {
            guard let match = selectionAssistantHistoryAnnotations.first(where: { _, annotation in
                annotation.page === page && annotation.bounds.insetBy(dx: -4, dy: -4).contains(point)
            }) else { return false }

            let anchor = match.0
            onNoteSelectionChanged?(NoteSelectionContext(
                attachmentID: anchor.attachmentID ?? attachmentID,
                quote: anchor.quote,
                pageIndex: anchor.pageIndex
            ))
            return true
        }

        func handleLinkActivation(_ url: URL) -> Bool {
            guard ArxivLinkImportRequest(url: url) != nil,
                  let onArxivLinkActivated
            else {
                return false
            }

            onArxivLinkActivated(url)
            return true
        }

        func loadAnnotations(in pdfView: PDFView) {
            renderedAnnotations = [:]
            guard let paperID, let attachmentID else {
                annotationRecords = []
                publishAnnotationCapabilities()
                return
            }

            do {
                annotationRecords = try annotationStore.load(
                    paperID: paperID,
                    attachmentID: attachmentID
                )
                rebuildRenderedAnnotations(in: pdfView)
            } catch {
                annotationRecords = []
                reportAnnotationError(error)
            }
            publishAnnotationCapabilities()
        }

        func applyTextMarkup(_ kind: PDFTextMarkupKind, preset: PDFAnnotationColorPreset) {
            guard let pdfView,
                  let document = pdfView.document,
                  let selection = pdfView.currentSelection
            else {
                return
            }

            activateAnnotationDocument()
            let lineSelections = selection.selectionsByLine()
            let selections = lineSelections.isEmpty ? [selection] : lineSelections
            let records = selections.compactMap { line -> PDFAnnotationRecord? in
                guard let page = line.pages.first else { return nil }
                let pageIndex = document.index(for: page)
                guard pageIndex != NSNotFound else { return nil }
                let bounds = line.bounds(for: page)
                    .intersection(page.bounds(for: .cropBox))
                    .standardized
                guard bounds.width >= 1, bounds.height >= 1 else { return nil }
                let quote = line.string?
                    .components(separatedBy: .whitespacesAndNewlines)
                    .filter { $0.isEmpty == false }
                    .joined(separator: " ")
                return PDFAnnotationRecord(
                    pageIndex: pageIndex,
                    kind: kind.annotationKind,
                    bounds: bounds,
                    color: preset.color(for: kind.annotationKind),
                    quote: quote
                )
            }
            addAnnotationRecords(records)
        }

        func addTextNote(
            pageIndex: Int,
            point: CGPoint,
            contents: String,
            preset: PDFAnnotationColorPreset
        ) {
            guard let document = pdfView?.document,
                  let page = document.page(at: pageIndex)
            else {
                return
            }
            let pageBounds = page.bounds(for: .cropBox)
            let iconSize: CGFloat = 24
            let proposedBounds = CGRect(
                x: point.x - iconSize / 2,
                y: point.y - iconSize / 2,
                width: iconSize,
                height: iconSize
            )
            let origin = CGPoint(
                x: min(max(proposedBounds.minX, pageBounds.minX), max(pageBounds.maxX - iconSize, pageBounds.minX)),
                y: min(max(proposedBounds.minY, pageBounds.minY), max(pageBounds.maxY - iconSize, pageBounds.minY))
            )
            addAnnotationRecords([
                PDFAnnotationRecord(
                    pageIndex: pageIndex,
                    kind: .text,
                    bounds: CGRect(origin: origin, size: CGSize(width: iconSize, height: iconSize)),
                    color: preset.color(for: .text),
                    contents: contents
                )
            ])
        }

        func undoPDFAnnotation() {
            guard let history = undoAnnotationHistory.popLast() else { return }
            do {
                switch history {
                case .add(let records):
                    try replaceAnnotationRecords(
                        annotationRecords.filter { record in
                            records.contains(where: { $0.id == record.id }) == false
                        }
                    )
                case .remove(let records):
                    try replaceAnnotationRecords(merging: records)
                }
                redoAnnotationHistory.append(history)
            } catch {
                undoAnnotationHistory.append(history)
                reportAnnotationError(error)
            }
            publishAnnotationCapabilities()
        }

        func redoPDFAnnotation() {
            guard let history = redoAnnotationHistory.popLast() else { return }
            do {
                switch history {
                case .add(let records):
                    try replaceAnnotationRecords(merging: records)
                case .remove(let records):
                    try replaceAnnotationRecords(
                        annotationRecords.filter { record in
                            records.contains(where: { $0.id == record.id }) == false
                        }
                    )
                }
                undoAnnotationHistory.append(history)
            } catch {
                redoAnnotationHistory.append(history)
                reportAnnotationError(error)
            }
            publishAnnotationCapabilities()
        }

        func zoomPDFIn() {
            zoomPDF(by: 1.2)
        }

        func zoomPDFOut() {
            zoomPDF(by: 1 / 1.2)
        }

        /// Like a pinch, a button zoom keeps its scale until the split divider is dragged near fit.
        private func zoomPDF(by factor: CGFloat) {
            guard let pdfView, pdfView.document != nil else { return }
            let minimumScale = max(pdfView.minScaleFactor, 0.01)
            let maximumScale = max(pdfView.maxScaleFactor, minimumScale)
            let nextScale = min(max(pdfView.scaleFactor * factor, minimumScale), maximumScale)
            guard abs(nextScale - pdfView.scaleFactor) > 0.0001 else { return }
            (pdfView as? PDFPreferredManualScaling)?.preferredManualScale = nil
            pdfView.autoScales = false
            pdfView.scaleFactor = nextScale
        }

        private func addInkAnnotation(on page: PDFPage, points: [CGPoint]) {
            guard let document = pdfView?.document,
                  points.count >= 2,
                  let session = annotationSession
            else {
                return
            }
            let pageIndex = document.index(for: page)
            guard pageIndex != NSNotFound else { return }
            let lineWidth = max(0.5, session.lineWidth)
            let rawBounds = points.reduce(CGRect.null) { partial, point in
                partial.union(CGRect(origin: point, size: .zero))
            }
            let bounds = rawBounds
                .insetBy(dx: -lineWidth, dy: -lineWidth)
                .intersection(page.bounds(for: .cropBox))
                .standardized
            guard bounds.width >= 1, bounds.height >= 1 else { return }
            addAnnotationRecords([
                PDFAnnotationRecord(
                    pageIndex: pageIndex,
                    kind: .ink,
                    bounds: bounds,
                    color: session.colorPreset.color(for: .ink),
                    lineWidth: lineWidth,
                    inkPaths: [points]
                )
            ])
        }

        #if os(iOS)
        private func addPressureInkAnnotation(
            on page: PDFPage,
            samples: [PDFAnnotationInkSample],
            basePageWidth: CGFloat
        ) {
            guard let document = pdfView?.document, samples.count >= 2 else { return }
            let pageIndex = document.index(for: page)
            guard pageIndex != NSNotFound else { return }

            let points = samples.map(\.cgPoint)
            let maximumWidth = CGFloat(samples.map(\.width).max() ?? Double(basePageWidth))
            let rawBounds = points.reduce(CGRect.null) { partial, point in
                partial.union(CGRect(origin: point, size: .zero))
            }
            let bounds = rawBounds
                .insetBy(dx: -maximumWidth / 2, dy: -maximumWidth / 2)
                .intersection(page.bounds(for: .cropBox))
                .standardized
            guard bounds.width >= 1, bounds.height >= 1 else { return }

            addAnnotationRecords([
                PDFAnnotationRecord(
                    pageIndex: pageIndex,
                    kind: .ink,
                    bounds: bounds,
                    color: annotationSession?.colorPreset.color(for: .ink)
                        ?? PDFAnnotationColorPreset.yellow.color(for: .ink),
                    lineWidth: Double(basePageWidth),
                    inkPaths: [points],
                    inkSamplePaths: [samples]
                )
            ])
        }
        #endif

        private func eraseAnnotation(on page: PDFPage, at point: CGPoint) {
            activateAnnotationDocument()
            let hitTolerance: CGFloat = 6
            let renderedRecord = page.annotations.reversed().compactMap { annotation -> PDFAnnotationRecord? in
                guard annotation.bounds.insetBy(dx: -hitTolerance, dy: -hitTolerance).contains(point),
                      let recordID = PDFAnnotationRenderer.recordID(for: annotation)
                else {
                    return nil
                }
                return annotationRecords.first { $0.id == recordID }
            }.first
            let pageIndex = pdfView?.document?.index(for: page) ?? NSNotFound
            let overlayInkRecord = annotationRecords.reversed().first { record in
                record.kind == .ink &&
                    pageIndex != NSNotFound &&
                    record.pageIndex == pageIndex &&
                    Self.inkRecord(record, contains: point, tolerance: hitTolerance)
            }
            guard let record = renderedRecord ?? overlayInkRecord else {
                return
            }
            removeAnnotationRecords([record])
        }

        private static func inkRecord(
            _ record: PDFAnnotationRecord,
            contains point: CGPoint,
            tolerance: CGFloat
        ) -> Bool {
            let hitDistance = tolerance + CGFloat(record.lineWidth) / 2
            guard record.bounds.cgRect.insetBy(dx: -hitDistance, dy: -hitDistance).contains(point) else {
                return false
            }
            if let samplePaths = record.inkSamplePaths, samplePaths.isEmpty == false {
                return samplePaths.contains { path in
                    guard let first = path.first else { return false }
                    if path.count == 1 {
                        return hypot(point.x - first.x, point.y - first.y)
                            <= tolerance + CGFloat(first.width) / 2
                    }
                    return zip(path, path.dropFirst()).contains { start, end in
                        let segmentTolerance = tolerance + CGFloat(max(start.width, end.width)) / 2
                        return distance(
                            from: point,
                            toSegmentFrom: start.cgPoint,
                            to: end.cgPoint
                        ) <= segmentTolerance
                    }
                }
            }
            return record.inkPaths.contains { path in
                let points = path.map(\.cgPoint)
                guard let first = points.first else { return false }
                if points.count == 1 {
                    return hypot(point.x - first.x, point.y - first.y) <= hitDistance
                }
                return zip(points, points.dropFirst()).contains { start, end in
                    distance(from: point, toSegmentFrom: start, to: end) <= hitDistance
                }
            }
        }

        private static func distance(
            from point: CGPoint,
            toSegmentFrom start: CGPoint,
            to end: CGPoint
        ) -> CGFloat {
            let dx = end.x - start.x
            let dy = end.y - start.y
            let squaredLength = dx * dx + dy * dy
            guard squaredLength > 0 else {
                return hypot(point.x - start.x, point.y - start.y)
            }
            let projection = ((point.x - start.x) * dx + (point.y - start.y) * dy) / squaredLength
            let t = min(max(projection, 0), 1)
            let closest = CGPoint(x: start.x + t * dx, y: start.y + t * dy)
            return hypot(point.x - closest.x, point.y - closest.y)
        }

        private func requestTextNote(on page: PDFPage, at point: CGPoint) {
            guard let document = pdfView?.document else { return }
            let requestedPageIndex = document.index(for: page)
            guard requestedPageIndex != NSNotFound else { return }
            activateAnnotationDocument()
            annotationSession?.requestTextNote(
                attachmentID: attachmentID,
                pageIndex: requestedPageIndex,
                point: point
            )
        }

        private func addAnnotationRecords(_ records: [PDFAnnotationRecord]) {
            guard records.isEmpty == false else { return }
            do {
                try replaceAnnotationRecords(merging: records)
                undoAnnotationHistory.append(.add(records))
                redoAnnotationHistory = []
            } catch {
                reportAnnotationError(error)
            }
            publishAnnotationCapabilities()
        }

        private func removeAnnotationRecords(_ records: [PDFAnnotationRecord]) {
            guard records.isEmpty == false else { return }
            do {
                try replaceAnnotationRecords(
                    annotationRecords.filter { record in
                        records.contains(where: { $0.id == record.id }) == false
                    }
                )
                undoAnnotationHistory.append(.remove(records))
                redoAnnotationHistory = []
            } catch {
                reportAnnotationError(error)
            }
            publishAnnotationCapabilities()
        }

        private func replaceAnnotationRecords(merging records: [PDFAnnotationRecord]) throws {
            let newIDs = Set(records.map(\.id))
            try replaceAnnotationRecords(
                annotationRecords.filter { newIDs.contains($0.id) == false } + records
            )
        }

        private func replaceAnnotationRecords(_ records: [PDFAnnotationRecord]) throws {
            guard let paperID, let attachmentID else { return }
            let sortedRecords = records.sorted { lhs, rhs in
                if lhs.createdAt == rhs.createdAt { return lhs.id.uuidString < rhs.id.uuidString }
                return lhs.createdAt < rhs.createdAt
            }
            try annotationStore.save(
                sortedRecords,
                paperID: paperID,
                attachmentID: attachmentID
            )
            annotationRecords = sortedRecords
            if let pdfView {
                rebuildRenderedAnnotations(in: pdfView)
            }
        }

        private func rebuildRenderedAnnotations(in pdfView: PDFView) {
            for annotation in renderedAnnotations.values {
                annotation.page?.removeAnnotation(annotation)
            }
            renderedAnnotations = [:]
            guard let document = pdfView.document else { return }
            for record in annotationRecords {
                #if os(iOS)
                // Keep iPad ink in the page overlay. Switching from the live
                // overlay to PDFKit's cached annotation renderer causes a
                // visible flash and a softer-looking stroke after Pencil-up.
                if record.kind == .ink { continue }
                #endif
                guard let page = document.page(at: record.pageIndex) else { continue }
                let annotation = PDFAnnotationRenderer.makeAnnotation(
                    from: record,
                    invertedColor: false
                )
                page.addAnnotation(annotation)
                renderedAnnotations[record.id] = annotation
            }
            #if os(iOS)
            refreshPencilInkOverlays(in: pdfView)
            #endif
        }

        private func activateAnnotationDocument() {
            annotationSession?.activate(attachmentID: attachmentID)
        }

        private func publishAnnotationCapabilities() {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.annotationSession?.handlerDidChange(self)
            }
        }

        private func reportAnnotationError(_ error: Error) {
            Task { @MainActor [weak annotationSession] in
                annotationSession?.report(error)
            }
        }

        func clearLoadedAnnotations() {
            clearSelectionAssistantHistoryAnnotations()
            annotationRecords = []
            renderedAnnotations = [:]
            undoAnnotationHistory = []
            redoAnnotationHistory = []
            #if os(iOS)
            if let pdfView {
                refreshPencilInkOverlays(in: pdfView)
            }
            #endif
            publishAnnotationCapabilities()
        }

        func observeOutlineGeometry(in view: PDFView) {
            guard onOutlineLocationChanged != nil else { return }
            func findScroll(_ view: PlatformOutlineView) -> PlatformOutlineScrollView? {
                if let scroll = view as? PlatformOutlineScrollView { return scroll }
                return view.subviews.lazy.compactMap { findScroll($0) }.first
            }
            guard let scroll = findScroll(view), outlineScrollView !== scroll else { return }
            outlineScrollView = scroll
            #if os(macOS)
            if let outlineGeometryNotification { NotificationCenter.default.removeObserver(outlineGeometryNotification) }
            // NSClipView scrolling posts bounds notifications but does not publish KVO
            // changes for `bounds`. Observe the same reliable signal as dual-PDF sync.
            scroll.contentView.postsBoundsChangedNotifications = true
            outlineGeometryNotification = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.scheduleCurrentPageIndexUpdate() }
            }
            #else
            outlineGeometryObservation = scroll.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.scheduleCurrentPageIndexUpdate() }
            }
            #endif
            scheduleCurrentPageIndexUpdate()
        }

        private func publishOutlineLocation() {
            guard let callback = onOutlineLocationChanged, let view = pdfView, let document = view.document else { return }
            #if os(macOS)
            // The original pane also reports while following a translated-side scroll;
            // this updates the outline without writing the shared page binding.
            let y = view.isFlipped ? view.bounds.minY + 100 : view.bounds.maxY - 100
            #else
            let y = view.bounds.minY + 100
            #endif
            let point = CGPoint(x: view.bounds.midX, y: y)
            guard let page = view.page(for: point, nearest: true) else { return }
            let index = document.index(for: page)
            guard index != NSNotFound else { return }
            let bounds = page.bounds(for: .cropBox)
            let pagePoint = view.convert(point, to: page)
            callback(index, Double(min(max((bounds.maxY - pagePoint.y) / max(1, bounds.height), 0), 1)))
        }

        func scheduleCurrentPageIndexUpdate() {
            guard !isPageIndexUpdateScheduled else { return }
            isPageIndexUpdateScheduled = true

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isPageIndexUpdateScheduled = false
                self.updateCurrentPageIndexIfNeeded()
                self.publishOutlineLocation()
            }
        }

        func scheduleDocumentPageCountUpdate(_ pageCount: Int, force: Bool = false) {
            pendingDocumentPageCount = max(0, pageCount)
            pendingDocumentPageCountForce = pendingDocumentPageCountForce || force
            guard !isDocumentPageCountUpdateScheduled else { return }
            isDocumentPageCountUpdateScheduled = true

            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self else { return }
                self.isDocumentPageCountUpdateScheduled = false
                guard let pageCount = self.pendingDocumentPageCount else { return }
                let force = self.pendingDocumentPageCountForce
                self.pendingDocumentPageCount = nil
                self.pendingDocumentPageCountForce = false
                guard force || self.lastPublishedDocumentPageCount != pageCount else { return }
                self.lastPublishedDocumentPageCount = pageCount
                self.onDocumentPageCountChanged?(pageCount)
            }
        }

        func shouldRestorePageIndex(_ requestedPageIndex: Int, in pdfView: PDFView) -> Bool {
            guard let document = pdfView.document, document.pageCount > 0 else { return false }
            let targetPageIndex = min(max(0, requestedPageIndex), document.pageCount - 1)
            guard let currentPage = pdfView.currentPage else { return true }
            let currentPageIndex = document.index(for: currentPage)
            guard currentPageIndex == NSNotFound || currentPageIndex != targetPageIndex else { return false }
            // The other pane already shows the page; a jump to its top would undo the scroll sync.
            if isFollowingScrollSync, let targetPage = document.page(at: targetPageIndex),
               pdfView.visiblePages.contains(targetPage) {
                return false
            }
            return true
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
            #if os(iOS)
            (pdfView as? TouchPDFView)?.onInitialLayoutReady = nil
            #endif
        }

        func restoreReadingPosition(
            _ requestedPosition: PDFReadingPosition,
            in pdfView: PDFView,
            suppressIntermediateUpdates: Bool
        ) {
            #if os(iOS)
            if let touchView = pdfView as? TouchPDFView,
               let document = pdfView.document,
               touchView.window == nil || touchView.bounds.isEmpty {
                // PDFKit accepts go(to:) before it has a viewport, then discards that
                // position when it first fits the document. Keep page-zero callbacks
                // suppressed until the real layout can restore the requested page.
                let position = requestedPosition.clamped(pageCount: document.pageCount)
                pendingProgrammaticPosition = position
                touchView.onInitialLayoutReady = { [weak self, weak touchView, weak document] in
                    guard let self, let touchView, let document,
                          touchView.document === document else { return }
                    self.restoreReadingPosition(position, in: touchView, suppressIntermediateUpdates: true)
                }
                return
            }
            #endif
            withoutLeadingScrollSync {
                moveToReadingPosition(
                    requestedPosition,
                    in: pdfView,
                    suppressIntermediateUpdates: suppressIntermediateUpdates
                )
            }
        }

        private func moveToReadingPosition(
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
                let signpostID = OSSignpostID(log: Self.performanceLog)
                os_signpost(
                    .begin,
                    log: Self.performanceLog,
                    name: "PDF Programmatic Navigation",
                    signpostID: signpostID
                )
                pdfView.go(to: PDFDestination(page: page, at: point))
                os_signpost(
                    .end,
                    log: Self.performanceLog,
                    name: "PDF Programmatic Navigation",
                    signpostID: signpostID
                )
            } else if pdfView.currentPage != page {
                let signpostID = OSSignpostID(log: Self.performanceLog)
                os_signpost(
                    .begin,
                    log: Self.performanceLog,
                    name: "PDF Programmatic Navigation",
                    signpostID: signpostID
                )
                pdfView.go(to: page)
                os_signpost(
                    .end,
                    log: Self.performanceLog,
                    name: "PDF Programmatic Navigation",
                    signpostID: signpostID
                )
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

            withoutLeadingScrollSync {
                if let point = targetPosition.point {
                    pdfView.go(to: PDFDestination(page: page, at: point))
                } else if pdfView.currentPage != page {
                    pdfView.go(to: page)
                }
            }
        }

        func scheduleSelectionUpdate() {
            guard !isSelectionUpdateScheduled else { return }
            isSelectionUpdateScheduled = true

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isSelectionUpdateScheduled = false
                let selection = self.currentSelectionContext()
                if selection != nil {
                    self.activateAnnotationDocument()
                }
                self.publishSelection(selection)
                self.publishAnnotationCapabilities()
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

            guard !isFollowingScrollSync, currentIndex != pageIndex.wrappedValue else { return }
            pageIndex.wrappedValue = currentIndex
        }

        @objc
        private func handlePageChanged(_ notification: Notification) {
            os_signpost(.event, log: Self.performanceLog, name: "PDF Page Changed")
            scheduleCurrentPageIndexUpdate()
            if let pdfView {
                scheduleSelectionAssistantHistoryRendering(in: pdfView)
                scheduleCitationMarkRendering(in: pdfView)
            }
        }

        @objc
        private func handleSelectionChanged(_ notification: Notification) {
            scheduleSelectionUpdate()
        }

        #if os(iOS)
        @objc
        private func handlePencilScaleChanged(_ notification: Notification) {
            for overlay in pencilPageOverlays.allObjects {
                overlay.refreshVectorInk()
            }
        }
        #endif

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

            let contextStart = max(0, pageIndex - 1)
            let contextEnd = min(document.pageCount - 1, pageIndex + 1)
            let localContext = (contextStart...contextEnd)
                .compactMap { document.page(at: $0)?.string }
                .joined(separator: "\n\n")

            return NoteSelectionContext(
                attachmentID: attachmentID,
                quote: quote,
                pageIndex: pageIndex,
                localContext: String(localContext.prefix(8_000))
            )
        }
    }
}

#if os(iOS)
extension PDFReaderView.Coordinator: @preconcurrency PDFPageOverlayViewProvider {
    func pdfView(_ pdfView: PDFView, overlayViewFor page: PDFPage) -> UIView? {
        let overlay = PDFPencilPageOverlayView()
        overlay.bind(to: page, in: pdfView)
        pencilPageOverlays.add(overlay)
        configurePencilOverlay(
            overlay,
            with: appliedPencilInteractionConfiguration ?? PencilInteractionConfiguration(
                mode: .browse,
                colorPreset: .yellow,
                lineWidth: PDFAnnotationLineWidthPreset.defaultValue
            )
        )
        refreshPencilInk(on: overlay, for: page, in: pdfView)

        overlay.onInteractionBegan = { [weak self] in
            self?.activateAnnotationDocument()
        }
        overlay.onInkStrokeCompleted = { [weak self, weak overlay, weak pdfView, weak page] samples in
            guard let self, let overlay, let pdfView, let page else { return }
            let baseDisplayWidth = CGFloat(
                self.annotationSession?.lineWidth ?? PDFAnnotationLineWidthPreset.defaultValue
            )
            let pageSamples = samples.map { sample in
                return PDFAnnotationInkSample(
                    point: self.pencilPagePoint(
                        for: sample.point,
                        overlay: overlay,
                        pdfView: pdfView,
                        page: page
                    ),
                    width: self.pencilPageWidth(
                        at: sample.point,
                        displayWidth: PDFPencilInkDynamics.displayWidth(
                            baseWidth: baseDisplayWidth,
                            pressure: sample.pressure
                        ),
                        overlay: overlay,
                        pdfView: pdfView,
                        page: page
                    )
                )
            }
            let basePageWidth = samples.first.map {
                self.pencilPageWidth(
                    at: $0.point,
                    displayWidth: baseDisplayWidth,
                    overlay: overlay,
                    pdfView: pdfView,
                    page: page
                )
            } ?? baseDisplayWidth
            self.addPressureInkAnnotation(
                on: page,
                samples: pageSamples,
                basePageWidth: basePageWidth
            )
        }
        overlay.onEraseRequested = { [weak self, weak overlay, weak pdfView, weak page] point in
            guard let self, let overlay, let pdfView, let page else { return }
            let viewPoint = overlay.convert(point, to: pdfView)
            self.eraseAnnotation(on: page, at: pdfView.convert(viewPoint, to: page))
        }
        overlay.onTextNoteRequested = { [weak self, weak overlay, weak pdfView, weak page] point in
            guard let self, let overlay, let pdfView, let page else { return }
            let viewPoint = overlay.convert(point, to: pdfView)
            self.requestTextNote(on: page, at: pdfView.convert(viewPoint, to: page))
        }
        return overlay
    }

    func pdfView(
        _ pdfView: PDFView,
        willDisplayOverlayView overlayView: UIView,
        for page: PDFPage
    ) {
        guard let overlay = overlayView as? PDFPencilPageOverlayView else { return }
        overlay.bind(to: page, in: pdfView)
        refreshPencilInk(on: overlay, for: page, in: pdfView)
    }

    func pdfView(
        _ pdfView: PDFView,
        willEndDisplayingOverlayView overlayView: UIView,
        for page: PDFPage
    ) {
        guard let overlay = overlayView as? PDFPencilPageOverlayView else { return }
        overlay.cancelInteraction()
        pencilPageOverlays.remove(overlay)
    }
}
#endif

#if os(macOS)
@MainActor
private final class InteractivePDFView: PDFView, PDFPreferredManualScaling {
    var preferredManualScale: CGFloat?
    var interactionMode: PDFInteractionMode = .browse {
        didSet {
            guard oldValue != interactionMode else { return }
            cancelInteraction()
            window?.invalidateCursorRects(for: self)
        }
    }
    var handToolEnabled = false {
        didSet {
            guard oldValue != handToolEnabled else { return }
            if handToolEnabled == false {
                cancelHandPan()
            }
            installHandCursorTrackingArea()
            window?.invalidateCursorRects(for: self)
        }
    }
    var inkPreviewColor: NSColor = .systemYellow {
        didSet { interactionOverlay.inkColor = inkPreviewColor }
    }
    var inkPreviewLineWidth: CGFloat = 2 {
        didSet { interactionOverlay.inkLineWidth = inkPreviewLineWidth }
    }
    var onInteractionBegan: (() -> Void)?
    var onLinkActivated: ((URL) -> Bool)?
    var onBrowseClick: ((PDFPage, CGPoint) -> Bool)?
    /// A click that neither starts a double click nor selects text, reported once the
    /// double-click interval has passed.
    var onBrowseSingleClick: ((PDFPage, CGPoint) -> Void)?
    var onDebugRegionSelected: ((PDFDebugRegionSelection) -> Void)?
    var onInkStrokeCompleted: ((PDFPage, [CGPoint]) -> Void)?
    var onEraseRequested: ((PDFPage, CGPoint) -> Void)?
    var onTextNoteRequested: ((PDFPage, CGPoint) -> Void)?

    private let interactionOverlay = PDFInteractionOverlayView()
    private struct HandPan {
        var scrollView: NSScrollView
        var startLocationInWindow: CGPoint
        var startOrigin: CGPoint
        var didMove = false
    }

    private weak var interactionPage: PDFPage?
    private var interactionStartPoint: CGPoint?
    private var inkViewPoints: [CGPoint] = []
    private var suppressBrowseMouseSequence = false
    private var pendingSingleClick: Task<Void, Never>?
    private var handPan: HandPan?
    private var handCursorTrackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        installInteractionOverlay()
        observeLiveMagnify()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        installInteractionOverlay()
        observeLiveMagnify()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        switch interactionMode {
        case .browse:
            break
        case .ink, .textNote, .erase, .debugRegion:
            addCursorRect(bounds, cursor: .crosshair)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        installHandCursorTrackingArea()
    }

    /// Only the hand tool needs mouse moves: `cursorUpdate` is sent once on entering the view,
    /// while text, images and blank areas inside it want different cursors.
    private func installHandCursorTrackingArea() {
        if let handCursorTrackingArea {
            removeTrackingArea(handCursorTrackingArea)
            self.handCursorTrackingArea = nil
        }
        guard handToolEnabled else { return }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .cursorUpdate, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        handCursorTrackingArea = trackingArea
    }

    override func cursorUpdate(with event: NSEvent) {
        if updateHandCursor(with: event) { return }
        super.cursorUpdate(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        // PDFKit sets its own cursor on every move, so the hand is set again afterwards.
        _ = updateHandCursor(with: event)
    }

    private func updateHandCursor(with event: NSEvent) -> Bool {
        guard handToolEnabled else { return false }
        if handPan != nil {
            NSCursor.closedHand.set()
            return true
        }
        guard shouldBeginHandPan(at: convert(event.locationInWindow, from: nil), modifiers: event.modifierFlags) else {
            return false
        }
        NSCursor.openHand.set()
        return true
    }

    override func perform(_ action: PDFAction) {
        if let urlAction = action as? PDFActionURL,
           let url = urlAction.url,
           onLinkActivated?(url) == true {
            return
        }
        super.perform(action)
    }

    override func magnify(with event: NSEvent) {
        // Automatic scaling is useful when a narrower dual-pane reader first
        // opens, but it otherwise snaps a manual pinch zoom back to fit.
        autoScales = false
        preferredManualScale = nil
        super.magnify(with: event)
    }

    /// Pinch and smart zoom are handled by PDFKit's internal scroll view and never reach
    /// `magnify(with:)`. PDFKit turns `autoScales` off when they start, but no longer does once
    /// the document has been replaced (another paper, or a translation update reloading the
    /// file); the zoom then lasts only until the next layout fits the page again.
    private func observeLiveMagnify() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollViewWillStartLiveMagnify(_:)),
            name: NSScrollView.willStartLiveMagnifyNotification,
            object: nil
        )
    }

    @objc private func scrollViewWillStartLiveMagnify(_ notification: Notification) {
        guard let scrollView = notification.object as? NSView,
              scrollView.isDescendant(of: self) else {
            return
        }
        autoScales = false
        preferredManualScale = nil
    }

    override func layout() {
        super.layout()
        applyPreferredManualScale()
    }

    override func mouseDown(with event: NSEvent) {
        pendingSingleClick?.cancel()
        pendingSingleClick = nil
        if interactionMode == .browse {
            onInteractionBegan?()
            if event.type == .leftMouseDown {
                let viewPoint = convert(event.locationInWindow, from: nil)
                if let page = page(for: viewPoint, nearest: false) {
                    let pagePoint = convert(viewPoint, to: page)
                    if onBrowseClick?(page, pagePoint) == true {
                        suppressBrowseMouseSequence = true
                        return
                    }
                }
                if let page = page(for: viewPoint, nearest: false), event.clickCount == 1 {
                    scheduleSingleClick(on: page, at: convert(viewPoint, to: page))
                }
                if event.clickCount == 1,
                   shouldBeginHandPan(at: viewPoint, modifiers: event.modifierFlags),
                   beginHandPan(with: event) {
                    return
                }
            }
            super.mouseDown(with: event)
            return
        }

        guard event.type == .leftMouseDown else {
            onInteractionBegan?()
            super.mouseDown(with: event)
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        guard let page = page(for: point, nearest: false) else {
            cancelInteraction()
            return
        }
        onInteractionBegan?()

        switch interactionMode {
        case .browse:
            super.mouseDown(with: event)
        case .debugRegion:
            interactionPage = page
            interactionStartPoint = point
            interactionOverlay.selectionRect = .zero
        case .ink:
            interactionPage = page
            interactionStartPoint = point
            inkViewPoints = [point]
            interactionOverlay.inkPoints = inkViewPoints
        case .erase:
            requestErase(on: page, viewPoint: point)
        case .textNote:
            onTextNoteRequested?(page, convert(point, to: page))
        }
    }

    /// PDFView may track the mouse itself, so the click is judged after the double-click
    /// interval instead of on mouse up: the button is up and no text was selected.
    private func scheduleSingleClick(on page: PDFPage, at point: CGPoint) {
        guard onBrowseSingleClick != nil else { return }
        let delay = min(NSEvent.doubleClickInterval, 0.35)
        pendingSingleClick = Task { @MainActor [weak self, weak page] in
            try? await Task.sleep(for: .seconds(delay))
            guard Task.isCancelled == false, let self, let page else { return }
            self.pendingSingleClick = nil
            guard NSEvent.pressedMouseButtons & 1 == 0,
                  (self.currentSelection?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return
            }
            self.onBrowseSingleClick?(page, point)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if updateHandPan(with: event) {
            return
        }
        let currentPoint = convert(event.locationInWindow, from: nil)
        switch interactionMode {
        case .browse:
            if suppressBrowseMouseSequence { return }
            super.mouseDragged(with: event)
        case .debugRegion:
            guard let interactionStartPoint, interactionPage != nil else { return }
            interactionOverlay.selectionRect = viewRect(from: interactionStartPoint, to: currentPoint)
        case .ink:
            guard interactionPage != nil else { return }
            if let previous = inkViewPoints.last,
               hypot(currentPoint.x - previous.x, currentPoint.y - previous.y) < 1 {
                return
            }
            inkViewPoints.append(currentPoint)
            interactionOverlay.inkPoints = inkViewPoints
        case .erase:
            guard let page = page(for: currentPoint, nearest: false) else { return }
            requestErase(on: page, viewPoint: currentPoint)
        case .textNote:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        if let handPan {
            cancelHandPan()
            // PDFKit never saw this click, so a click without a drag clears the selection here.
            if handPan.didMove == false {
                clearSelection()
            }
            cursorUpdate(with: event)
            return
        }
        switch interactionMode {
        case .browse:
            if suppressBrowseMouseSequence {
                suppressBrowseMouseSequence = false
                return
            }
            super.mouseUp(with: event)
        case .debugRegion:
            finishDebugSelection(with: event)
        case .ink:
            finishInkStroke(with: event)
        case .erase, .textNote:
            cancelInteraction()
        }
    }

    private func finishDebugSelection(with event: NSEvent) {
        guard let interactionStartPoint,
              let interactionPage,
              let document
        else {
            cancelInteraction()
            return
        }

        let currentPoint = convert(event.locationInWindow, from: nil)
        let start = convert(interactionStartPoint, to: interactionPage)
        let end = convert(currentPoint, to: interactionPage)
        let pageBounds = interactionPage.bounds(for: .cropBox).standardized
        let selectedBounds = viewRect(from: start, to: end)
            .intersection(pageBounds)
            .standardized
        let selectedPageIndex = document.index(for: interactionPage)

        cancelInteraction()

        guard selectedPageIndex != NSNotFound,
              selectedBounds.width >= 4,
              selectedBounds.height >= 4
        else {
            return
        }

        onDebugRegionSelected?(
            PDFDebugRegionSelection(
                pageIndex: selectedPageIndex,
                pageBounds: pageBounds,
                selectedBounds: selectedBounds
            )
        )
    }

    private func finishInkStroke(with event: NSEvent) {
        guard let interactionPage else {
            cancelInteraction()
            return
        }
        let finalPoint = convert(event.locationInWindow, from: nil)
        if inkViewPoints.last != finalPoint {
            inkViewPoints.append(finalPoint)
        }
        let pageBounds = interactionPage.bounds(for: .cropBox)
        let pagePoints = inkViewPoints
            .map { convert($0, to: interactionPage) }
            .filter { pageBounds.insetBy(dx: -2, dy: -2).contains($0) }
        cancelInteraction()
        guard pagePoints.count >= 2 else { return }
        onInkStrokeCompleted?(interactionPage, pagePoints)
    }

    private func requestErase(on page: PDFPage, viewPoint: CGPoint) {
        onEraseRequested?(page, convert(viewPoint, to: page))
    }

    private func installInteractionOverlay() {
        interactionOverlay.frame = bounds
        interactionOverlay.autoresizingMask = [.width, .height]
        interactionOverlay.inkColor = inkPreviewColor
        interactionOverlay.inkLineWidth = inkPreviewLineWidth
        addSubview(interactionOverlay, positioned: .above, relativeTo: nil)
    }

    /// Modifier clicks, such as Shift to extend a selection, stay with PDFKit.
    private func shouldBeginHandPan(at viewPoint: CGPoint, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard handToolEnabled, interactionMode == .browse else { return false }
        guard modifiers.intersection([.shift, .command, .option, .control]).isEmpty else { return false }
        guard let page = page(for: viewPoint, nearest: false) else {
            return true
        }
        let pagePoint = convert(viewPoint, to: page)
        if let annotation = page.annotation(at: pagePoint), Self.isInteractive(annotation) {
            return false
        }
        if let selection = page.selectionForWord(at: pagePoint),
           let selectedText = selection.string?.trimmingCharacters(in: .whitespacesAndNewlines),
           selectedText.isEmpty == false {
            // PDFKit may return the nearest word even when the pointer is in page whitespace,
            // especially after zooming. Preserve text selection only over the word itself.
            let screenPointTolerance: CGFloat = 2
            let pagePointTolerance = screenPointTolerance / max(scaleFactor, 0.01)
            let textBounds = selection.bounds(for: page).insetBy(
                dx: -pagePointTolerance,
                dy: -pagePointTolerance
            )
            if textBounds.contains(pagePoint) {
                return false
            }
        }
        return true
    }

    /// Links, form fields and pop-up notes take the click. Markup, including the temporary
    /// underlines for citations, assistant history and note quotes, does not block a pan.
    private static func isInteractive(_ annotation: PDFAnnotation) -> Bool {
        switch annotation.type {
        case "Link", "Widget", "Text", "Popup":
            return true
        default:
            return annotation.action != nil
        }
    }

    private func beginHandPan(with event: NSEvent) -> Bool {
        guard let scrollView = subviews.lazy.compactMap({ $0 as? NSScrollView }).first else {
            return false
        }
        window?.makeFirstResponder(self)
        handPan = HandPan(
            scrollView: scrollView,
            startLocationInWindow: event.locationInWindow,
            startOrigin: scrollView.contentView.bounds.origin
        )
        // A pan is a live scroll, so a dual-pane reader follows it the same way it follows the
        // trackpad, even after the pointer leaves this pane.
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
        NSCursor.closedHand.set()
        return true
    }

    private func updateHandPan(with event: NSEvent) -> Bool {
        guard var handPan else { return false }
        let deltaX = event.locationInWindow.x - handPan.startLocationInWindow.x
        let deltaY = event.locationInWindow.y - handPan.startLocationInWindow.y
        if handPan.didMove == false {
            handPan.didMove = true
            self.handPan = handPan
            pendingSingleClick?.cancel()
            pendingSingleClick = nil
        }
        NSCursor.closedHand.set()
        let clipView = handPan.scrollView.contentView
        let proposedOrigin = CGPoint(
            x: handPan.startOrigin.x - deltaX,
            y: handPan.startOrigin.y - deltaY
        )
        let constrainedOrigin = clipView.constrainBoundsRect(
            CGRect(origin: proposedOrigin, size: clipView.bounds.size)
        ).origin
        clipView.scroll(to: constrainedOrigin)
        handPan.scrollView.reflectScrolledClipView(clipView)
        return true
    }

    private func cancelHandPan() {
        guard let handPan else { return }
        self.handPan = nil
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: handPan.scrollView)
        window?.invalidateCursorRects(for: self)
    }

    private func cancelInteraction() {
        cancelHandPan()
        suppressBrowseMouseSequence = false
        interactionStartPoint = nil
        interactionPage = nil
        inkViewPoints = []
        interactionOverlay.selectionRect = nil
        interactionOverlay.inkPoints = []
    }

    private func viewRect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }
}

@MainActor
private final class PDFInteractionOverlayView: NSView {
    var selectionRect: CGRect? {
        didSet { needsDisplay = true }
    }
    var inkPoints: [CGPoint] = [] {
        didSet { needsDisplay = true }
    }
    var inkColor: NSColor = .systemYellow {
        didSet { needsDisplay = true }
    }
    var inkLineWidth: CGFloat = 2 {
        didSet { needsDisplay = true }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if let selectionRect, selectionRect.isEmpty == false {
            NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
            selectionRect.fill()
            NSColor.controlAccentColor.withAlphaComponent(0.95).setStroke()
            let path = NSBezierPath(rect: selectionRect.insetBy(dx: 0.5, dy: 0.5))
            path.lineWidth = 2
            path.stroke()
        }

        guard let firstPoint = inkPoints.first, inkPoints.count > 1 else { return }
        let inkPath = NSBezierPath()
        inkPath.move(to: firstPoint)
        for point in inkPoints.dropFirst() {
            inkPath.line(to: point)
        }
        inkPath.lineCapStyle = .round
        inkPath.lineJoinStyle = .round
        inkPath.lineWidth = inkLineWidth
        inkColor.setStroke()
        inkPath.stroke()
    }
}
#endif
