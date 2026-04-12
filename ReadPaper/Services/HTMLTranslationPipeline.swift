import Foundation
import SwiftData
import SwiftSoup

struct HTMLTranslationCandidate: Equatable, Sendable {
    var segmentID: String
    var sourceHash: String
    var tagName: String
    var sourceText: String
    var protectedFragments: [String]
}

struct HTMLTranslationSegmentUpdate: Equatable, Sendable {
    var sequence: Int
    var processedSegments: Int
    var totalSegments: Int
    var segmentID: String
    var translatedHTML: String
}

@MainActor
final class HTMLTranslationPipeline {
    private let client: TranslationLLMClientProtocol

    init(client: TranslationLLMClientProtocol = TranslationLLMClient()) {
        self.client = client
    }

    func translateHTML(
        attachment: PaperAttachment,
        paper: Paper,
        preferences: TranslationPreferencesSnapshot,
        route: LLMModelRouteSnapshot,
        apiKey: String,
        modelContext: ModelContext,
        onDocumentPrepared: (() -> Void)? = nil,
        onProgressUpdated: ((Int, Int) -> Void)? = nil,
        onSegmentTranslated: ((HTMLTranslationSegmentUpdate) -> Void)? = nil
    ) async throws {
        try Task.checkCancellation()
        guard attachment.kind == .html else { throw PaperImportError.missingHTML }
        let htmlURL = attachment.fileURL
        let html = try String(contentsOf: htmlURL, encoding: .utf8)
        let extraction = try Self.prepareDocument(html)
        let candidates = extraction.candidates
        let document = try SwiftSoup.parse(extraction.preparedHTML)
        let client = self.client
        try Self.injectDisplayStyles(into: document)
        try Self.writeDocument(document, to: htmlURL)
        onDocumentPrepared?()

        let job = TranslationJob(
            paperID: paper.id,
            attachmentID: attachment.id,
            kind: "html",
            targetLanguage: preferences.targetLanguage,
            state: .running,
            totalSegments: candidates.count
        )
        modelContext.insert(job)
        try modelContext.save()
        onProgressUpdated?(0, candidates.count)

        do {
            var pendingCandidates: [HTMLTranslationCandidate] = []

            func applyTranslatedSegment(_ candidate: HTMLTranslationCandidate, translated: String) throws {
                try Self.applyTranslation(translated, candidate: candidate, to: document)
                job.processedSegments += 1
                job.progress = candidates.isEmpty ? 1 : Double(job.processedSegments) / Double(candidates.count)
                job.modifiedAt = Date()
                try modelContext.save()
                try Self.writeDocument(document, to: htmlURL)
                onProgressUpdated?(job.processedSegments, candidates.count)
                onSegmentTranslated?(HTMLTranslationSegmentUpdate(
                    sequence: job.processedSegments,
                    processedSegments: job.processedSegments,
                    totalSegments: candidates.count,
                    segmentID: candidate.segmentID,
                    translatedHTML: Self.renderTranslation(translated, candidate: candidate)
                ))
            }

            for candidate in candidates {
                try Task.checkCancellation()
                if let cached = try cachedSegment(
                    paperID: paper.id,
                    sourceType: "html",
                    targetLanguage: preferences.targetLanguage,
                    sourceHash: candidate.sourceHash,
                    route: route,
                    modelContext: modelContext
                ) {
                    try applyTranslatedSegment(candidate, translated: cached.translatedText)
                } else {
                    pendingCandidates.append(candidate)
                }
            }

            let concurrency = max(1, preferences.htmlTranslationConcurrency)
            for batch in pendingCandidates.chunked(into: concurrency) {
                try Task.checkCancellation()
                try await withThrowingTaskGroup(of: (HTMLTranslationCandidate, String).self) { group in
                    for candidate in batch {
                        group.addTask {
                            let translated = try await client.translate(
                                candidate.sourceText,
                                targetLanguage: preferences.targetLanguage,
                                route: route,
                                apiKey: apiKey
                            )
                            return (candidate, translated)
                        }
                    }

                    for try await (candidate, translated) in group {
                        try Task.checkCancellation()
                        modelContext.insert(TranslationSegment(
                            paperID: paper.id,
                            sourceType: "html",
                            targetLanguage: preferences.targetLanguage,
                            sourceHash: candidate.sourceHash,
                            sourceText: candidate.sourceText,
                            translatedText: translated,
                            providerProfileID: route.providerProfileID,
                            modelProfileID: route.modelProfileID,
                            modelName: route.modelName
                        ))
                        try applyTranslatedSegment(candidate, translated: translated)
                    }
                }
            }

            try Task.checkCancellation()
            job.state = .completed
            job.progress = 1
            job.modifiedAt = Date()
            try modelContext.save()
        } catch is CancellationError {
            job.state = .failed
            job.lastError = AppLocalization.localized("Translation cancelled.")
            job.modifiedAt = Date()
            try? modelContext.save()
            throw CancellationError()
        } catch {
            job.state = .failed
            job.lastError = error.localizedDescription
            job.modifiedAt = Date()
            try? modelContext.save()
            throw error
        }
    }

    private func cachedSegment(
        paperID: UUID,
        sourceType: String,
        targetLanguage: String,
        sourceHash: String,
        route: LLMModelRouteSnapshot,
        modelContext: ModelContext
    ) throws -> TranslationSegment? {
        let segments = try modelContext.fetch(FetchDescriptor<TranslationSegment>())
        return segments.first {
            $0.paperID == paperID &&
                $0.sourceType == sourceType &&
                $0.targetLanguage == targetLanguage &&
                $0.sourceHash == sourceHash &&
                $0.providerProfileID == route.providerProfileID &&
                $0.modelProfileID == route.modelProfileID
        }
    }

    static func extractCandidates(from html: String) throws -> [HTMLTranslationCandidate] {
        try prepareDocument(html).candidates
    }

    static func prepareDocument(_ html: String) throws -> (preparedHTML: String, candidates: [HTMLTranslationCandidate]) {
        let document = try SwiftSoup.parse(html)
        try removeExistingTranslationBlocks(from: document)
        var candidates: [HTMLTranslationCandidate] = []
        let selector = "p, h1, h2, h3, h4, h5, h6, figcaption, blockquote, li"

        for element in try document.select(selector).array() {
            if try shouldSkip(element) { continue }
            let tagName = element.tagName()
            let protected = try protectedText(from: element)
            let minimumLength = tagName.hasPrefix("h") ? 2 : 10
            guard protected.text.count >= minimumLength else { continue }

            let segmentID = "rp-\(Hashing.sha256Hex(protected.text).prefix(16))-\(candidates.count)"
            try element.attr("data-rp-segment-id", segmentID)
            try element.attr("data-rp-source", "true")
            candidates.append(HTMLTranslationCandidate(
                segmentID: segmentID,
                sourceHash: Hashing.sha256Hex(protected.text),
                tagName: tagName,
                sourceText: protected.text,
                protectedFragments: protected.fragments
            ))
        }

        return (try document.outerHtml(), candidates)
    }

    static func applyTranslations(
        toPreparedHTML html: String,
        candidates: [HTMLTranslationCandidate],
        translations: [String: String]
    ) throws -> String {
        let document = try SwiftSoup.parse(html)
        try injectDisplayStyles(into: document)
        for candidate in candidates {
            guard let translation = translations[candidate.segmentID] else {
                continue
            }
            try applyTranslation(translation, candidate: candidate, to: document)
        }
        return try document.outerHtml()
    }

    private static func applyTranslation(
        _ translation: String,
        candidate: HTMLTranslationCandidate,
        to document: Document
    ) throws {
        guard let source = try document.select("[data-rp-segment-id=\(candidate.segmentID)]").first() else {
            return
        }
        for existing in try document.select(".rp-translation-block[data-rp-source-segment-id=\(candidate.segmentID)]").array() {
            try existing.remove()
        }
        let translatedHTML = renderTranslation(translation, candidate: candidate)
        let block = try SwiftSoup.parseBodyFragment(translatedHTML).body()?.child(0)
        if let block {
            try source.after(block.outerHtml())
        }
    }

    private static func removeExistingTranslationBlocks(from document: Document) throws {
        for block in try document.select(".rp-translation-block, [data-rp-translation=true]").array() {
            try block.remove()
        }
    }

    private static func writeDocument(_ document: Document, to url: URL) throws {
        try document.outerHtml().write(to: url, atomically: true, encoding: .utf8)
    }

    private static func shouldSkip(_ element: Element) throws -> Bool {
        if element.hasAttr("data-rp-translation") || element.hasClass("rp-translation-block") {
            return true
        }
        if element.parents().hasClass("rp-translation-block") {
            return true
        }
        return false
    }

    private static func protectedText(from element: Element) throws -> (text: String, fragments: [String]) {
        let clone = element.copy() as! Element
        var fragments: [String] = []
        for protectedNode in try clone.select("math, .ltx_Math, cite, code").array() {
            let placeholder = "[PROTECTED_\(fragments.count)]"
            fragments.append(try protectedNode.outerHtml())
            try protectedNode.text(placeholder)
        }
        let text = try clone.text()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return (text, fragments)
    }

    private static func renderTranslation(_ translation: String, candidate: HTMLTranslationCandidate) -> String {
        var escaped = escapeHTML(translation)
        for (index, fragment) in candidate.protectedFragments.enumerated() {
            escaped = escaped.replacingOccurrences(of: "[PROTECTED_\(index)]", with: fragment)
        }
        return "<\(candidate.tagName) class=\"rp-translation-block\" data-rp-translation=\"true\" data-rp-source-segment-id=\"\(escapeHTML(candidate.segmentID))\">\(escaped)</\(candidate.tagName)>"
    }

    private static func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func injectDisplayStyles(into document: Document) throws {
        let styleID = "rp-translation-display-style"
        if try document.getElementById(styleID) != nil {
            return
        }
        let style = try document.createElement("style")
        try style.attr("id", styleID)
        try style.html("""
        html[data-rp-display-mode='original'] .rp-translation-block { display: none !important; }
        html[data-rp-display-mode='translated'] [data-rp-source='true'] { display: none !important; }
        .rp-translation-block { color: #1f4d3a; margin-top: 0.25em; }
        """)
        if let head = document.head() {
            try head.appendChild(style)
        }
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { start in
            Array(self[start..<Swift.min(start + size, count)])
        }
    }
}
