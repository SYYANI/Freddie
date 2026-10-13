import AppKit
import iosMath

extension NSAttributedString.Key {
    /// A typeset formula (`WritingMathBox`) on the TeX of `$…$`, drawn instead of the TeX
    /// while its line is not being edited.
    static let writingMath = NSAttributedString.Key("ReadPaperWritingMath")
    /// A loaded image (`WritingImageBox`) on the whole `![alt](path)` syntax, drawn below
    /// its line.
    static let writingImage = NSAttributedString.Key("ReadPaperWritingImage")
}

/// A formula typeset with iosMath. The editor turns the first character of the TeX into a
/// control glyph as wide as the formula and draws the formula at that glyph. Like the rest of
/// the text system it is only used on the main thread.
final class WritingMathBox: NSObject, @unchecked Sendable {
    /// Space kept on both sides of the formula.
    static let horizontalInset: CGFloat = 1

    let width: CGFloat
    let ascent: CGFloat
    let descent: CGFloat
    private let display: MTMathListDisplay

    fileprivate init(display: MTMathListDisplay) {
        self.display = display
        width = ceil(display.width) + 2 * Self.horizontalInset
        ascent = ceil(display.ascent)
        descent = ceil(display.descent)
    }

    /// Draws the formula with its baseline starting at `origin`, in a flipped context.
    func draw(baselineOrigin origin: CGPoint, color: NSColor, in context: CGContext) {
        context.saveGState()
        // The text matrix is not part of the graphics state.
        let textMatrix = context.textMatrix
        context.translateBy(x: origin.x + Self.horizontalInset, y: origin.y)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        display.textColor = color
        display.position = .zero
        display.draw(context)
        context.textMatrix = textMatrix
        context.restoreGState()
    }
}

/// Typesets TeX for the writing editor, remembering results per formula and size.
@MainActor
final class WritingMathTypesetter {
    static let shared = WritingMathTypesetter()

    private let cache = NSCache<NSString, WritingMathBox>()
    private var invalidKeys = Set<String>()
    private let label = MTMathUILabel()

    private init() {
        cache.countLimit = 2_000
        label.displayErrorInline = false
    }

    /// Nil when iosMath cannot read the TeX.
    func box(tex: String, isDisplay: Bool, fontSize: CGFloat) -> WritingMathBox? {
        let trimmed = tex.trimmingCharacters(in: .whitespaces)
        guard trimmed.isEmpty == false else { return nil }
        let key = "\(isDisplay ? "display" : "text")|\(fontSize)|\(trimmed)"
        if let cached = cache.object(forKey: key as NSString) {
            return cached
        }
        guard invalidKeys.contains(key) == false else { return nil }

        label.mode = isDisplay ? .display : .text
        label.fontSize = fontSize
        label.latex = trimmed
        label.needsLayout = true
        label.layoutSubtreeIfNeeded()
        guard label.error == nil, label.mathList != nil, let display = label.displayList, display.width > 0 else {
            invalidKeys.insert(key)
            return nil
        }
        let box = WritingMathBox(display: display)
        cache.setObject(box, forKey: key as NSString)
        return box
    }
}

/// An image shown in a writing. A new box is made for every image in the text, so two
/// images of the same file next to each other stay apart. Main thread only.
final class WritingImageBox: NSObject, @unchecked Sendable {
    let url: URL
    let image: NSImage

    init(url: URL, image: NSImage) {
        self.url = url
        self.image = image
    }

    /// The image's own size in points, scaled down to fit.
    func displaySize(maximumWidth: CGFloat) -> NSSize {
        let natural = image.size
        guard natural.width > 0, natural.height > 0, maximumWidth > 0 else { return .zero }
        let scale = min(1, maximumWidth / natural.width, WritingImageLayout.maximumHeight / natural.height)
        return NSSize(width: (natural.width * scale).rounded(), height: (natural.height * scale).rounded())
    }
}

/// Loaded images by file, reloaded when the file changes.
@MainActor
final class WritingImageCache {
    static let shared = WritingImageCache()

    private struct Entry {
        var modificationDate: Date
        var image: NSImage
    }

    private var entries: [URL: Entry] = [:]

    func image(at url: URL) -> NSImage? {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
        guard values?.isRegularFile == true, let modificationDate = values?.contentModificationDate else {
            entries[url] = nil
            return nil
        }
        if let entry = entries[url], entry.modificationDate == modificationDate {
            return entry.image
        }
        guard let image = NSImage(contentsOf: url), image.isValid, image.size.width > 0, image.size.height > 0 else {
            entries[url] = nil
            return nil
        }
        entries[url] = Entry(modificationDate: modificationDate, image: image)
        return image
    }
}

/// Where the images of a paragraph go: stacked below the paragraph's last line, or in
/// place of the line when the paragraph is nothing but images and is not being edited.
struct WritingImageLayout {
    static let maximumHeight: CGFloat = 560
    static let spacing: CGFloat = 8
    static let topPadding: CGFloat = 4
    static let bottomPadding: CGFloat = 8

    var items: [(box: WritingImageBox, size: NSSize)]
    /// From the line fragment's leading edge to the images.
    var leadingInset: CGFloat
    /// The line shows only the images, so its text height is dropped.
    var replacesText: Bool

    var height: CGFloat {
        let images = items.reduce(0) { $0 + $1.size.height }
        return Self.topPadding + images + Self.spacing * CGFloat(max(0, items.count - 1)) + Self.bottomPadding
    }

    var width: CGFloat {
        items.map(\.size.width).max() ?? 0
    }

    /// Image frames for a line fragment whose height already includes `height`.
    func frames(inLineFragment rect: NSRect) -> [(box: WritingImageBox, frame: NSRect)] {
        var y = rect.maxY - height + Self.topPadding
        return items.map { item in
            let frame = NSRect(x: rect.minX + leadingInset, y: y, width: item.size.width, height: item.size.height)
            y += item.size.height + Self.spacing
            return (item.box, frame)
        }
    }
}
