import CoreGraphics
import Foundation

/// Detects PDFs whose text cannot be recovered as Unicode, such as scanned
/// pages without an OCR layer or dvips/Distiller bitmap Type3 fonts that number
/// glyphs in first-use order without a `ToUnicode` map. Translating those files
/// only sends gibberish to the LLM, so PDF translation is refused up front.
///
/// The check is deliberately conservative: a document is rejected only when no
/// page uses a font whose text could plausibly be decoded.
struct PDFTextLayerInspector {
    enum Verdict: Equatable {
        case extractable
        case noFonts
        case undecodableFonts
    }

    private enum FontDecodability {
        case decodable
        case undecodable
        case empty
    }

    private static let maxFormDepth = 8

    func requireExtractableText(at url: URL) throws {
        guard let verdict = inspect(documentAt: url), verdict != .extractable else { return }
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
        for pageNumber in 1...document.numberOfPages {
            guard let pageDictionary = document.page(at: pageNumber)?.dictionary,
                  let resources = Self.inheritedResources(of: pageDictionary) else { continue }
            scan(resources: resources, depth: 0, state: &state)
            if state.hasDecodableFont { return .extractable }
        }
        return state.hasFont ? .undecodableFonts : .noFonts
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

    var errorDescription: String? {
        switch self {
        case .noExtractableText:
            AppLocalization.localized(
                "This PDF has no extractable text layer (for example, scanned pages or bitmap fonts without character mapping). PDF translation is not supported for it."
            )
        }
    }
}
