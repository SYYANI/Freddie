import Foundation
import PDFKit
import SwiftSoup

enum PaperSearchBlockKind: String, Codable, Sendable {
    case heading
    case paragraph
    case figureCaption
    case blockquote
    case listItem
    case pdfPage
}

struct PaperSearchBlock: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var kind: PaperSearchBlockKind
    var text: String
    var sectionPath: [String]
    var attachmentID: UUID
    var pageIndex: Int?
    var htmlSelector: String?
    var ordinal: Int
}

struct PaperFullTextIndex: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int
    var paperID: UUID
    var sourceFingerprint: String
    var blocks: [PaperSearchBlock]
    var createdAt: Date
}

struct PaperSearchHit: Equatable, Sendable {
    var block: PaperSearchBlock
    var previousBlocks: [PaperSearchBlock]
    var nextBlocks: [PaperSearchBlock]
    var score: Double

    var contextualText: String {
        (previousBlocks + [block] + nextBlocks)
            .map(\.text)
            .joined(separator: "\n\n")
    }
}

/// A local, deterministic keyword index. HTML remains the structural source of
/// truth; PDF page strings are only used as low-confidence recall hints when an
/// HTML attachment is unavailable.
@MainActor
struct PaperFullTextSearchService {
    static let htmlSemanticSelector = "h1, h2, h3, h4, h5, h6, p, figcaption, blockquote, li"
    static let assistantBlockAttribute = "data-rp-assistant-block-id"

    let fileStore: PaperFileStore

    init(fileStore: PaperFileStore = PaperFileStore()) {
        self.fileStore = fileStore
    }

    func rebuild(
        paper: Paper,
        attachments: [PaperAttachment]
    ) throws -> PaperFullTextIndex? {
        if let htmlAttachment = attachments.first(where: { $0.kind == .html }),
           fileStore.fileManager.fileExists(atPath: htmlAttachment.resolvedFileURL(fileStore: fileStore).path) {
            let index = try makeHTMLIndex(paper: paper, attachment: htmlAttachment)
            try persist(index)
            return index
        }

        if let pdfAttachment = attachments.first(where: { $0.kind == .pdf }),
           fileStore.fileManager.fileExists(atPath: pdfAttachment.resolvedFileURL(fileStore: fileStore).path) {
            let index = try makePDFIndex(paper: paper, attachment: pdfAttachment)
            try persist(index)
            return index
        }

        return nil
    }

    func loadOrRebuild(
        paper: Paper,
        attachments: [PaperAttachment]
    ) throws -> PaperFullTextIndex? {
        let preferredAttachment = attachments.first(where: { $0.kind == .html })
            ?? attachments.first(where: { $0.kind == .pdf })
        guard let preferredAttachment else { return nil }

        let fingerprint = try sourceFingerprint(for: preferredAttachment)
        if let cached = try load(paperID: paper.id),
           cached.version == PaperFullTextIndex.currentVersion,
           cached.paperID == paper.id,
           cached.sourceFingerprint == fingerprint {
            return cached
        }
        return try rebuild(paper: paper, attachments: attachments)
    }

    func search(
        query: String,
        in index: PaperFullTextIndex,
        topK: Int = 4,
        adjacentBlockCount: Int = 1
    ) -> [PaperSearchHit] {
        let normalizedTopK = max(1, min(topK, 12))
        let terms = Self.searchTerms(in: query)
        guard terms.isEmpty == false, index.blocks.isEmpty == false else { return [] }

        let documentFrequency = Dictionary(uniqueKeysWithValues: terms.map { term in
            let count = index.blocks.reduce(into: 0) { partialResult, block in
                if Self.normalized(block.text).contains(term) ||
                    Self.normalized(block.sectionPath.joined(separator: " ")).contains(term) {
                    partialResult += 1
                }
            }
            return (term, count)
        })
        let blockCount = Double(index.blocks.count)
        let normalizedQuery = Self.normalized(query)

        var ranked = index.blocks.compactMap { block -> (PaperSearchBlock, Double)? in
            let text = Self.normalized(block.text)
            let section = Self.normalized(block.sectionPath.joined(separator: " "))
            var score = 0.0

            for term in terms {
                let frequency = Double(Self.occurrenceCount(of: term, in: text))
                let sectionFrequency = Double(Self.occurrenceCount(of: term, in: section))
                guard frequency > 0 || sectionFrequency > 0 else { continue }
                let frequencyInDocuments = Double(documentFrequency[term] ?? 0)
                let inverseDocumentFrequency = log((blockCount + 1) / (frequencyInDocuments + 1)) + 1
                score += inverseDocumentFrequency * (min(frequency, 4) + sectionFrequency * 1.8)
            }

            if normalizedQuery.count >= 4, text.contains(normalizedQuery) {
                score += 8
            }
            if block.kind == .heading {
                score *= 1.15
            }
            // PDF strings can have broken reading order, so they intentionally
            // rank below structured HTML blocks for an otherwise equal match.
            if block.kind == .pdfPage {
                score *= 0.82
            }
            return score > 0 ? (block, score) : nil
        }
        ranked.sort {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            return $0.0.ordinal < $1.0.ordinal
        }

        var selected: [(PaperSearchBlock, Double)] = []
        for candidate in ranked {
            let isNearExistingHit = selected.contains { existing in
                existing.0.attachmentID == candidate.0.attachmentID &&
                    abs(existing.0.ordinal - candidate.0.ordinal) <= adjacentBlockCount
            }
            if isNearExistingHit == false {
                selected.append(candidate)
            }
            if selected.count == normalizedTopK { break }
        }

        let neighborCount = max(0, min(adjacentBlockCount, 2))
        return selected.map { block, score in
            let matchingBlocks = index.blocks.filter { $0.attachmentID == block.attachmentID }
            guard let position = matchingBlocks.firstIndex(where: { $0.id == block.id }) else {
                return PaperSearchHit(block: block, previousBlocks: [], nextBlocks: [], score: score)
            }
            let previousStart = max(0, position - neighborCount)
            let nextEnd = min(matchingBlocks.count, position + neighborCount + 1)
            return PaperSearchHit(
                block: block,
                previousBlocks: Array(matchingBlocks[previousStart..<position]),
                nextBlocks: Array(matchingBlocks[(position + 1)..<nextEnd]),
                score: score
            )
        }
    }

    static func canKeywordMatch(query: String, in index: PaperFullTextIndex) -> Bool {
        let terms = searchTerms(in: query)
        guard terms.isEmpty == false, index.blocks.isEmpty == false else { return false }

        let queryIsOnlyCJK = terms.allSatisfy { term in
            term.unicodeScalars.allSatisfy(isCJKScalar)
        }
        guard queryIsOnlyCJK else { return true }

        return index.blocks.contains { block in
            normalized(block.text).unicodeScalars.contains(where: isCJKScalar)
        }
    }

    static func relevanceScore(query: String, text: String, title: String = "") -> Double {
        let terms = searchTerms(in: query)
        guard terms.isEmpty == false else { return 0 }
        let normalizedText = normalized(text)
        let normalizedTitle = normalized(title)
        return terms.reduce(0) { partialResult, term in
            partialResult
                + Double(occurrenceCount(of: term, in: normalizedText))
                + Double(occurrenceCount(of: term, in: normalizedTitle)) * 1.8
        }
    }

    private func makeHTMLIndex(
        paper: Paper,
        attachment: PaperAttachment
    ) throws -> PaperFullTextIndex {
        let url = attachment.resolvedFileURL(fileStore: fileStore)
        let html = try String(contentsOf: url, encoding: .utf8)
        let document = try SwiftSoup.parse(html)
        let elements = try document.select(Self.htmlSemanticSelector).array()
        var blocks: [PaperSearchBlock] = []
        var sectionStack: [String] = []
        var didModifyDocument = false

        for element in elements {
            if try Self.isTranslationElement(element) || Self.hasSemanticDescendant(element) {
                continue
            }
            let text = try Self.normalizedVisibleText(element)
            let tagName = element.tagName().lowercased()
            let minimumLength = tagName.hasPrefix("h") ? 2 : 4
            guard text.count >= minimumLength else { continue }

            if let headingLevel = Self.headingLevel(tagName) {
                if sectionStack.count >= headingLevel {
                    sectionStack.removeSubrange((headingLevel - 1)..<sectionStack.count)
                }
                while sectionStack.count < headingLevel - 1 {
                    sectionStack.append("")
                }
                sectionStack.append(text)
            }

            let blockID: String
            let existingID = try element.attr(Self.assistantBlockAttribute)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if existingID.isEmpty {
                blockID = "rp-assistant-\(Hashing.sha256Hex("\(attachment.id.uuidString)|\(blocks.count)|\(tagName)|\(text)").prefix(20))"
                try element.attr(Self.assistantBlockAttribute, blockID)
                didModifyDocument = true
            } else {
                blockID = existingID
            }

            blocks.append(PaperSearchBlock(
                id: blockID,
                kind: Self.blockKind(for: tagName),
                text: text,
                sectionPath: sectionStack.filter { $0.isEmpty == false },
                attachmentID: attachment.id,
                pageIndex: nil,
                htmlSelector: "[\(Self.assistantBlockAttribute)=\"\(blockID)\"]",
                ordinal: blocks.count
            ))
        }

        if didModifyDocument {
            try document.outerHtml().write(to: url, atomically: true, encoding: .utf8)
        }

        return PaperFullTextIndex(
            version: PaperFullTextIndex.currentVersion,
            paperID: paper.id,
            sourceFingerprint: try sourceFingerprint(for: attachment),
            blocks: blocks,
            createdAt: Date()
        )
    }

    private func makePDFIndex(
        paper: Paper,
        attachment: PaperAttachment
    ) throws -> PaperFullTextIndex {
        let url = attachment.resolvedFileURL(fileStore: fileStore)
        let document = PDFDocument(url: url)
        let blocks = (0..<(document?.pageCount ?? 0)).compactMap { pageIndex -> PaperSearchBlock? in
            guard let text = document?.page(at: pageIndex)?.string.map(Self.normalizedWhitespace),
                  text.count >= 4 else { return nil }
            return PaperSearchBlock(
                id: "pdf-\(attachment.id.uuidString)-\(pageIndex)",
                kind: .pdfPage,
                text: text,
                sectionPath: [],
                attachmentID: attachment.id,
                pageIndex: pageIndex,
                htmlSelector: nil,
                ordinal: pageIndex
            )
        }
        return PaperFullTextIndex(
            version: PaperFullTextIndex.currentVersion,
            paperID: paper.id,
            sourceFingerprint: try sourceFingerprint(for: attachment),
            blocks: blocks,
            createdAt: Date()
        )
    }

    private func persist(_ index: PaperFullTextIndex) throws {
        let data = try JSONEncoder().encode(index)
        try data.write(to: indexURL(for: index.paperID), options: .atomic)
    }

    private func load(paperID: UUID) throws -> PaperFullTextIndex? {
        let url = try indexURL(for: paperID)
        guard fileStore.fileManager.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(PaperFullTextIndex.self, from: Data(contentsOf: url))
    }

    private func indexURL(for paperID: UUID) throws -> URL {
        try fileStore.directory(for: paperID)
            .appendingPathComponent("assistant-search-index-v1.json")
    }

    private func sourceFingerprint(for attachment: PaperAttachment) throws -> String {
        let url = attachment.resolvedFileURL(fileStore: fileStore)
        let attributes = try fileStore.fileManager.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modifiedAt = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(attachment.id.uuidString)|\(size)|\(modifiedAt)"
    }

    private static func isTranslationElement(_ element: Element) throws -> Bool {
        if element.hasClass("rp-translation-block") || element.hasAttr("data-rp-translation") {
            return true
        }
        return element.parents().hasClass("rp-translation-block")
    }

    private static func hasSemanticDescendant(_ element: Element) -> Bool {
        guard let descendants = try? element.select(htmlSemanticSelector).array() else { return false }
        return descendants.contains { descendant in
            descendant !== element && ((try? isTranslationElement(descendant)) == false)
        }
    }

    private static func normalizedVisibleText(_ element: Element) throws -> String {
        let clone = element.copy() as! Element
        for translated in try clone.select(".rp-translation-block, [data-rp-translation=true]").array() {
            try translated.remove()
        }
        return normalizedWhitespace(try clone.text())
    }

    private static func normalizedWhitespace(_ value: String) -> String {
        value.components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.isEmpty == false }
            .joined(separator: " ")
    }

    private static func headingLevel(_ tagName: String) -> Int? {
        guard tagName.count == 2, tagName.first == "h", let level = Int(tagName.dropFirst()) else {
            return nil
        }
        return (1...6).contains(level) ? level : nil
    }

    private static func blockKind(for tagName: String) -> PaperSearchBlockKind {
        if headingLevel(tagName) != nil { return .heading }
        switch tagName {
        case "figcaption": return .figureCaption
        case "blockquote": return .blockquote
        case "li": return .listItem
        default: return .paragraph
        }
    }

    private static func normalized(_ value: String) -> String {
        normalizedWhitespace(value)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
    }

    private static func searchTerms(in query: String) -> [String] {
        let stopWords: Set<String> = [
            "a", "an", "and", "are", "as", "at", "be", "by", "did", "do", "does", "for", "from",
            "how", "in", "is", "it", "of", "on", "or", "that", "the", "this", "to", "was", "what",
            "when", "where", "which", "who", "why", "with"
        ]
        let rawTerms = normalized(query)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 && stopWords.contains($0) == false }

        var result: [String] = []
        var seen: Set<String> = []
        for term in rawTerms {
            if seen.insert(term).inserted { result.append(term) }
            let scalars = Array(term.unicodeScalars)
            let containsASCIIAlphanumeric = scalars.contains { $0.isASCII && CharacterSet.alphanumerics.contains($0) }
            if containsASCIIAlphanumeric == false, scalars.count > 2 {
                for index in 0..<(scalars.count - 1) {
                    let bigram = String(String.UnicodeScalarView(scalars[index...index + 1]))
                    if seen.insert(bigram).inserted { result.append(bigram) }
                }
            }
        }
        return result
    }

    private static func occurrenceCount(of needle: String, in haystack: String) -> Int {
        guard needle.isEmpty == false, haystack.isEmpty == false else { return 0 }
        var count = 0
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let range = haystack.range(of: needle, range: searchRange) {
            count += 1
            searchRange = range.upperBound..<haystack.endIndex
        }
        return count
    }

    private static func isCJKScalar(_ scalar: Unicode.Scalar) -> Bool {
        (0x3400...0x4DBF).contains(scalar.value) ||
            (0x4E00...0x9FFF).contains(scalar.value)
    }
}
