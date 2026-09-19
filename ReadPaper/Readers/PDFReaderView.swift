import PDFKit
import OSLog
import SwiftUI

#if os(macOS)
import AppKit
import CoreImage
private typealias PlatformPDFColor = NSColor
private typealias PlatformPDFViewRepresentable = NSViewRepresentable
#else
import UIKit
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
    var onNoteSelectionChanged: ((NoteSelectionContext?) -> Void)? = nil
    var onArxivLinkActivated: ((URL) -> Void)? = nil
    var onDocumentPageCountChanged: ((Int) -> Void)? = nil
    var debugRegionSelectionEnabled = false
    var onDebugRegionSelected: ((PDFDebugRegionSelection) -> Void)? = nil

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
        let view = PDFView()
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
                to: interactiveView
            )
            interactiveView.onDebugRegionSelected = onDebugRegionSelected
        }
        #endif

        guard let fileURL else {
            let hadLoadedDocument = view.document != nil || context.coordinator.loadedURL != nil
            if hadLoadedDocument {
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
            return
        }
        let shouldReloadDocument = context.coordinator.loadedURL != fileURL ||
            context.coordinator.lastReloadToken != reloadToken ||
            context.coordinator.loadedPaperID != paperID ||
            context.coordinator.loadedAttachmentID != attachmentID
        if shouldReloadDocument {
            let restorePosition = context.coordinator.readingPosition(
                fallbackPageIndex: pageIndex,
                in: view
            )
            context.coordinator.prepareForProgrammaticPageRestore(to: restorePosition)
            context.coordinator.clearSelectionAssistantHistoryAnnotations()
            let document = PDFDocument(url: fileURL)
            view.document = document
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
        context.coordinator.applyNoteNavigationIfNeeded(noteNavigationRequest, in: view)
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

        func applyScalingPreference(_ usesAutomaticScaling: Bool, to pdfView: PDFView) {
            guard appliedAutomaticScaling != usesAutomaticScaling else { return }
            appliedAutomaticScaling = usesAutomaticScaling
            pdfView.autoScales = usesAutomaticScaling
            if usesAutomaticScaling == false {
                pdfView.scaleFactor = 1
            }
        }

        func restoreAutomaticScalingIfNearFit(in pdfView: PDFView) {
            guard pdfView.autoScales == false,
                  PDFAutomaticScalingPolicy.shouldRestore(
                    currentScale: pdfView.scaleFactor,
                    fittedScale: pdfView.scaleFactorForSizeToFit
                  ) else {
                return
            }
            pdfView.autoScales = true
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
            to pdfView: InteractivePDFView
        ) {
            let configuration = InteractionConfiguration(
                mode: debugRegionSelectionEnabled
                    ? .debugRegion
                    : annotationSession?.interactionMode ?? .browse,
                colorPreset: annotationSession?.colorPreset ?? .yellow,
                lineWidth: annotationSession?.lineWidth ?? 2,
                displayAppearance: displayAppearance
            )
            guard appliedInteractionConfiguration != configuration else { return }
            appliedInteractionConfiguration = configuration
            pdfView.interactionMode = configuration.mode
            pdfView.inkPreviewColor = configuration.colorPreset
                .color(for: .ink)
                .platformColor(inverted: false)
            pdfView.inkPreviewLineWidth = configuration.lineWidth
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
                    self?.handleSelectionAssistantHistoryClick(on: page, at: point) ?? false
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
            #endif
        }

        func detach() {
            clearNoteNavigationHighlight()
            clearSelectionAssistantHistoryAnnotations()
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
                guard nearbyPageIndexes.contains(clampedPageIndex) else { continue }
                guard let page = document.page(at: clampedPageIndex),
                      let pageText = page.string,
                      let range = PDFNoteNavigationTextMatcher.range(of: anchor.quote, in: pageText),
                      let selection = page.selection(for: range) else {
                    continue
                }

                let lineSelections = selection.selectionsByLine()
                let selections = lineSelections.isEmpty ? [selection] : lineSelections
                var didRenderAnchor = false
                for line in selections {
                    let bounds = line.bounds(for: page)
                        .intersection(page.bounds(for: .cropBox))
                        .standardized
                    guard bounds.isNull == false, bounds.width > 0, bounds.height > 0 else { continue }
                    let annotation = PDFAnnotation(
                        bounds: bounds,
                        forType: .underline,
                        withProperties: nil
                    )
                    annotation.color = selectionAssistantHistoryColor
                    let border = PDFBorder()
                    border.lineWidth = 1
                    annotation.border = border
                    page.addAnnotation(annotation)
                    selectionAssistantHistoryAnnotations.append((anchor, annotation))
                    didRenderAnchor = true
                }
                if didRenderAnchor {
                    renderedSelectionAssistantHistoryAnchorIDs.insert(anchor.id)
                }
            }
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

        private func eraseAnnotation(on page: PDFPage, at point: CGPoint) {
            activateAnnotationDocument()
            let hitTolerance: CGFloat = 6
            guard let annotation = page.annotations.reversed().first(where: { annotation in
                PDFAnnotationRenderer.recordID(for: annotation) != nil &&
                    annotation.bounds.insetBy(dx: -hitTolerance, dy: -hitTolerance).contains(point)
            }),
            let recordID = PDFAnnotationRenderer.recordID(for: annotation),
            let record = annotationRecords.first(where: { $0.id == recordID })
            else {
                return
            }
            removeAnnotationRecords([record])
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
                guard let page = document.page(at: record.pageIndex) else { continue }
                let annotation = PDFAnnotationRenderer.makeAnnotation(
                    from: record,
                    invertedColor: false
                )
                page.addAnnotation(annotation)
                renderedAnnotations[record.id] = annotation
            }
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
            publishAnnotationCapabilities()
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
            return currentPageIndex == NSNotFound || currentPageIndex != targetPageIndex
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

            guard currentIndex != pageIndex.wrappedValue else { return }
            pageIndex.wrappedValue = currentIndex
        }

        @objc
        private func handlePageChanged(_ notification: Notification) {
            os_signpost(.event, log: Self.performanceLog, name: "PDF Page Changed")
            scheduleCurrentPageIndexUpdate()
            if let pdfView {
                scheduleSelectionAssistantHistoryRendering(in: pdfView)
            }
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

#if os(macOS)
@MainActor
private final class InteractivePDFView: PDFView {
    var interactionMode: PDFInteractionMode = .browse {
        didSet {
            guard oldValue != interactionMode else { return }
            cancelInteraction()
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
    var onDebugRegionSelected: ((PDFDebugRegionSelection) -> Void)?
    var onInkStrokeCompleted: ((PDFPage, [CGPoint]) -> Void)?
    var onEraseRequested: ((PDFPage, CGPoint) -> Void)?
    var onTextNoteRequested: ((PDFPage, CGPoint) -> Void)?

    private let interactionOverlay = PDFInteractionOverlayView()
    private weak var interactionPage: PDFPage?
    private var interactionStartPoint: CGPoint?
    private var inkViewPoints: [CGPoint] = []
    private var suppressBrowseMouseSequence = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        installInteractionOverlay()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        installInteractionOverlay()
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
        super.magnify(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        if interactionMode == .browse {
            onInteractionBegan?()
            if event.type == .leftMouseDown {
                let viewPoint = convert(event.locationInWindow, from: nil)
                if let page = page(for: viewPoint, nearest: false),
                   onBrowseClick?(page, convert(viewPoint, to: page)) == true {
                    suppressBrowseMouseSequence = true
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

    override func mouseDragged(with event: NSEvent) {
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

    private func cancelInteraction() {
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
