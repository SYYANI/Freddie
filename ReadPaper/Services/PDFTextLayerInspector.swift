import CoreGraphics
import Foundation

/// Detects PDFs whose text cannot be recovered as Unicode, such as scanned
/// pages without an OCR layer or dvips/Distiller bitmap Type3 fonts that number
/// glyphs in first-use order without a `ToUnicode` map. Translating those files
/// only sends gibberish to the LLM, so PDF translation is refused up front.
///
/// Hidden OCR text over a page-sized scan is not a typeset text layer either,
/// nor is the short "Downloaded from …" stamp archives draw on every scanned
/// page. Otherwise, font decoding remains conservative.
struct PDFTextLayerInspector {
    enum Verdict: Equatable {
        case extractable
        case noFonts
        case undecodableFonts
        case scannedWithOCR
        /// Most pages are scans whose only text is a short visible stamp.
        case scannedWithoutOCR
    }

    private enum FontDecodability {
        case decodable
        case undecodable
        case empty
    }

    private static let maxFormDepth = 8

    func requireExtractableText(at url: URL) throws {
        guard let verdict = inspect(documentAt: url), verdict != .extractable else { return }
        if verdict == .scannedWithOCR { throw PDFTextLayerError.scannedWithOCR }
        throw PDFTextLayerError.noExtractableText
    }

    /// Returns `nil` when the file cannot be opened; callers then leave error
    /// reporting to the translation tool itself.
    func inspect(documentAt url: URL) -> Verdict? {
        guard let document = CGPDFDocument(url as CFURL) else { return nil }
        return inspect(document)
    }

    func inspect(_ document: CGPDFDocument) -> Verdict {
        guard document.numberOfPages > 0 else { return .extractable }

        var state = ScanState()
        var scannedPages = 0
        for pageNumber in 1...document.numberOfPages {
            guard let page = document.page(at: pageNumber),
                  let pageDictionary = page.dictionary,
                  let resources = Self.inheritedResources(of: pageDictionary) else { continue }
            switch PDFOCRScanInspector.classify(page, resources: resources) {
            case .scanWithOCR: return .scannedWithOCR
            case .scan: scannedPages += 1
            case .other: break
            }
            if !state.hasDecodableFont {
                scan(resources: resources, depth: 0, state: &state)
            }
        }
        guard state.hasDecodableFont else { return state.hasFont ? .undecodableFonts : .noFonts }
        // A stamp's font decodes fine, so count scanned pages instead. A majority keeps
        // a typeset paper with a full-page figure enabled and still catches the scans
        // behind a typeset cover page (JSTOR).
        return scannedPages * 2 > document.numberOfPages ? .scannedWithoutOCR : .extractable
    }

    private struct ScanState {
        var visitedResources = Set<CGPDFDictionaryRef>()
        var visitedFonts = Set<CGPDFDictionaryRef>()
        var hasFont = false
        var hasDecodableFont = false
    }

    private func scan(resources: CGPDFDictionaryRef, depth: Int, state: inout ScanState) {
        guard state.visitedResources.insert(resources).inserted else { return }

        var fonts: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(resources, "Font", &fonts), let fonts {
            for object in Self.values(of: fonts) {
                var font: CGPDFDictionaryRef?
                guard CGPDFObjectGetValue(object, .dictionary, &font), let font,
                      state.visitedFonts.insert(font).inserted else { continue }
                switch Self.decodability(of: font) {
                case .decodable:
                    state.hasFont = true
                    state.hasDecodableFont = true
                    return
                case .undecodable:
                    state.hasFont = true
                case .empty:
                    break
                }
            }
        }

        guard depth < Self.maxFormDepth else { return }
        var xObjects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, "XObject", &xObjects), let xObjects else { return }
        for object in Self.values(of: xObjects) {
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
                  let streamDictionary = CGPDFStreamGetDictionary(stream),
                  Self.name(in: streamDictionary, key: "Subtype") == "Form" else { continue }
            var formResources: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(streamDictionary, "Resources", &formResources), let formResources {
                scan(resources: formResources, depth: depth + 1, state: &state)
                if state.hasDecodableFont { return }
            }
        }
    }

    private static func decodability(of font: CGPDFDictionaryRef) -> FontDecodability {
        var toUnicode: CGPDFObjectRef?
        if CGPDFDictionaryGetObject(font, "ToUnicode", &toUnicode) { return .decodable }
        guard name(in: font, key: "Subtype") == "Type3" else { return .decodable }

        var charProcs: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(font, "CharProcs", &charProcs), let charProcs else { return .empty }
        let glyphNames = Set(keys(of: charProcs))
        guard !glyphNames.isEmpty else { return .empty }

        var encoding: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(font, "Encoding", &encoding), let encoding else {
            // A named standard encoding maps codes to well-known glyph names.
            return name(in: font, key: "Encoding") == nil ? .undecodable : .decodable
        }
        var differences: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(encoding, "Differences", &differences), let differences else {
            return name(in: encoding, key: "BaseEncoding") == nil ? .undecodable : .decodable
        }

        let definedGlyphs = differenceEntries(differences).filter { glyphNames.contains($0.name) }
        guard !definedGlyphs.isEmpty else { return .empty }

        let meaningfulNames = definedGlyphs.filter { PDFGlyphName.isMeaningful($0.name) }.count
        if meaningfulNames * 2 >= definedGlyphs.count { return .decodable }

        // pdfTeX-style bitmap fonts keep TeX code positions (`/a65` at code 65),
        // so the raw codes still decode to plausible Latin letters.
        let letterCodes = definedGlyphs.filter {
            (65...90).contains($0.code) || (97...122).contains($0.code)
        }.count
        if letterCodes * 2 >= definedGlyphs.count { return .decodable }

        return .undecodable
    }

    private static func differenceEntries(_ array: CGPDFArrayRef) -> [(code: Int, name: String)] {
        var entries: [(code: Int, name: String)] = []
        var code = 0
        for index in 0..<CGPDFArrayGetCount(array) {
            var integer: CGPDFInteger = 0
            var namePointer: UnsafePointer<CChar>?
            if CGPDFArrayGetInteger(array, index, &integer) {
                code = Int(integer)
            } else if CGPDFArrayGetName(array, index, &namePointer), let namePointer {
                entries.append((code, String(cString: namePointer)))
                code += 1
            }
        }
        return entries
    }

    private static func inheritedResources(of pageDictionary: CGPDFDictionaryRef) -> CGPDFDictionaryRef? {
        var node: CGPDFDictionaryRef? = pageDictionary
        var remainingDepth = 32
        while let current = node, remainingDepth > 0 {
            var resources: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(current, "Resources", &resources), let resources {
                return resources
            }
            var parent: CGPDFDictionaryRef?
            node = CGPDFDictionaryGetDictionary(current, "Parent", &parent) ? parent : nil
            remainingDepth -= 1
        }
        return nil
    }

    private static func name(in dictionary: CGPDFDictionaryRef, key: String) -> String? {
        var value: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dictionary, key, &value), let value else { return nil }
        return String(cString: value)
    }

    private static func keys(of dictionary: CGPDFDictionaryRef) -> [String] {
        var keys: [String] = []
        CGPDFDictionaryApplyBlock(dictionary, { key, _, _ in
            keys.append(String(cString: key))
            return true
        }, nil)
        return keys
    }

    private static func values(of dictionary: CGPDFDictionaryRef) -> [CGPDFObjectRef] {
        var values: [CGPDFObjectRef] = []
        CGPDFDictionaryApplyBlock(dictionary, { _, value, _ in
            values.append(value)
            return true
        }, nil)
        return values
    }
}

/// Reads drawing operators without rendering images or extracting full text.
/// Require an actually painted page-sized image and at most a stamp's worth of
/// visible text, so figures, unused image resources and ordinary text pages stay enabled.
private final class PDFOCRScanInspector {
    enum PageKind {
        case scanWithOCR
        case scan
        case other
    }

    /// Archive stamps ("Downloaded from … by guest on …", JSTOR's terms line) run
    /// about 100–150 characters, two bytes each in CID fonts; a typeset page has thousands.
    private static let maxStampTextLength = 400

    private struct GraphicsState {
        var transform = CGAffineTransform.identity
        var textRenderingMode = 0
    }

    private var graphics = GraphicsState()
    private var stack: [GraphicsState] = []
    private var hasHiddenText = false
    private var visibleTextLength = 0
    private var hasPageImage = false
    private var complete = true
    private let pageBounds: CGRect
    private let depth: Int
    private let resources: CGPDFDictionaryRef

    private init(pageBounds: CGRect, resources: CGPDFDictionaryRef, depth: Int = 0) {
        self.pageBounds = pageBounds
        self.depth = depth
        self.resources = resources
    }

    static func classify(_ page: CGPDFPage, resources: CGPDFDictionaryRef) -> PageKind {
        let inspector = PDFOCRScanInspector(pageBounds: page.getBoxRect(.cropBox), resources: resources)
        let content = CGPDFContentStreamCreateWithPage(page)
        defer { CGPDFContentStreamRelease(content) }
        inspector.scan(content)
        guard inspector.complete, inspector.hasPageImage,
              inspector.visibleTextLength <= maxStampTextLength else { return .other }
        return inspector.hasHiddenText ? .scanWithOCR : .scan
    }

    private static func context(_ info: UnsafeMutableRawPointer?) -> PDFOCRScanInspector {
        Unmanaged<PDFOCRScanInspector>.fromOpaque(info!).takeUnretainedValue()
    }

    private func recordText(_ string: CGPDFStringRef) {
        let length = CGPDFStringGetLength(string)
        guard length > 0 else { return }
        if graphics.textRenderingMode == 3 {
            hasHiddenText = true
        } else {
            visibleTextLength += length
        }
    }

    private func scan(_ content: CGPDFContentStreamRef) {
        guard let table = CGPDFOperatorTableCreate() else { complete = false; return }
        defer { CGPDFOperatorTableRelease(table) }
        CGPDFOperatorTableSetCallback(table, "q") { _, info in
            let state = PDFOCRScanInspector.context(info)
            state.stack.append(state.graphics)
        }
        CGPDFOperatorTableSetCallback(table, "Q") { _, info in
            let state = PDFOCRScanInspector.context(info)
            if let saved = state.stack.popLast() { state.graphics = saved }
        }
        CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
            var values = [CGPDFReal](repeating: 0, count: 6)
            for index in (0..<6).reversed() {
                guard CGPDFScannerPopNumber(scanner, &values[index]) else { return }
            }
            let state = PDFOCRScanInspector.context(info)
            state.graphics.transform = CGAffineTransform(
                a: values[0], b: values[1], c: values[2],
                d: values[3], tx: values[4], ty: values[5]
            ).concatenating(state.graphics.transform)
        }
        CGPDFOperatorTableSetCallback(table, "Tr") { scanner, info in
            var mode: CGPDFInteger = 0
            if CGPDFScannerPopInteger(scanner, &mode) {
                PDFOCRScanInspector.context(info).graphics.textRenderingMode = mode
            }
        }
        for name in ["Tj", "'", "\""] {
            CGPDFOperatorTableSetCallback(table, name) { scanner, info in
                var string: CGPDFStringRef?
                if CGPDFScannerPopString(scanner, &string), let string {
                    PDFOCRScanInspector.context(info).recordText(string)
                }
            }
        }
        CGPDFOperatorTableSetCallback(table, "TJ") { scanner, info in
            var array: CGPDFArrayRef?
            guard CGPDFScannerPopArray(scanner, &array), let array else { return }
            for index in 0..<CGPDFArrayGetCount(array) {
                var string: CGPDFStringRef?
                if CGPDFArrayGetString(array, index, &string), let string {
                    PDFOCRScanInspector.context(info).recordText(string)
                }
            }
        }
        CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
            PDFOCRScanInspector.context(info).drawXObject(scanner)
        }
        let scanner = CGPDFScannerCreate(content, table, Unmanaged.passUnretained(self).toOpaque())
        defer { CGPDFScannerRelease(scanner) }
        if !CGPDFScannerScan(scanner) { complete = false }
    }

    private func drawXObject(_ scanner: CGPDFScannerRef) {
        var name: UnsafePointer<CChar>?
        let parent = CGPDFScannerGetContentStream(scanner)
        guard CGPDFScannerPopName(scanner, &name), let name,
              let object = CGPDFContentStreamGetResource(parent, "XObject", name) else { return }
        var stream: CGPDFStreamRef?
        guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
              let dictionary = CGPDFStreamGetDictionary(stream) else { return }
        var subtype: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype else { return }
        switch String(cString: subtype) {
        case "Image":
            var isMask: CGPDFBoolean = 0
            CGPDFDictionaryGetBoolean(dictionary, "ImageMask", &isMask)
            guard isMask == 0, pageBounds.width > 0, pageBounds.height > 0 else { return }
            let drawn = CGRect(x: 0, y: 0, width: 1, height: 1)
                .applying(graphics.transform).intersection(pageBounds)
            if !drawn.isNull, drawn.width * drawn.height >= pageBounds.width * pageBounds.height * 0.8 {
                hasPageImage = true
            }
        case "Form":
            guard depth < 8 else { complete = false; return }
            var formResources: CGPDFDictionaryRef?
            CGPDFDictionaryGetDictionary(dictionary, "Resources", &formResources)
            let child = PDFOCRScanInspector(
                pageBounds: pageBounds, resources: formResources ?? resources, depth: depth + 1
            )
            child.graphics = graphics
            var matrix: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(dictionary, "Matrix", &matrix), let matrix,
               CGPDFArrayGetCount(matrix) == 6 {
                var values = [CGPDFReal](repeating: 0, count: 6)
                for index in 0..<6 { CGPDFArrayGetNumber(matrix, index, &values[index]) }
                child.graphics.transform = CGAffineTransform(
                    a: values[0], b: values[1], c: values[2],
                    d: values[3], tx: values[4], ty: values[5]
                ).concatenating(graphics.transform)
            }
            let content = CGPDFContentStreamCreateWithStream(stream, child.resources, parent)
            defer { CGPDFContentStreamRelease(content) }
            child.scan(content)
            hasHiddenText = hasHiddenText || child.hasHiddenText
            visibleTextLength += child.visibleTextLength
            hasPageImage = hasPageImage || child.hasPageImage
            complete = complete && child.complete
        default:
            break
        }
    }
}

enum PDFGlyphName {
    private static let knownNames: Set<String> = [
        "space", "exclam", "quotedbl", "numbersign", "dollar", "percent", "ampersand",
        "quoteright", "quotesingle", "parenleft", "parenright", "asterisk", "plus", "comma",
        "hyphen", "period", "slash", "zero", "one", "two", "three", "four", "five", "six",
        "seven", "eight", "nine", "colon", "semicolon", "less", "equal", "greater", "question",
        "at", "bracketleft", "backslash", "bracketright", "asciicircum", "underscore",
        "quoteleft", "grave", "braceleft", "bar", "braceright", "asciitilde", "ff", "fi", "fl",
        "ffi", "ffl", "endash", "emdash", "bullet", "quotedblleft", "quotedblright",
        "quotedblbase", "quotesinglbase", "ellipsis", "dotlessi", "dotlessj", "germandbls",
        "ae", "AE", "oe", "OE", "oslash", "Oslash", "lslash", "Lslash", "eth", "Eth", "thorn",
        "Thorn", "minus", "multiply", "divide", "degree", "section", "paragraph", "dagger",
        "daggerdbl", "copyright", "registered", "trademark",
    ]

    private static let accentSuffixes = [
        "acute", "grave", "circumflex", "dieresis", "tilde", "cedilla", "ring", "caron",
        "macron", "breve", "ogonek", "dotaccent", "hungarumlaut",
    ]

    /// Whether a glyph name follows Adobe Glyph List conventions closely enough
    /// to recover Unicode text from it.
    static func isMeaningful(_ glyphName: String) -> Bool {
        let base = glyphName.split(separator: ".", omittingEmptySubsequences: false).first ?? ""
        let component = String(base.split(separator: "_", omittingEmptySubsequences: false).first ?? "")
        guard !component.isEmpty else { return false }

        if component.count == 1, let scalar = component.unicodeScalars.first,
           scalar.isASCII, CharacterSet.letters.contains(scalar) {
            return true
        }
        if knownNames.contains(component) { return true }
        if isHexSuffixed(component, prefix: "uni", lengths: 4...4) { return true }
        if isHexSuffixed(component, prefix: "u", lengths: 4...6) { return true }
        for suffix in accentSuffixes where component.hasSuffix(suffix) {
            let letters = component.dropLast(suffix.count)
            if (1...2).contains(letters.count), letters.allSatisfy({ $0.isASCII && $0.isLetter }) {
                return true
            }
        }
        return false
    }

    private static func isHexSuffixed(
        _ name: String,
        prefix: String,
        lengths: ClosedRange<Int>
    ) -> Bool {
        guard name.hasPrefix(prefix) else { return false }
        let digits = name.dropFirst(prefix.count)
        return lengths.contains(digits.count) && digits.allSatisfy(\.isHexDigit)
    }
}

enum PDFTextLayerError: LocalizedError, Equatable {
    case noExtractableText
    case scannedWithOCR

    var errorDescription: String? {
        switch self {
        case .noExtractableText:
            AppLocalization.localized(
                "This PDF has no extractable text layer (for example, scanned pages or bitmap fonts without character mapping). PDF translation is not supported for it."
            )
        case .scannedWithOCR:
            AppLocalization.localized(
                "This PDF uses scanned page images with an OCR text layer. Use Translate Scanned PDF instead."
            )
        }
    }
}
