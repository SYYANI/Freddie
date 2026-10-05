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

    /// Notes anchored to the displayed PDF. Notes without an attachment predate
    /// attachment tracking and belong to the original PDF.
    static func anchors(
        from notes: [Note],
        attachmentID: UUID?,
        includesUnattributedNotes: Bool
    ) -> [PDFSidenoteAnchor] {
        notes.compactMap { note in
            guard let pageIndex = note.pageIndex else { return nil }
            if let noteAttachmentID = note.attachmentID {
                guard noteAttachmentID == attachmentID else { return nil }
            } else if includesUnattributedNotes == false {
                return nil
            }
            return PDFSidenoteAnchor(id: note.id, pageIndex: pageIndex, quote: note.trimmedQuote ?? "")
        }
    }
}

enum PDFSidenoteAnchorResolver {
    /// Height of the band used when a note's quote cannot be found on its page.
    static let fallbackBandHeight: CGFloat = 12

    /// The anchor's rect in page space: the quote's bounds when it is found on the
    /// page, otherwise a band at the top of the page. `nil` when the page does
    /// not exist, e.g. a partial translated PDF.
    static func pageRect(
        for anchor: PDFSidenoteAnchor,
        in document: PDFDocument,
        pageText: (Int) -> String?
    ) -> CGRect? {
        guard anchor.pageIndex >= 0,
              anchor.pageIndex < document.pageCount,
              let page = document.page(at: anchor.pageIndex) else {
            return nil
        }

        if anchor.quote.isEmpty == false,
           let text = pageText(anchor.pageIndex),
           let range = PDFNoteNavigationTextMatcher.range(of: anchor.quote, in: text),
           let selection = page.selection(for: range) {
            let bounds = selection.bounds(for: page)
            if bounds.isNull == false, bounds.isEmpty == false {
                return bounds
            }
        }

        let pageBounds = page.bounds(for: .cropBox)
        return CGRect(
            x: pageBounds.minX,
            y: pageBounds.maxY - fallbackBandHeight,
            width: pageBounds.width,
            height: fallbackBandHeight
        )
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

/// Shares the PDF view's anchor positions with the margin rail, so scrolling
/// only re-renders the rail rather than the whole reader pane.
@MainActor
@Observable
final class PDFSidenoteLayoutModel {
    /// Top of each note's anchor, in points from the top of the PDF view.
    private(set) var anchorTops: [UUID: CGFloat] = [:]

    #if os(macOS)
    /// The PDF's scroll view, which receives scroll wheel events over the rail.
    @ObservationIgnored weak var scrollView: NSScrollView?
    #endif

    func update(anchorTops newValue: [UUID: CGFloat]) {
        let rounded = newValue.mapValues { ($0 * 2).rounded() / 2 }
        guard rounded != anchorTops else { return }
        anchorTops = rounded
    }
}
