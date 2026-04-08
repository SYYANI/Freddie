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

@MainActor
final class HTMLTranslationPipeline {
    private let client: ChatTranslationClient

    init(client: ChatTranslationClient = ChatTranslationClient()) {
        self.client = client
    }

    func translateHTML(
        attachment: PaperAttachment,
        paper: Paper,
        settings: AppSettingsSnapshot,
        modelContext: ModelContext
    ) async throws {
        try Task.checkCancellation()
        guard attachment.kind == .html else { throw PaperImportError.missingHTML }
        let htmlURL = attachment.fileURL
        let html = try String(contentsOf: htmlURL, encoding: .utf8)
        let extraction = try Self.prepareDocument(html)
        let candidates = extraction.candidates

        let job = TranslationJob(
            paperID: paper.id,
            attachmentID: attachment.id,
            kind: "html",
            targetLanguage: settings.targetLanguage,
            state: .running,
            totalSegments: candidates.count
        )
        modelContext.insert(job)
        try modelContext.save()

        do {
            var translations: [String: String] = [:]
            var pendingCandidates: [HTMLTranslationCandidate] = []
            for candidate in candidates {
                try Task.checkCancellation()
                if let cached = try cachedSegment(
                    paperID: paper.id,
                    sourceType: "html",
                    targetLanguage: settings.targetLanguage,
                    sourceHash: candidate.sourceHash,
                    modelContext: modelContext
                ) {
                    translations[candidate.segmentID] = cached.translatedText
                    job.processedSegments += 1
                    job.progress = candidates.isEmpty ? 1 : Double(job.processedSegments) / Double(candidates.count)
                    job.modifiedAt = Date()
                    try modelContext.save()
                } else {
                    pendingCandidates.append(candidate)
                }
            }

            let concurrency = max(1, settings.htmlTranslationConcurrency)
            for batch in pendingCandidates.chunked(into: concurrency) {
                try Task.checkCancellation()
                let results = try await Self.translateBatch(batch, settings: settings, client: client)
                try Task.checkCancellation()
                for (candidate, translated) in results {
                    translations[candidate.segmentID] = translated
                    modelContext.insert(TranslationSegment(
                        paperID: paper.id,
                        sourceType: "html",
                        targetLanguage: settings.targetLanguage,
                        sourceHash: candidate.sourceHash,
                        sourceText: candidate.sourceText,
                        translatedText: translated,
                        modelName: settings.heavyModelName
                    ))
                    job.processedSegments += 1
                    job.progress = candidates.isEmpty ? 1 : Double(job.processedSegments) / Double(candidates.count)
                    job.modifiedAt = Date()
                }
                try modelContext.save()
            }

            try Task.checkCancellation()
            let output = try Self.applyTranslations(
                toPreparedHTML: extraction.preparedHTML,
                candidates: candidates,
                translations: translations
            )
            try Task.checkCancellation()
            try output.write(to: htmlURL, atomically: true, encoding: .utf8)
            job.state = .completed
            job.progress = 1
            job.modifiedAt = Date()
            try modelContext.save()
        } catch is CancellationError {
            job.state = .failed
            job.lastError = "Translation cancelled."
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
        modelContext: ModelContext
    ) throws -> TranslationSegment? {
        let segments = try modelContext.fetch(FetchDescriptor<TranslationSegment>())
        return segments.first {
            $0.paperID == paperID &&
                $0.sourceType == sourceType &&
                $0.targetLanguage == targetLanguage &&
                $0.sourceHash == sourceHash
        }
    }

    static func extractCandidates(from html: String) throws -> [HTMLTranslationCandidate] {
        try prepareDocument(html).candidates
    }

    nonisolated private static func translateBatch(
        _ candidates: [HTMLTranslationCandidate],
        settings: AppSettingsSnapshot,
        client: ChatTranslationClient
    ) async throws -> [(HTMLTranslationCandidate, String)] {
        try await withThrowingTaskGroup(of: (HTMLTranslationCandidate, String).self) { group in
            for candidate in candidates {
                group.addTask {
                    let translated = try await client.translate(candidate.sourceText, purpose: "heavy", settings: settings)
                    return (candidate, translated)
                }
            }

            var results: [(HTMLTranslationCandidate, String)] = []
            for try await result in group {
                results.append(result)
            }
            return results
        }
    }

    static func prepareDocument(_ html: String) throws -> (preparedHTML: String, candidates: [HTMLTranslationCandidate]) {
        let document = try SwiftSoup.parse(html)
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
        for candidate in candidates {
            guard let translation = translations[candidate.segmentID],
                  let source = try document.select("[data-rp-segment-id=\(candidate.segmentID)]").first() else {
                continue
            }
            let translatedHTML = renderTranslation(translation, candidate: candidate)
            let block = try SwiftSoup.parseBodyFragment(translatedHTML).body()?.child(0)
            if let block {
                try source.after(block.outerHtml())
            }
        }
        try injectDisplayStyles(into: document)
        return try document.outerHtml()
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
        return "<\(candidate.tagName) class=\"rp-translation-block\" data-rp-translation=\"true\">\(escaped)</\(candidate.tagName)>"
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
