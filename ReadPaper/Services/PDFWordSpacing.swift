import CoreGraphics
import Foundation
import PDFKit

/// Restores word spaces PDFKit drops from some PDFs.
///
/// PDFKit treats a gap between two glyphs as a word break only when it is wide
/// compared with the width the font gives code 32. pdfTeX fonts that never draw
/// code 32 can carry an unrelated width there (500 in TeX Gyre Pagella subsets,
/// twice its real space), so on justified lines whose gaps shrink below about a
/// quarter em PDFKit returns "Anarchitecturalchangetouchesthreethings…".
///
/// The content stream still says where every glyph sits. This reads the gaps from
/// it (text and current transformation matrices, `TJ` offsets, `Tc`/`Tw`/`Tz` and the
/// font's own glyph widths) and inserts a space wherever two adjacent PDFKit
/// characters meet inside such a gap. PDFKit spreads a gap over the boxes of the
/// characters on both sides, so they meet at its middle. Text PDFKit already
/// spaces, and pages whose fonts this cannot measure, come back unchanged.
enum PDFWordSpacing {
    /// TeX shrinks interword glue to about 0.17–0.22 em on tight justified lines,
    /// while kerning and letterspacing stay well under 0.1 em.
    static let minimumGapEm: CGFloat = 0.15

    /// A word-sized gap between two glyphs on one baseline, in page space.
    struct Gap: Equatable {
        var minX: CGFloat
        var maxX: CGFloat
        var baseline: CGFloat
        var em: CGFloat

        var midX: CGFloat { (minX + maxX) / 2 }
        var width: CGFloat { maxX - minX }
    }

    /// Where a glyph's advance runs along its baseline, in page space.
    struct Glyph: Equatable {
        var minX: CGFloat
        var maxX: CGFloat
        var baseline: CGFloat
        var em: CGFloat
    }

    struct GlyphLayout {
        var glyphs: [Glyph] = []
        var gaps: [Gap] = []
    }

    /// `page.string` with missing word spaces restored. Cached with the page, since the
    /// selection context asks for the surrounding pages on every selection change.
    static func text(of page: PDFPage) -> String? {
        let entry = cacheEntry(for: page)
        if let cached = entry.withLock({ $0.pageText }) { return cached }
        guard let string = page.string else { return nil }
        let source = string as NSString
        let breaks = wordBreaks(on: page, in: NSRange(location: 0, length: source.length))
        let text = breaks.isEmpty ? string : inserting(breaks, into: source, offset: 0)
        entry.withLock { $0.pageText = text }
        return text
    }

    /// `selection.string` with missing word spaces restored.
    static func text(of selection: PDFSelection) -> String? {
        guard let string = selection.string else { return nil }

        // Characters of the selection in reading order, each flagged when a space
        // belongs after it. PDFKit builds `selection.string` from the same ranges,
        // adding line or page breaks between them.
        var source: [unichar] = []
        var spaceAfter: [Bool] = []
        var hasBreak = false
        for page in selection.pages {
            guard let pageString = page.string as NSString? else { continue }
            for index in 0..<selection.numberOfTextRanges(on: page) {
                let range = selection.range(at: index, on: page)
                guard range.location != NSNotFound,
                      NSMaxRange(range) <= pageString.length else { continue }
                let breaks = Set(wordBreaks(on: page, in: range))
                hasBreak = hasBreak || breaks.isEmpty == false
                for offset in range.location..<NSMaxRange(range) {
                    source.append(pageString.character(at: offset))
                    spaceAfter.append(breaks.contains(offset))
                }
            }
        }
        guard hasBreak else { return string }

        let target = string as NSString
        var result: [unichar] = []
        result.reserveCapacity(target.length + 16)
        var cursor = 0
        for index in 0..<target.length {
            let character = target.character(at: index)
            result.append(character)
            guard cursor < source.count, source[cursor] == character else { continue }
            if spaceAfter[cursor],
               index + 1 < target.length,
               isWhitespace(target.character(at: index + 1)) == false {
                result.append(0x20)
            }
            cursor += 1
        }
        return String(utf16CodeUnits: result, count: result.count)
    }

    /// Offsets in `page.string` after which a space is missing, within `range`.
    static func wordBreaks(on page: PDFPage, in range: NSRange) -> [Int] {
        guard range.length > 1, let string = page.string as NSString? else { return [] }
        let index = glyphIndex(for: page)
        guard index.hasGaps else { return [] }

        let end = min(NSMaxRange(range), string.length)
        let offsets = Array(range.location..<end)
        let boxes: [CGRect?] = offsets.map { offset in
            let character = string.character(at: offset)
            guard isWhitespace(character) == false, UTF16.isTrailSurrogate(character) == false,
                  let bounds = page.selection(for: NSRange(location: offset, length: 1))?.bounds(for: page),
                  bounds.isEmpty == false else { return nil }
            return bounds
        }
        let baselines = boxes.map { $0.flatMap(index.baseline(ofCharacterIn:)) }

        var breaks: [Int] = []
        for position in boxes.indices.dropFirst() {
            guard let left = boxes[position - 1], let right = boxes[position] else { continue }
            // Adjacent on one line: PDFKit makes the boxes of unspaced characters touch.
            let overlap = min(left.maxY, right.maxY) - max(left.minY, right.minY)
            guard overlap > 0, overlap > 0.5 * min(left.height, right.height),
                  abs(right.minX - left.maxX) <= 0.5,
                  let baseline = nearestBaseline(around: position, boxes: boxes, baselines: baselines)
            else { continue }
            if index.containsGap(between: left, and: right, onBaseline: baseline) {
                breaks.append(offsets[position - 1])
            }
        }
        return breaks
    }

    /// The baseline of the line holding the characters at `position - 1` and `position`,
    /// taken from the closest character on that line whose glyph was found.
    private static func nearestBaseline(around position: Int, boxes: [CGRect?], baselines: [CGFloat?]) -> CGFloat? {
        guard let reference = boxes[position] else { return nil }
        func onLine(_ candidate: Int) -> Bool {
            guard let box = boxes[candidate] else { return false }
            return abs(box.minY - reference.minY) <= 0.5 && abs(box.maxY - reference.maxY) <= 0.5
        }
        for distance in 0...12 {
            for candidate in [position - 1 - distance, position + distance]
            where boxes.indices.contains(candidate) && onLine(candidate) {
                if let baseline = baselines[candidate] { return baseline }
            }
        }
        return nil
    }

    private static func inserting(_ breaks: [Int], into source: NSString, offset: Int) -> String {
        var result = ""
        var location = 0
        for index in breaks.sorted() {
            let split = index - offset + 1
            result += source.substring(with: NSRange(location: location, length: split - location))
            result += " "
            location = split
        }
        result += source.substring(from: location)
        return result
    }

    private static func isWhitespace(_ character: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(character) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    // MARK: - Gap index

    struct GlyphIndex {
        /// PDFKit gives each character its glyph's advance and splits a gap exactly in
        /// half, using the same font widths.
        static let tolerance: CGFloat = 0.1
        private static let bucketWidth: CGFloat = 4
        private var gaps: [Int: [Gap]] = [:]
        private var glyphs: [Int: [Glyph]] = [:]

        init(_ layout: GlyphLayout) {
            guard layout.gaps.isEmpty == false else { return }
            for gap in layout.gaps {
                gaps[Self.bucket(gap.midX), default: []].append(gap)
            }
            for glyph in layout.glyphs {
                glyphs[Self.bucket(glyph.minX), default: []].append(glyph)
            }
        }

        var hasGaps: Bool { gaps.isEmpty == false }

        /// The baseline of the glyph whose advance a character's box covers exactly, as
        /// it does inside a word. PDFKit sizes the box from the font's bounding box, so
        /// the box alone can reach the baselines of the lines above and below.
        func baseline(ofCharacterIn box: CGRect) -> CGFloat? {
            let matches = (glyphs[Self.bucket(box.minX)] ?? []).filter { glyph in
                abs(glyph.minX - box.minX) <= Self.tolerance
                    && abs(glyph.maxX - box.maxX) <= Self.tolerance
                    && box.minY <= glyph.baseline && glyph.baseline <= box.maxY
            }
            guard let first = matches.first,
                  matches.allSatisfy({ abs($0.baseline - first.baseline) <= 0.01 * $0.em }) else { return nil }
            return first.baseline
        }

        /// Whether a word gap on `baseline` lies where two touching boxes meet.
        func containsGap(between left: CGRect, and right: CGRect, onBaseline baseline: CGFloat) -> Bool {
            let boundary = (left.maxX + right.minX) / 2
            return (Self.bucket(boundary - 1)...Self.bucket(boundary + 1)).contains { key in
                gaps[key]?.contains { gap in
                    abs(gap.midX - boundary) <= Self.tolerance
                        && abs(gap.baseline - baseline) <= 0.1 * gap.em
                } ?? false
            }
        }

        private static func bucket(_ x: CGFloat) -> Int {
            Int((x / bucketWidth).rounded(.down))
        }
    }

    private struct PageCache {
        var index: GlyphIndex?
        var pageText: String?
    }

    /// Per-page state that lives as long as the `PDFPage`.
    private final class CacheEntry: @unchecked Sendable {
        private let lock = NSLock()
        private var cache = PageCache()

        func withLock<T>(_ body: (inout PageCache) -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body(&cache)
        }
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static let cache = NSMapTable<PDFPage, CacheEntry>(
        keyOptions: .weakMemory,
        valueOptions: .strongMemory
    )

    private static func cacheEntry(for page: PDFPage) -> CacheEntry {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let entry = cache.object(forKey: page) { return entry }
        let entry = CacheEntry()
        cache.setObject(entry, forKey: page)
        return entry
    }

    private static func glyphIndex(for page: PDFPage) -> GlyphIndex {
        let entry = cacheEntry(for: page)
        if let cached = entry.withLock({ $0.index }) { return cached }
        let index = GlyphIndex(page.pageRef.map(layout(of:)) ?? GlyphLayout())
        entry.withLock { $0.index = index }
        return index
    }

    /// Upright glyphs on a page and the word-sized gaps between them, in page space.
    static func layout(of page: CGPDFPage) -> GlyphLayout {
        let scanner = PDFGlyphGapScanner()
        let content = CGPDFContentStreamCreateWithPage(page)
        defer { CGPDFContentStreamRelease(content) }
        scanner.scan(content)
        scanner.endRun()
        return scanner.layout
    }
}

// MARK: - Content stream scanner

private final class PDFGlyphGapScanner {
    private struct FontMetrics {
        var bytesPerCode: Int
        var widths: [Int: CGFloat]
        var defaultWidth: CGFloat?
        /// Glyph space to text space: 1/1000, or a Type3 font's FontMatrix.
        var scale: CGFloat

        func width(of code: Int) -> CGFloat? {
            (widths[code] ?? defaultWidth).map { $0 * scale }
        }
    }

    private struct GraphicsState {
        var transform = CGAffineTransform.identity
        var font: FontMetrics?
        var fontSize: CGFloat = 0
        var characterSpacing: CGFloat = 0
        var wordSpacing: CGFloat = 0
        var horizontalScale: CGFloat = 1
        var leading: CGFloat = 0
        var rise: CGFloat = 0
    }

    private static let maxFormDepth = 8

    /// The spacing from one glyph to the next along a line, and the gap it makes
    /// when wide enough to be a word break.
    private struct Step {
        var distance: CGFloat
        var gap: PDFWordSpacing.Gap?
    }

    private(set) var layout = PDFWordSpacing.GlyphLayout()
    private var previousGlyph: PDFWordSpacing.Glyph?
    private var run: [Step] = []
    private var graphics = GraphicsState()
    private var stack: [GraphicsState] = []
    private var textMatrix = CGAffineTransform.identity
    private var lineMatrix = CGAffineTransform.identity
    private var fonts: [CGPDFDictionaryRef: FontMetrics?] = [:]
    private var depth = 0

    private static func context(_ info: UnsafeMutableRawPointer?) -> PDFGlyphGapScanner {
        Unmanaged<PDFGlyphGapScanner>.fromOpaque(info!).takeUnretainedValue()
    }

    private static func popNumbers(_ scanner: CGPDFScannerRef, count: Int) -> [CGFloat]? {
        var values = [CGFloat](repeating: 0, count: count)
        for index in (0..<count).reversed() {
            var value: CGPDFReal = 0
            guard CGPDFScannerPopNumber(scanner, &value) else { return nil }
            values[index] = value
        }
        return values
    }

    private static func matrix(_ values: [CGFloat]) -> CGAffineTransform {
        CGAffineTransform(a: values[0], b: values[1], c: values[2], d: values[3], tx: values[4], ty: values[5])
    }

    func scan(_ content: CGPDFContentStreamRef) {
        guard let table = CGPDFOperatorTableCreate() else { return }
        defer { CGPDFOperatorTableRelease(table) }

        CGPDFOperatorTableSetCallback(table, "q") { _, info in
            let state = PDFGlyphGapScanner.context(info)
            state.stack.append(state.graphics)
        }
        CGPDFOperatorTableSetCallback(table, "Q") { _, info in
            let state = PDFGlyphGapScanner.context(info)
            if let saved = state.stack.popLast() { state.graphics = saved }
        }
        CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
            guard let values = PDFGlyphGapScanner.popNumbers(scanner, count: 6) else { return }
            let state = PDFGlyphGapScanner.context(info)
            state.graphics.transform = PDFGlyphGapScanner.matrix(values).concatenating(state.graphics.transform)
        }
        CGPDFOperatorTableSetCallback(table, "BT") { _, info in
            let state = PDFGlyphGapScanner.context(info)
            state.textMatrix = .identity
            state.lineMatrix = .identity
        }
        CGPDFOperatorTableSetCallback(table, "Tf") { scanner, info in
            var size: CGPDFReal = 0
            var name: UnsafePointer<CChar>?
            guard CGPDFScannerPopNumber(scanner, &size),
                  CGPDFScannerPopName(scanner, &name), let name else { return }
            let state = PDFGlyphGapScanner.context(info)
            state.graphics.fontSize = size
            state.graphics.font = state.fontMetrics(named: name, in: CGPDFScannerGetContentStream(scanner))
        }
        CGPDFOperatorTableSetCallback(table, "Tc") { scanner, info in
            if let values = PDFGlyphGapScanner.popNumbers(scanner, count: 1) {
                PDFGlyphGapScanner.context(info).graphics.characterSpacing = values[0]
            }
        }
        CGPDFOperatorTableSetCallback(table, "Tw") { scanner, info in
            if let values = PDFGlyphGapScanner.popNumbers(scanner, count: 1) {
                PDFGlyphGapScanner.context(info).graphics.wordSpacing = values[0]
            }
        }
        CGPDFOperatorTableSetCallback(table, "Tz") { scanner, info in
            if let values = PDFGlyphGapScanner.popNumbers(scanner, count: 1) {
                PDFGlyphGapScanner.context(info).graphics.horizontalScale = values[0] / 100
            }
        }
        CGPDFOperatorTableSetCallback(table, "TL") { scanner, info in
            if let values = PDFGlyphGapScanner.popNumbers(scanner, count: 1) {
                PDFGlyphGapScanner.context(info).graphics.leading = values[0]
            }
        }
        CGPDFOperatorTableSetCallback(table, "Ts") { scanner, info in
            if let values = PDFGlyphGapScanner.popNumbers(scanner, count: 1) {
                PDFGlyphGapScanner.context(info).graphics.rise = values[0]
            }
        }
        CGPDFOperatorTableSetCallback(table, "Td") { scanner, info in
            if let values = PDFGlyphGapScanner.popNumbers(scanner, count: 2) {
                PDFGlyphGapScanner.context(info).moveLine(x: values[0], y: values[1])
            }
        }
        CGPDFOperatorTableSetCallback(table, "TD") { scanner, info in
            guard let values = PDFGlyphGapScanner.popNumbers(scanner, count: 2) else { return }
            let state = PDFGlyphGapScanner.context(info)
            state.graphics.leading = -values[1]
            state.moveLine(x: values[0], y: values[1])
        }
        CGPDFOperatorTableSetCallback(table, "Tm") { scanner, info in
            guard let values = PDFGlyphGapScanner.popNumbers(scanner, count: 6) else { return }
            let state = PDFGlyphGapScanner.context(info)
            state.textMatrix = PDFGlyphGapScanner.matrix(values)
            state.lineMatrix = state.textMatrix
        }
        CGPDFOperatorTableSetCallback(table, "T*") { _, info in
            let state = PDFGlyphGapScanner.context(info)
            state.moveLine(x: 0, y: -state.graphics.leading)
        }
        CGPDFOperatorTableSetCallback(table, "Tj") { scanner, info in
            var string: CGPDFStringRef?
            if CGPDFScannerPopString(scanner, &string), let string {
                PDFGlyphGapScanner.context(info).show(string)
            }
        }
        CGPDFOperatorTableSetCallback(table, "'") { scanner, info in
            var string: CGPDFStringRef?
            guard CGPDFScannerPopString(scanner, &string), let string else { return }
            let state = PDFGlyphGapScanner.context(info)
            state.moveLine(x: 0, y: -state.graphics.leading)
            state.show(string)
        }
        CGPDFOperatorTableSetCallback(table, "\"") { scanner, info in
            var string: CGPDFStringRef?
            guard CGPDFScannerPopString(scanner, &string), let string,
                  let values = PDFGlyphGapScanner.popNumbers(scanner, count: 2) else { return }
            let state = PDFGlyphGapScanner.context(info)
            state.graphics.wordSpacing = values[0]
            state.graphics.characterSpacing = values[1]
            state.moveLine(x: 0, y: -state.graphics.leading)
            state.show(string)
        }
        CGPDFOperatorTableSetCallback(table, "TJ") { scanner, info in
            var array: CGPDFArrayRef?
            guard CGPDFScannerPopArray(scanner, &array), let array else { return }
            let state = PDFGlyphGapScanner.context(info)
            for index in 0..<CGPDFArrayGetCount(array) {
                var string: CGPDFStringRef?
                var adjustment: CGPDFReal = 0
                if CGPDFArrayGetString(array, index, &string), let string {
                    state.show(string)
                } else if CGPDFArrayGetNumber(array, index, &adjustment) {
                    state.advance(by: -adjustment / 1000 * state.graphics.fontSize * state.graphics.horizontalScale)
                }
            }
        }
        CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
            PDFGlyphGapScanner.context(info).drawXObject(scanner)
        }

        let scanner = CGPDFScannerCreate(content, table, Unmanaged.passUnretained(self).toOpaque())
        defer { CGPDFScannerRelease(scanner) }
        CGPDFScannerScan(scanner)
    }

    private func moveLine(x: CGFloat, y: CGFloat) {
        lineMatrix = CGAffineTransform(translationX: x, y: y).concatenating(lineMatrix)
        textMatrix = lineMatrix
    }

    private func advance(by distance: CGFloat) {
        textMatrix = CGAffineTransform(translationX: distance, y: 0).concatenating(textMatrix)
    }

    private func show(_ string: CGPDFStringRef) {
        guard let bytes = CGPDFStringGetBytePtr(string) else { return }
        let length = CGPDFStringGetLength(string)
        guard let font = graphics.font, graphics.fontSize != 0 else {
            endRun()
            return
        }

        var index = 0
        while index + font.bytesPerCode <= length {
            var code = 0
            for byte in 0..<font.bytesPerCode {
                code = code << 8 | Int(bytes[index + byte])
            }
            index += font.bytesPerCode
            guard let width = font.width(of: code) else {
                endRun()
                continue
            }
            showGlyph(width: width, isSpace: font.bytesPerCode == 1 && code == 32)
        }
    }

    private func showGlyph(width: CGFloat, isSpace: Bool) {
        let size = graphics.fontSize
        let scale = graphics.horizontalScale
        let rendering = textMatrix.concatenating(graphics.transform)
        let origin = CGPoint(x: 0, y: graphics.rise).applying(rendering)
        let inkEnd = CGPoint(x: width * size * scale, y: graphics.rise).applying(rendering)
        let spacing = graphics.characterSpacing + (isSpace ? graphics.wordSpacing : 0)
        advance(by: (width * size + spacing) * scale)

        // Upright, left-to-right text only, as PDFKit's boxes are compared along x.
        let em = abs(size) * hypot(rendering.c, rendering.d)
        let directionLength = hypot(rendering.a, rendering.b)
        guard em > 0, directionLength > 0,
              rendering.a / directionLength > 0.999,
              inkEnd.x >= origin.x else {
            endRun()
            return
        }
        let glyph = PDFWordSpacing.Glyph(minX: origin.x, maxX: inkEnd.x, baseline: origin.y, em: em)
        layout.glyphs.append(glyph)

        if let previous = previousGlyph {
            let distance = glyph.minX - previous.maxX
            if abs(glyph.baseline - previous.baseline) < 0.3 * em, distance > -0.5 * em {
                let isWide = distance >= PDFWordSpacing.minimumGapEm * min(em, previous.em)
                run.append(Step(distance: distance, gap: isWide ? PDFWordSpacing.Gap(
                    minX: previous.maxX,
                    maxX: glyph.minX,
                    baseline: (previous.baseline + glyph.baseline) / 2,
                    em: min(em, previous.em)
                ) : nil))
            } else {
                endRun()
            }
        }
        previousGlyph = glyph
    }

    /// Keeps the gaps of a line that stand out from its usual glyph spacing, so
    /// letterspaced headings and digits set one by one in tables stay whole.
    func endRun() {
        defer {
            run.removeAll(keepingCapacity: true)
            previousGlyph = nil
        }
        for (index, step) in run.enumerated() {
            guard let gap = step.gap else { continue }
            let window = max(0, index - 6)...min(run.count - 1, index + 6)
            let neighbours = window.filter { $0 != index }.map { run[$0].distance }.sorted()
            let usual = neighbours.isEmpty ? 0 : max(0, neighbours[neighbours.count / 4])
            if gap.width - usual >= 0.1 * gap.em {
                layout.gaps.append(gap)
            }
        }
    }

    private func drawXObject(_ scanner: CGPDFScannerRef) {
        var name: UnsafePointer<CChar>?
        let parent = CGPDFScannerGetContentStream(scanner)
        guard depth < Self.maxFormDepth,
              CGPDFScannerPopName(scanner, &name), let name,
              let object = CGPDFContentStreamGetResource(parent, "XObject", name) else { return }
        var stream: CGPDFStreamRef?
        guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
              let dictionary = CGPDFStreamGetDictionary(stream),
              Self.name(in: dictionary, key: "Subtype") == "Form" else { return }

        endRun()
        let saved = (graphics, stack, textMatrix, lineMatrix)
        var matrix: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(dictionary, "Matrix", &matrix), let matrix,
           let values = Self.numbers(in: matrix), values.count == 6 {
            graphics.transform = Self.matrix(values).concatenating(graphics.transform)
        }
        var resources: CGPDFDictionaryRef?
        CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources)
        // Without its own resources a form uses its parent's, which resource lookups
        // reach through `parent`; the form dictionary itself has no Font entry.
        let content = CGPDFContentStreamCreateWithStream(stream, resources ?? dictionary, parent)
        defer { CGPDFContentStreamRelease(content) }
        depth += 1
        scan(content)
        depth -= 1
        (graphics, stack, textMatrix, lineMatrix) = saved
        endRun()
    }

    // MARK: Fonts

    private func fontMetrics(named name: UnsafePointer<CChar>, in content: CGPDFContentStreamRef) -> FontMetrics? {
        var dictionary: CGPDFDictionaryRef?
        guard let object = CGPDFContentStreamGetResource(content, "Font", name),
              CGPDFObjectGetValue(object, .dictionary, &dictionary),
              let dictionary else { return nil }
        let key = dictionary
        if let cached = fonts[key] { return cached }
        let metrics = Self.metrics(of: dictionary)
        fonts[key] = metrics
        return metrics
    }

    private static func metrics(of font: CGPDFDictionaryRef) -> FontMetrics? {
        switch name(in: font, key: "Subtype") {
        case "Type0":
            return compositeMetrics(of: font)
        case "Type1", "MMType1", "TrueType", "Type3":
            break
        default:
            return nil
        }

        // Standard 14 fonts may omit Widths; PDFKit knows their real spaces anyway.
        var widthsArray: CGPDFArrayRef?
        var firstChar: CGPDFInteger = 0
        guard CGPDFDictionaryGetArray(font, "Widths", &widthsArray), let widthsArray,
              CGPDFDictionaryGetInteger(font, "FirstChar", &firstChar),
              let values = numbers(in: widthsArray) else { return nil }
        var widths: [Int: CGFloat] = [:]
        for (offset, width) in values.enumerated() {
            widths[firstChar + offset] = width
        }

        var missingWidth: CGFloat?
        var descriptor: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(font, "FontDescriptor", &descriptor), let descriptor {
            var value: CGPDFReal = 0
            if CGPDFDictionaryGetNumber(descriptor, "MissingWidth", &value), value > 0 {
                missingWidth = value
            }
        }

        var scale: CGFloat = 0.001
        if name(in: font, key: "Subtype") == "Type3" {
            var fontMatrix: CGPDFArrayRef?
            guard CGPDFDictionaryGetArray(font, "FontMatrix", &fontMatrix), let fontMatrix,
                  let matrix = numbers(in: fontMatrix), matrix.count == 6, matrix[0] != 0 else { return nil }
            scale = matrix[0]
        }
        return FontMetrics(bytesPerCode: 1, widths: widths, defaultWidth: missingWidth, scale: scale)
    }

    /// Identity-H CID fonts; other CMaps would need parsing to split codes.
    private static func compositeMetrics(of font: CGPDFDictionaryRef) -> FontMetrics? {
        guard name(in: font, key: "Encoding") == "Identity-H" else { return nil }
        var descendants: CGPDFArrayRef?
        var descendant: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetArray(font, "DescendantFonts", &descendants), let descendants,
              CGPDFArrayGetDictionary(descendants, 0, &descendant), let descendant else { return nil }

        var defaultWidth: CGPDFReal = 1000
        CGPDFDictionaryGetNumber(descendant, "DW", &defaultWidth)
        var widths: [Int: CGFloat] = [:]
        var widthArray: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(descendant, "W", &widthArray), let widthArray {
            let count = CGPDFArrayGetCount(widthArray)
            var index = 0
            while index < count {
                var first: CGPDFInteger = 0
                guard CGPDFArrayGetInteger(widthArray, index, &first) else { break }
                var list: CGPDFArrayRef?
                if CGPDFArrayGetArray(widthArray, index + 1, &list), let list,
                   let values = numbers(in: list) {
                    for (offset, width) in values.enumerated() {
                        widths[first + offset] = width
                    }
                    index += 2
                } else {
                    var last: CGPDFInteger = 0
                    var width: CGPDFReal = 0
                    guard CGPDFArrayGetInteger(widthArray, index + 1, &last),
                          CGPDFArrayGetNumber(widthArray, index + 2, &width),
                          last >= first, last - first < 65_536 else { break }
                    for code in first...last {
                        widths[code] = width
                    }
                    index += 3
                }
            }
        }
        return FontMetrics(bytesPerCode: 2, widths: widths, defaultWidth: defaultWidth, scale: 0.001)
    }

    private static func numbers(in array: CGPDFArrayRef) -> [CGFloat]? {
        var values: [CGFloat] = []
        for index in 0..<CGPDFArrayGetCount(array) {
            var value: CGPDFReal = 0
            guard CGPDFArrayGetNumber(array, index, &value) else { return nil }
            values.append(value)
        }
        return values
    }

    private static func name(in dictionary: CGPDFDictionaryRef, key: String) -> String? {
        var value: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dictionary, key, &value), let value else { return nil }
        return String(cString: value)
    }
}
