import Foundation
import Observation
import PDFKit

#if os(macOS)
import AppKit
#endif

/// A note shown in the PDF reader's margin rail, anchored to a page and quote.
struct PDFSidenoteAnchor: Equatable, Sendable, Identifiable {
    var id: UUID
    var pageIndex: Int
    var quote: String

    /// Notes anchored to the displayed PDF, in a stable order so that editing a
    /// note (which reorders notes by modification date) does not re-resolve
    /// anchors. Notes without an attachment predate attachment tracking and
    /// belong to the original PDF.
    static func anchors(
        from notes: [Note],
        attachmentID: UUID?,
        includesUnattributedNotes: Bool
    ) -> [PDFSidenoteAnchor] {
        let anchors = notes.compactMap { note -> PDFSidenoteAnchor? in
            guard let pageIndex = note.pageIndex else { return nil }
            if let noteAttachmentID = note.attachmentID {
                guard noteAttachmentID == attachmentID else { return nil }
            } else if includesUnattributedNotes == false {
                return nil
            }
            return PDFSidenoteAnchor(id: note.id, pageIndex: pageIndex, quote: note.trimmedQuote ?? "")
        }
        return anchors.sorted { ($0.pageIndex, $0.id.uuidString) < ($1.pageIndex, $1.id.uuidString) }
    }
}

enum PDFSidenoteAnchorResolver {
    /// Height of the band used when a note's quote cannot be found on its page.
    static let fallbackBandHeight: CGFloat = 12

    struct Resolution: Equatable {
        /// Where the note's card aligns, in page space.
        var anchorRect: CGRect
        /// One rect per line of the quote, for highlighting; empty when the
        /// quote was not found on the page.
        var quoteLineRects: [CGRect]
    }

    /// Resolves an anchor on its page: the quote's bounds when it is found,
    /// otherwise a band at the top of the page. `nil` when the page does not
    /// exist, e.g. a partial translated PDF.
    static func resolve(
        _ anchor: PDFSidenoteAnchor,
        in document: PDFDocument,
        pageText: (Int) -> String?
    ) -> Resolution? {
        guard anchor.pageIndex >= 0,
              anchor.pageIndex < document.pageCount,
              let page = document.page(at: anchor.pageIndex) else {
            return nil
        }
        let pageBounds = page.bounds(for: .cropBox)

        if anchor.quote.isEmpty == false,
           let text = pageText(anchor.pageIndex),
           let range = PDFNoteNavigationTextMatcher.range(of: anchor.quote, in: text),
           let selection = page.selection(for: range) {
            let bounds = selection.bounds(for: page)
            if bounds.isNull == false, bounds.isEmpty == false {
                let lines = selection.selectionsByLine()
                let lineRects = (lines.isEmpty ? [selection] : lines).compactMap { line -> CGRect? in
                    let rect = line.bounds(for: page).intersection(pageBounds).standardized
                    return rect.isNull || rect.isEmpty ? nil : rect
                }
                return Resolution(anchorRect: bounds, quoteLineRects: lineRects)
            }
        }

        return Resolution(
            anchorRect: CGRect(
                x: pageBounds.minX,
                y: pageBounds.maxY - fallbackBandHeight,
                width: pageBounds.width,
                height: fallbackBandHeight
            ),
            quoteLineRects: []
        )
    }

    static func pageRect(
        for anchor: PDFSidenoteAnchor,
        in document: PDFDocument,
        pageText: (Int) -> String?
    ) -> CGRect? {
        resolve(anchor, in: document, pageText: pageText)?.anchorRect
    }
}

enum SidenoteStacking {
    /// Places items at their desired tops, in order, pushing each one below the
    /// previous item so that none overlap.
    static func tops(desired: [CGFloat], heights: [CGFloat], spacing: CGFloat) -> [CGFloat] {
        var tops: [CGFloat] = []
        tops.reserveCapacity(desired.count)
        var cursor = -CGFloat.greatestFiniteMagnitude
        for (index, desiredTop) in desired.enumerated() {
            let top = max(desiredTop, cursor)
            tops.append(top)
            let height = index < heights.count ? heights[index] : 0
            cursor = top + height + spacing
        }
        return tops
    }
}

struct SidenoteFlashRequest: Equatable {
    var noteID: UUID
    var token: Int
}

/// Shares state between the PDF view and the margin rail: anchor positions
/// flow to the rail, so scrolling only re-renders the rail rather than the
/// whole reader pane; the hovered or edited note flows back to emphasize its
/// highlight; clicks on a highlight flash the matching card.
@MainActor
@Observable
final class PDFSidenoteLayoutModel {
    /// Top of each note's anchor, in points from the top of the PDF view.
    private(set) var anchorTops: [UUID: CGFloat] = [:]
    private(set) var flashRequest: SidenoteFlashRequest?
    @ObservationIgnored private(set) var activeNoteID: UUID?
    @ObservationIgnored var onActiveNoteChanged: ((UUID?) -> Void)?

    #if os(macOS)
    /// The PDF's scroll view, which receives scroll wheel events over the rail.
    @ObservationIgnored weak var scrollView: NSScrollView?
    #endif

    func setActiveNote(_ noteID: UUID?) {
        guard activeNoteID != noteID else { return }
        activeNoteID = noteID
        onActiveNoteChanged?(noteID)
    }

    func flash(_ noteID: UUID) {
        flashRequest = SidenoteFlashRequest(noteID: noteID, token: (flashRequest?.token ?? 0) + 1)
    }

    func update(anchorTops newValue: [UUID: CGFloat]) {
        let rounded = newValue.mapValues { ($0 * 2).rounded() / 2 }
        guard rounded != anchorTops else { return }
        anchorTops = rounded
    }
}
