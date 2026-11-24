import CoreGraphics
import Foundation
import PDFKit
#if os(macOS)
import AppKit
#endif

/// A line of a PDF page as PDFKit selects it.
struct PDFEchoLine: Equatable {
    /// In page coordinates (origin at the bottom left).
    var bounds: CGRect
    var text: String
}

/// A paragraph-like run of lines on a PDF page: what an echo mark sits beside. PDFs carry
/// no paragraphs, so they are guessed from the line layout.
struct PDFEchoParagraph: Equatable {
    var id: String
    var pageIndex: Int
    var text: String
    /// In page coordinates.
    var bounds: CGRect
    var firstLine: CGRect
}

enum PDFEchoParagraphs {
    /// A run without paragraph breaks (a dense column) is cut after this many lines, so
    /// a mark is never far from the passage it is for.
    static let maxLines = 12

    static func id(pageIndex: Int, paragraph: Int) -> String {
        "p\(pageIndex)-\(paragraph)"
    }

    static func pageIndex(of id: String) -> Int? {
        guard id.hasPrefix("p"), let dash = id.firstIndex(of: "-") else { return nil }
        return Int(id[id.index(after: id.startIndex)..<dash])
    }

    /// Groups lines in reading order into paragraphs. A new paragraph starts at a gap
    /// taller than a line, at a jump to another column, after a heading (a lone line taller
    /// or much shorter than the next), after a short last line followed by an indented one,
    /// or after `maxLines` lines.
    static func group(_ lines: [PDFEchoLine], pageIndex: Int) -> [PDFEchoParagraph] {
        var paragraphs: [PDFEchoParagraph] = []
        var current: [PDFEchoLine] = []

        func flush() {
            guard let first = current.first else { return }
            let bounds = current.dropFirst().reduce(first.bounds) { $0.union($1.bounds) }
            let text = current.dropFirst().reduce(first.text) { LearningEventCollector.joinedLines($0, $1.text) }
            paragraphs.append(PDFEchoParagraph(
                id: id(pageIndex: pageIndex, paragraph: paragraphs.count),
                pageIndex: pageIndex,
                text: text,
                bounds: bounds,
                firstLine: first.bounds
            ))
            current = []
        }

        for line in mergingPiecesOfALine(lines) {
            guard let previous = current.last else {
                current = [line]
                continue
            }
            let height = max(min(previous.bounds.height, line.bounds.height), 1)
            let gap = previous.bounds.minY - line.bounds.maxY
            let overlap = min(previous.bounds.maxX, line.bounds.maxX) - max(previous.bounds.minX, line.bounds.minX)
            let columnLeft = current.map(\.bounds.minX).min() ?? line.bounds.minX
            let columnRight = current.map(\.bounds.maxX).max() ?? line.bounds.maxX
            let previousIsShort = previous.bounds.maxX < columnRight - height * 2
            let isIndented = line.bounds.minX > columnLeft + height * 0.6
            // A lone line in a larger font than the next, or much shorter than it: a
            // heading over its section. Inline math makes lines inside a paragraph taller
            // too, so only a taller line *before* the text counts.
            let followsHeading = current.count == 1
                && (previous.bounds.height > line.bounds.height * 1.2
                    || previous.bounds.width < line.bounds.width * 0.6)
            // Back up the page: the next column. Its bottom is above the previous line's
            // centre; lines made taller by inline math only reach into their neighbours.
            let jumpsUp = line.bounds.minY > previous.bounds.midY
            let startsParagraph = gap > height * 0.9
                || jumpsUp
                || followsHeading
                || overlap < min(previous.bounds.width, line.bounds.width) * 0.3
                || (previousIsShort && isIndented)
                || current.count >= maxLines
            if startsParagraph {
                flush()
            }
            current.append(line)
        }
        flush()
        return paragraphs
    }

    /// PDFKit sometimes splits one printed line into pieces (around inline math, for
    /// instance). Consecutive pieces on the same baseline with only a word-sized gap are
    /// one line again; table cells, far apart on a row, stay separate.
    static func mergingPiecesOfALine(_ lines: [PDFEchoLine]) -> [PDFEchoLine] {
        var merged: [PDFEchoLine] = []
        for line in lines where line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            if let previous = merged.last {
                let height = max(min(previous.bounds.height, line.bounds.height), 1)
                let verticalOverlap = min(previous.bounds.maxY, line.bounds.maxY) - max(previous.bounds.minY, line.bounds.minY)
                let gap = line.bounds.minX - previous.bounds.maxX
                if verticalOverlap > height * 0.5, gap > -height, gap < height * 1.5 {
                    merged[merged.count - 1] = PDFEchoLine(
                        bounds: previous.bounds.union(line.bounds),
                        text: previous.text + " " + line.text
                    )
                    continue
                }
            }
            merged.append(line)
        }
        return merged
    }

    /// The paragraphs of a page, with PDFKit's lines and the reader's word spacing.
    static func paragraphs(on page: PDFPage, pageIndex: Int) -> [PDFEchoParagraph] {
        let pageBounds = page.bounds(for: .cropBox)
        guard let selection = page.selection(for: pageBounds) else { return [] }
        let lines = selection.selectionsByLine().compactMap { line -> PDFEchoLine? in
            let bounds = line.bounds(for: page).intersection(pageBounds).standardized
            guard bounds.isNull == false, bounds.width > 0, bounds.height > 0,
                  let text = (PDFWordSpacing.text(of: line) ?? line.string)?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  text.isEmpty == false else { return nil }
            return PDFEchoLine(bounds: bounds, text: text)
        }
        return group(lines, pageIndex: pageIndex)
    }

    static let markSize: CGFloat = 16

    /// Where a paragraph's mark goes, in page coordinates: centred on its first line, in
    /// the margin on the side of its column (the outer margin for a right-hand column).
    static func markRect(for paragraph: PDFEchoParagraph, pageBounds: CGRect) -> CGRect {
        let size = markSize
        let isRightColumn = paragraph.bounds.width < pageBounds.width * 0.6
            && paragraph.bounds.midX > pageBounds.midX
        var x = isRightColumn ? paragraph.bounds.maxX + 8 : paragraph.bounds.minX - 8 - size
        if x < pageBounds.minX + 2 || x + size > pageBounds.maxX - 2 {
            x = min(max(pageBounds.minX + 2, paragraph.bounds.minX - size - 2), pageBounds.maxX - size - 2)
        }
        let y = paragraph.firstLine.midY - size / 2
        return CGRect(x: x, y: y, width: size, height: size)
    }
}

/// An echo mark placed on a page: the paragraph it marks and where, in page coordinates.
struct PDFEchoMarkPlacement {
    let page: PDFPage
    let bounds: CGRect
    let blockID: String
    let isSeen: Bool
}

#if os(macOS)
/// A mark beside a paragraph with echoes: a dot with a faint ring, drawn in the page
/// margin. It is a view in PDFKit's document view, not a `PDFAnnotation`: PDFKit draws
/// custom annotations into a page-sized bitmap at 1x page scale and does not redraw them
/// when zoomed, so they blur; the document view is magnified by its scroll view, and
/// AppKit redraws its subviews sharp at every magnification. Nothing is added to the PDF.
final class PDFEchoMarkView: NSView {
    let blockID: String
    let isSeen: Bool

    init(blockID: String, isSeen: Bool) {
        self.blockID = blockID
        self.isSeen = isSeen
        super.init(frame: .zero)
        wantsLayer = true
        // Above the page views PDFKit adds to the document view as pages come into view.
        layer?.zPosition = 10
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    /// Clicks go to the PDF view, which opens the fan (`InteractivePDFView.onBrowseClick`).
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        // Sized like the page (the frame is in document-view points); drawn in units of
        // the 16-point mark.
        let unit = bounds.width / PDFEchoParagraphs.markSize
        let alpha: CGFloat = isSeen ? 0.3 : 0.75
        let color = CGColor(srgbRed: 10 / 255, green: 132 / 255, blue: 1, alpha: alpha)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        context.setFillColor(color)
        context.fillEllipse(in: CGRect(x: center.x - 3 * unit, y: center.y - 3 * unit, width: 6 * unit, height: 6 * unit))
        context.setStrokeColor(color.copy(alpha: alpha * 0.55) ?? color)
        context.setLineWidth(unit)
        context.strokeEllipse(in: CGRect(x: center.x - 6 * unit, y: center.y - 6 * unit, width: 12 * unit, height: 12 * unit))
    }
}
#endif
