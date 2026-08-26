import PDFKit
import SwiftUI

#if os(macOS)
import AppKit
private typealias PlatformPDFColor = NSColor
private typealias PlatformPDFViewRepresentable = NSViewRepresentable
#else
import UIKit
private typealias PlatformPDFColor = UIColor
private typealias PlatformPDFViewRepresentable = UIViewRepresentable
#endif

private func displayAdjustedAnnotationColor(
    _ color: PlatformPDFColor,
    inverted: Bool
) -> PlatformPDFColor {
    guard inverted else { return color }
    #if os(macOS)
    guard let rgbColor = color.usingColorSpace(.deviceRGB) else { return color }
    return NSColor(
        calibratedRed: 1 - rgbColor.redComponent,
        green: 1 - rgbColor.greenComponent,
        blue: 1 - rgbColor.blueComponent,
        alpha: rgbColor.alphaComponent
    )
    #else
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return color }
    return UIColor(red: 1 - red, green: 1 - green, blue: 1 - blue, alpha: alpha)
    #endif
}

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
    fileprivate var pdfBackgroundColor: PlatformPDFColor {
        switch self {
        case .defaultMode:
            #if os(macOS)
            return .textBackgroundColor
            #else
            return .systemBackground
            #endif
        case .dark:
            // Keep the PDFView background light so the difference blend can invert
            // both the page and the surrounding canvas into a dark reading surface.
            #if os(macOS)
            return NSColor(calibratedWhite: 0.96, alpha: 1)
            #else
            return UIColor(white: 0.96, alpha: 1)
            #endif
        case .paper:
            #if os(macOS)
            return NSColor(calibratedRed: 0.96, green: 0.93, blue: 0.86, alpha: 1)
            #else
            return UIColor(red: 0.96, green: 0.93, blue: 0.86, alpha: 1)
            #endif
        }
    }

    var surfaceColor: Color {
        #if os(macOS)
        Color(nsColor: pdfBackgroundColor)
        #else
        Color(uiColor: pdfBackgroundColor)
        #endif
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
    @Binding var pageIndex: Int
    var reloadToken: Int = 0
    var annotationSession: PDFAnnotationSession? = nil
    var onNoteSelectionChanged: ((NoteSelectionContext?) -> Void)? = nil
    var onArxivLinkActivated: ((URL) -> Void)? = nil
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
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        applyDisplayAppearance(displayAppearance, to: view)
        context.coordinator.attach(to: view)
        return view
    }

    private func updateView(_ view: PDFView, context: Context) {
        applyDisplayAppearance(displayAppearance, to: view)
        context.coordinator.configure(
            paperID: paperID,
            attachmentID: attachmentID,
            annotationSession: annotationSession
        )
        context.coordinator.onNoteSelectionChanged = onNoteSelectionChanged
        context.coordinator.onArxivLinkActivated = onArxivLinkActivated
        #if os(macOS)
        if let interactiveView = view as? InteractivePDFView {
            interactiveView.interactionMode = debugRegionSelectionEnabled
                ? .debugRegion
                : annotationSession?.interactionMode ?? .browse
            interactiveView.onDebugRegionSelected = onDebugRegionSelected
            interactiveView.inkPreviewColor = (annotationSession?.colorPreset ?? .yellow)
                .color(for: .ink)
                .platformColor(inverted: displayAppearance == .dark)
            interactiveView.inkPreviewLineWidth = annotationSession?.lineWidth ?? 2
        }
        #endif
        context.coordinator.updateAnnotationAppearance(displayAppearance)

        guard let fileURL else {
            view.document = nil
            context.coordinator.loadedURL = nil
            context.coordinator.loadedPaperID = paperID
            context.coordinator.loadedAttachmentID = attachmentID
            context.coordinator.lastReloadToken = reloadToken
            context.coordinator.clearLoadedAnnotations()
            context.coordinator.clearProgrammaticPageRestore()
            context.coordinator.publishSelection(nil)
            context.coordinator.scheduleCurrentPageIndexUpdate()
            return
        }
        let shouldReloadDocument = context.coordinator.loadedURL != fileURL ||
            context.coordinator.lastReloadToken != reloadToken ||
            context.coordinator.loadedPaperID != paperID ||
            context.coordinator.loadedAttachmentID != attachmentID
        let restorePosition = context.coordinator.readingPosition(
            fallbackPageIndex: pageIndex,
            in: view
        )
        if shouldReloadDocument {
            context.coordinator.prepareForProgrammaticPageRestore(to: restorePosition)
            view.document = PDFDocument(url: fileURL)
            context.coordinator.loadedURL = fileURL
            context.coordinator.loadedPaperID = paperID
            context.coordinator.loadedAttachmentID = attachmentID
            context.coordinator.lastReloadToken = reloadToken
            context.coordinator.loadAnnotations(in: view)
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
            paperID: paperID,
            attachmentID: attachmentID,
            pageIndex: $pageIndex,
            onNoteSelectionChanged: onNoteSelectionChanged,
            onArxivLinkActivated: onArxivLinkActivated,
            annotationSession: annotationSession
        )
    }

    private func applyDisplayAppearance(_ appearance: PDFDisplayAppearance, to view: PDFView) {
        view.backgroundColor = appearance.pdfBackgroundColor
    }

    @MainActor
    final class Coordinator: NSObject, PDFAnnotationSessionHandler {
        private enum AnnotationHistoryEntry {
            case add([PDFAnnotationRecord])
            case remove([PDFAnnotationRecord])
        }

        var loadedURL: URL?
        var loadedPaperID: UUID?
        var loadedAttachmentID: UUID?
        var lastReloadToken: Int = 0
        var paperID: UUID?
        var attachmentID: UUID?
        weak var pdfView: PDFView?
        var pageIndex: Binding<Int>
        var onNoteSelectionChanged: ((NoteSelectionContext?) -> Void)?
        var onArxivLinkActivated: ((URL) -> Void)?
        private weak var annotationSession: PDFAnnotationSession?
        private weak var registeredAnnotationSession: PDFAnnotationSession?
        private var registeredAnnotationAttachmentID: UUID?
        private var annotationStore: PDFAnnotationStore
        private var annotationRecords: [PDFAnnotationRecord] = []
        private var renderedAnnotations: [UUID: PDFAnnotation] = [:]
        private var sourceAnnotationColors: [ObjectIdentifier: (PDFAnnotation, PlatformPDFColor)] = [:]
        private var undoAnnotationHistory: [AnnotationHistoryEntry] = []
        private var redoAnnotationHistory: [AnnotationHistoryEntry] = []
        private var annotationColorsAreInverted = false
        private var isPageIndexUpdateScheduled = false
        private var isSelectionUpdateScheduled = false
        private var lastPublishedSelection: NoteSelectionContext?
        private var pendingProgrammaticPosition: PDFReadingPosition?

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
                sourceAnnotationColors = [:]
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
            self.pdfView = nil
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
            captureSourceAnnotationColors(in: pdfView.document)
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

        func updateAnnotationAppearance(_ appearance: PDFDisplayAppearance) {
            let shouldInvert = appearance == .dark
            guard annotationColorsAreInverted != shouldInvert else { return }
            annotationColorsAreInverted = shouldInvert
            for (_, (annotation, originalColor)) in sourceAnnotationColors {
                annotation.color = displayAdjustedAnnotationColor(
                    originalColor,
                    inverted: shouldInvert
                )
            }
            for record in annotationRecords {
                renderedAnnotations[record.id]?.color = record.color.platformColor(
                    inverted: shouldInvert
                )
            }
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
                    invertedColor: annotationColorsAreInverted
                )
                page.addAnnotation(annotation)
                renderedAnnotations[record.id] = annotation
            }
        }

        private func captureSourceAnnotationColors(in document: PDFDocument?) {
            sourceAnnotationColors = [:]
            guard let document else { return }
            for pageIndex in 0..<document.pageCount {
                guard let page = document.page(at: pageIndex) else { continue }
                for annotation in page.annotations {
                    sourceAnnotationColors[ObjectIdentifier(annotation)] = (annotation, annotation.color)
                    annotation.color = displayAdjustedAnnotationColor(
                        annotation.color,
                        inverted: annotationColorsAreInverted
                    )
                }
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
            annotationRecords = []
            renderedAnnotations = [:]
            sourceAnnotationColors = [:]
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
    var onDebugRegionSelected: ((PDFDebugRegionSelection) -> Void)?
    var onInkStrokeCompleted: ((PDFPage, [CGPoint]) -> Void)?
    var onEraseRequested: ((PDFPage, CGPoint) -> Void)?
    var onTextNoteRequested: ((PDFPage, CGPoint) -> Void)?

    private let interactionOverlay = PDFInteractionOverlayView()
    private weak var interactionPage: PDFPage?
    private var interactionStartPoint: CGPoint?
    private var inkViewPoints: [CGPoint] = []

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

    override func mouseDown(with event: NSEvent) {
        guard event.type == .leftMouseDown, interactionMode != .browse else {
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
