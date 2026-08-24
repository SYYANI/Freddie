import Combine
import CoreGraphics
import Foundation

enum PDFInteractionMode: String, CaseIterable, Identifiable, Sendable {
    case browse
    case ink
    case textNote
    case erase
    case debugRegion

    var id: String { rawValue }
}

enum PDFTextMarkupKind: String, CaseIterable, Identifiable, Sendable {
    case highlight
    case underline
    case strikeOut

    var id: String { rawValue }

    var annotationKind: PDFAnnotationKind {
        switch self {
        case .highlight: return .highlight
        case .underline: return .underline
        case .strikeOut: return .strikeOut
        }
    }
}

struct PDFTextNotePlacement: Identifiable, Equatable {
    let id = UUID()
    var attachmentID: UUID
    var pageIndex: Int
    var point: CGPoint
}

@MainActor
protocol PDFAnnotationSessionHandler: AnyObject {
    var annotationAttachmentID: UUID? { get }
    var hasPDFTextSelection: Bool { get }
    var canUndoPDFAnnotation: Bool { get }
    var canRedoPDFAnnotation: Bool { get }
    var hasPDFAnnotations: Bool { get }

    func applyTextMarkup(_ kind: PDFTextMarkupKind, preset: PDFAnnotationColorPreset)
    func addTextNote(pageIndex: Int, point: CGPoint, contents: String, preset: PDFAnnotationColorPreset)
    func undoPDFAnnotation()
    func redoPDFAnnotation()
}

@MainActor
final class PDFAnnotationSession: ObservableObject {
    @Published private(set) var interactionMode: PDFInteractionMode = .browse
    @Published var colorPreset: PDFAnnotationColorPreset = .yellow
    @Published var lineWidth: Double = 2
    @Published private(set) var activeAttachmentID: UUID?
    @Published private(set) var hasTextSelection = false
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var hasAnnotations = false
    @Published private(set) var pendingTextNote: PDFTextNotePlacement?
    @Published private(set) var isDebugInteractionActive = false
    @Published var errorMessage: String?

    private var handlers: [UUID: WeakPDFAnnotationSessionHandler] = [:]

    func register(_ handler: any PDFAnnotationSessionHandler, for attachmentID: UUID) {
        handlers = handlers.filter { $0.value.value != nil }
        handlers[attachmentID] = WeakPDFAnnotationSessionHandler(handler)
        let activeHandlerAvailable = activeAttachmentID.flatMap { handlers[$0]?.value } != nil
        if activeHandlerAvailable == false {
            activeAttachmentID = attachmentID
        }
        refreshCapabilities()
    }

    func unregister(_ handler: any PDFAnnotationSessionHandler, for attachmentID: UUID) {
        guard handlers[attachmentID]?.value === handler else { return }
        handlers.removeValue(forKey: attachmentID)
        if activeAttachmentID == attachmentID {
            activeAttachmentID = handlers.first(where: { $0.value.value != nil })?.key
        }
        refreshCapabilities()
    }

    func activate(attachmentID: UUID?) {
        guard let attachmentID, handlers[attachmentID]?.value != nil else { return }
        activeAttachmentID = attachmentID
        refreshCapabilities()
    }

    func selectInteractionMode(_ mode: PDFInteractionMode) {
        guard mode != .debugRegion, isDebugInteractionActive == false else { return }
        interactionMode = mode
        pendingTextNote = nil
    }

    func beginDebugInteraction() {
        isDebugInteractionActive = true
        interactionMode = .browse
        pendingTextNote = nil
    }

    func endDebugInteraction() {
        isDebugInteractionActive = false
    }

    func applyTextMarkup(_ kind: PDFTextMarkupKind) {
        guard isDebugInteractionActive == false, let handler = activeHandler else { return }
        handler.applyTextMarkup(kind, preset: colorPreset)
        refreshCapabilities()
    }

    func requestTextNote(attachmentID: UUID?, pageIndex: Int, point: CGPoint) {
        guard isDebugInteractionActive == false,
              let attachmentID,
              handlers[attachmentID]?.value != nil
        else {
            return
        }
        activate(attachmentID: attachmentID)
        pendingTextNote = PDFTextNotePlacement(
            attachmentID: attachmentID,
            pageIndex: pageIndex,
            point: point
        )
    }

    func commitPendingTextNote(contents: String) {
        guard let placement = pendingTextNote,
              let handler = handlers[placement.attachmentID]?.value
        else {
            pendingTextNote = nil
            return
        }
        let normalized = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false else { return }
        handler.addTextNote(
            pageIndex: placement.pageIndex,
            point: placement.point,
            contents: normalized,
            preset: colorPreset
        )
        pendingTextNote = nil
        interactionMode = .browse
        refreshCapabilities()
    }

    func cancelPendingTextNote() {
        pendingTextNote = nil
        if interactionMode == .textNote {
            interactionMode = .browse
        }
    }

    func undo() {
        activeHandler?.undoPDFAnnotation()
        refreshCapabilities()
    }

    func redo() {
        activeHandler?.redoPDFAnnotation()
        refreshCapabilities()
    }

    func handlerDidChange(_ handler: any PDFAnnotationSessionHandler) {
        guard handler.annotationAttachmentID == activeAttachmentID else { return }
        refreshCapabilities()
    }

    func resetForDocumentChange() {
        interactionMode = .browse
        activeAttachmentID = nil
        pendingTextNote = nil
        isDebugInteractionActive = false
        refreshCapabilities()
    }

    func report(_ error: Error) {
        errorMessage = error.localizedDescription
    }

    private var activeHandler: (any PDFAnnotationSessionHandler)? {
        guard let activeAttachmentID else { return nil }
        return handlers[activeAttachmentID]?.value
    }

    private func refreshCapabilities() {
        handlers = handlers.filter { $0.value.value != nil }
        guard let handler = activeHandler else {
            if hasTextSelection { hasTextSelection = false }
            if canUndo { canUndo = false }
            if canRedo { canRedo = false }
            if hasAnnotations { hasAnnotations = false }
            return
        }
        let newHasTextSelection = handler.hasPDFTextSelection
        let newCanUndo = handler.canUndoPDFAnnotation
        let newCanRedo = handler.canRedoPDFAnnotation
        let newHasAnnotations = handler.hasPDFAnnotations
        if hasTextSelection != newHasTextSelection { hasTextSelection = newHasTextSelection }
        if canUndo != newCanUndo { canUndo = newCanUndo }
        if canRedo != newCanRedo { canRedo = newCanRedo }
        if hasAnnotations != newHasAnnotations { hasAnnotations = newHasAnnotations }
    }
}

@MainActor
private final class WeakPDFAnnotationSessionHandler {
    weak var value: (any PDFAnnotationSessionHandler)?

    init(_ value: any PDFAnnotationSessionHandler) {
        self.value = value
    }
}
