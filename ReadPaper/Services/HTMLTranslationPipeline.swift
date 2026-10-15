import Foundation
import SwiftData
import SwiftSoup

struct HTMLTranslationCandidate: Equatable, Sendable {
    var segmentID: String
    var sourceHash: String
    var tagName: String
    var sourceText: String
    var protectedFragments: [String]
    var sectionTitle: String?
    var previousSourceText: String?
    var nextSourceText: String?
}

extension HTMLTranslationCandidate {
    /// Context sent with the request; also used to recognise outputs that echo it.
    func translationContext(documentTitle: String?, glossary: String?) -> AcademicTranslationContext {
        AcademicTranslationContext(
            documentTitle: documentTitle,
            sectionTitle: sectionTitle,
            previousSegment: previousSourceText,
            nextSegment: nextSourceText,
            glossary: glossary
        )
    }
}

struct HTMLTranslationOutcome: Equatable, Sendable {
    /// Segments left untranslated because every attempt returned unusable output.
    var failedSegments: Int
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
    nonisolated private static let candidateSelector = "p, h1, h2, h3, h4, h5, h6, figcaption, blockquote, li"

    private let client: TranslationLLMClientProtocol

    init(client: TranslationLLMClientProtocol = TranslationLLMClient()) {
        self.client = client
    }

    @discardableResult
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
    ) async throws -> HTMLTranslationOutcome {
        try Task.checkCancellation()
        guard attachment.kind == .html else { throw PaperImportError.missingHTML }
        // Parsing and rewriting paper.html runs off the main actor, so the reader
        // stays responsive while long pages are prepared and saved.
        let page = HTMLTranslationPage(url: attachment.fileURL)
        let candidates = try await page.prepare()
        // paper.html has changed from here on, so the reader reloads it even if
        // the run stops before the cache hits are in.
        var isPagePrepared = false
        defer {
            if isPagePrepared == false {
                onDocumentPrepared?()
            }
        }
        let client = self.client
        let cacheIdentity = preferences.translationCacheIdentity(for: route)
        let documentTitle = paper.title

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
            var failedSegments = 0

            func advanceProgress(by count: Int = 1) throws {
                job.processedSegments += count
                job.progress = candidates.isEmpty ? 1 : Double(job.processedSegments) / Double(candidates.count)
                job.modifiedAt = Date()
                try modelContext.save()
                onProgressUpdated?(job.processedSegments, candidates.count)
            }

            func applyTranslatedSegment(_ candidate: HTMLTranslationCandidate, translated: String) async throws {
                try await page.apply([HTMLTranslationPage.Translation(candidate: candidate, text: translated)])
                try advanceProgress()
                onSegmentTranslated?(HTMLTranslationSegmentUpdate(
                    sequence: job.processedSegments,
                    processedSegments: job.processedSegments,
                    totalSegments: candidates.count,
                    segmentID: candidate.segmentID,
                    translatedHTML: Self.renderTranslation(translated, candidate: candidate)
                ))
            }

            // Cache hits land in one write and one save. The page reload that
            // `onDocumentPrepared` triggers shows them all; per-segment updates would
            // arrive in one burst, and the reader applies only the last of a burst.
            try Task.checkCancellation()
            let cached = try cachedTranslations(
                for: candidates,
                paperID: paper.id,
                targetLanguage: preferences.targetLanguage,
                route: route,
                cacheIdentity: cacheIdentity,
                modelContext: modelContext
            )
            let cachedHits = candidates.compactMap { candidate in
                cached[candidate.segmentID].map { HTMLTranslationPage.Translation(candidate: candidate, text: $0) }
            }
            let pendingCandidates = candidates.filter { cached[$0.segmentID] == nil }
            if cachedHits.isEmpty == false {
                try await page.apply(cachedHits)
                try advanceProgress(by: cachedHits.count)
            }
            isPagePrepared = true
            onDocumentPrepared?()

            let concurrency = max(1, preferences.htmlTranslationConcurrency)
            for batch in pendingCandidates.chunked(into: concurrency) {
                try Task.checkCancellation()
                try await withThrowingTaskGroup(of: (HTMLTranslationCandidate, String?).self) { group in
                    for candidate in batch {
                        group.addTask {
                            do {
                                let translated = try await client.validatedTranslate(
                                    candidate.sourceText,
                                    targetLanguage: preferences.targetLanguage,
                                    route: route,
                                    apiKey: apiKey,
                                    context: candidate.translationContext(
                                        documentTitle: documentTitle,
                                        glossary: preferences.translationGlossary
                                    )
                                )
                                return (candidate, translated)
                            } catch is TranslationOutputValidationError {
                                // An unstable model must not abort the whole document; the segment
                                // stays untranslated and uncached so the next run retries it.
                                return (candidate, nil)
                            }
                        }
                    }

                    for try await (candidate, translated) in group {
                        try Task.checkCancellation()
                        guard let translated else {
                            failedSegments += 1
                            try advanceProgress()
                            continue
                        }
                        modelContext.insert(TranslationSegment(
                            paperID: paper.id,
                            sourceType: "html",
                            targetLanguage: preferences.targetLanguage,
                            sourceHash: candidate.sourceHash,
                            sourceText: candidate.sourceText,
                            translatedText: translated,
                            providerProfileID: route.providerProfileID,
                            modelProfileID: route.modelProfileID,
                            modelName: cacheIdentity
                        ))
                        try await applyTranslatedSegment(candidate, translated: translated)
                    }
                }
            }

            try Task.checkCancellation()
            job.state = .completed
            job.progress = 1
            job.lastError = failedSegments > 0 ? Self.skippedSegmentsMessage(count: failedSegments) : nil
            job.modifiedAt = Date()
            try modelContext.save()
            return HTMLTranslationOutcome(failedSegments: failedSegments)
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

    static func skippedSegmentsMessage(count: Int, bundle: Bundle? = nil) -> String {
        AppLocalization.format(
            "%lld segments were skipped because the model returned invalid output. Translate again to retry them.",
            bundle: bundle,
            count
        )
    }

    /// Valid cached translations keyed by segment ID, from one fetch of this paper's
    /// cache rather than one fetch of every paper's cache per segment.
    private func cachedTranslations(
        for candidates: [HTMLTranslationCandidate],
        paperID: UUID,
        targetLanguage: String,
        route: LLMModelRouteSnapshot,
        cacheIdentity: String,
        modelContext: ModelContext
    ) throws -> [String: String] {
        let sourceType = "html"
        let descriptor = FetchDescriptor<TranslationSegment>(predicate: #Predicate {
            $0.paperID == paperID && $0.sourceType == sourceType && $0.targetLanguage == targetLanguage
        })
        let segmentsByHash = Dictionary(
            grouping: try modelContext.fetch(descriptor).filter {
                $0.providerProfileID == route.providerProfileID &&
                    $0.modelProfileID == route.modelProfileID &&
                    $0.modelName == cacheIdentity
            },
            by: \.sourceHash
        )

        var translations: [String: String] = [:]
        var purged = Set<PersistentIdentifier>()
        for candidate in candidates {
            guard let matches = segmentsByHash[candidate.sourceHash] else { continue }
            let context = candidate.translationContext(documentTitle: nil, glossary: nil)
            for segment in matches where purged.contains(segment.persistentModelID) == false {
                let issue = TranslationOutputValidator.issue(
                    in: segment.translatedText,
                    source: candidate.sourceText,
                    context: context
                )
                if let issue, issue.isFatal {
                    // Purge outputs cached before validation existed (e.g. echoed prompts).
                    purged.insert(segment.persistentModelID)
                    modelContext.delete(segment)
                } else if translations[candidate.segmentID] == nil {
                    translations[candidate.segmentID] = segment.translatedText
                }
            }
        }
        return translations
    }

    nonisolated static func extractCandidates(from html: String) throws -> [HTMLTranslationCandidate] {
        try prepareDocument(html).candidates
    }

    nonisolated static func prepareDocument(_ html: String) throws -> (preparedHTML: String, candidates: [HTMLTranslationCandidate]) {
        let document = try SwiftSoup.parse(html)
        let candidates = try prepare(document)
        return (try document.outerHtml(), candidates)
    }

    /// Clears earlier translations and marks every candidate in place.
    nonisolated static func prepare(_ document: Document) throws -> [HTMLTranslationCandidate] {
        try removeExistingTranslationBlocks(from: document)
        try removeExistingSourceMarkers(from: document)
        var candidates: [HTMLTranslationCandidate] = []
        var currentSectionTitle: String?

        for element in try document.select(candidateSelector).array() {
            if try shouldSkip(element) { continue }
            if try hasTranslatableDescendant(in: element) { continue }
            let tagName = element.tagName()
            let protected = try protectedText(from: element)
            let minimumLength = tagName.hasPrefix("h") ? 2 : 10
            if tagName.hasPrefix("h"), protected.text.isEmpty == false {
                currentSectionTitle = protected.text
            }
            guard protected.text.count >= minimumLength, !isMathOnly(protected.text) else { continue }

            let segmentID = "rp-\(Hashing.sha256Hex(protected.text).prefix(16))-\(candidates.count)"
            try element.attr("data-rp-segment-id", segmentID)
            try element.attr("data-rp-source", "true")
            candidates.append(HTMLTranslationCandidate(
                segmentID: segmentID,
                sourceHash: Hashing.sha256Hex(protected.text),
                tagName: tagName,
                sourceText: protected.text,
                protectedFragments: protected.fragments,
                sectionTitle: tagName.hasPrefix("h") ? nil : currentSectionTitle,
                previousSourceText: nil,
                nextSourceText: nil
            ))
        }

        for index in candidates.indices {
            if index > candidates.startIndex {
                candidates[index].previousSourceText = candidates[index - 1].sourceText
            }
            let nextIndex = candidates.index(after: index)
            if nextIndex < candidates.endIndex {
                candidates[index].nextSourceText = candidates[nextIndex].sourceText
            }
        }

        return candidates
    }

    nonisolated static func applyTranslations(
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

    nonisolated fileprivate static func applyTranslation(
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

    nonisolated private static func removeExistingTranslationBlocks(from document: Document) throws {
        for block in try document.select(".rp-translation-block, [data-rp-translation=true]").array() {
            try block.remove()
        }
    }

    nonisolated private static func removeExistingSourceMarkers(from document: Document) throws {
        for element in try document.select("[data-rp-segment-id], [data-rp-source]").array() {
            try element.removeAttr("data-rp-segment-id")
            try element.removeAttr("data-rp-source")
        }
    }

    nonisolated fileprivate static func writeDocument(_ document: Document, to url: URL) throws {
        try document.outerHtml().write(to: url, atomically: true, encoding: .utf8)
    }

    nonisolated private static func shouldSkip(_ element: Element) throws -> Bool {
        if element.hasAttr("data-rp-translation") || element.hasClass("rp-translation-block") {
            return true
        }
        if element.parents().hasClass("rp-translation-block") {
            return true
        }
        return HTMLRegionVisibility.isWithinHiddenRegion(element)
    }

    nonisolated private static func hasTranslatableDescendant(in element: Element) throws -> Bool {
        for descendant in try element.select(candidateSelector).array() {
            if descendant === element { continue }
            if try shouldSkip(descendant) { continue }
            let tagName = descendant.tagName()
            let protected = try protectedText(from: descendant)
            let minimumLength = tagName.hasPrefix("h") ? 2 : 10
            if protected.text.count >= minimumLength, !isMathOnly(protected.text) {
                return true
            }
        }
        return false
    }

    /// Formula-only blocks have nothing to translate; translating them only duplicates the equation.
    nonisolated static func isMathOnly(_ text: String) -> Bool {
        let prose = text
            .replacingOccurrences(of: #"\[PROTECTED_\d+\]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(
                of: #"\$\$[\s\S]*?\$\$|\\\[[\s\S]*?\\\]|\\\([\s\S]*?\\\)|\\begin\{([A-Za-z]+\*?)\}[\s\S]*?\\end\{\1\}"#,
                with: " ",
                options: .regularExpression
            )
        return !prose.contains { $0.isLetter }
    }

    nonisolated private static func protectedText(from element: Element) throws -> (text: String, fragments: [String]) {
        let clone = element.copy() as! Element
        try HTMLRegionVisibility.removeHiddenRegions(in: clone)
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

    nonisolated private static func renderTranslation(_ translation: String, candidate: HTMLTranslationCandidate) -> String {
        var escaped = escapeHTML(translation)
        for (index, fragment) in candidate.protectedFragments.enumerated() {
            escaped = escaped.replacingOccurrences(of: "[PROTECTED_\(index)]", with: fragment)
        }
        return "<\(candidate.tagName) class=\"rp-translation-block\" data-rp-translation=\"true\" data-rp-source-segment-id=\"\(escapeHTML(candidate.segmentID))\">\(escaped)</\(candidate.tagName)>"
    }

    nonisolated private static func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    nonisolated fileprivate static func injectDisplayStyles(into document: Document) throws {
        let styleID = "rp-translation-display-style"
        let style: Element
        if let existing = try document.getElementById(styleID) {
            style = existing
        } else {
            style = try document.createElement("style")
            try style.attr("id", styleID)
        }
        try style.html("""
        html[data-rp-display-mode='original'] .rp-translation-block { display: none !important; }
        html[data-rp-display-mode='translated'] [data-rp-source='true'] { display: none !important; }
        .rp-translation-block {
            color: #1f4d3a;
            display: block !important;
            position: static !important;
            clear: both;
            height: auto !important;
            min-height: 0 !important;
            max-height: none !important;
            overflow: visible !important;
            white-space: normal !important;
            word-break: break-word;
            line-height: 1.55 !important;
            margin-top: 0.25em;
            box-sizing: border-box;
        }
        html[data-rp-display-mode='bilingual'] .rp-readability-content [data-rp-source='true'] {
            margin-bottom: 0.25em !important;
        }
        .rp-readability-content [data-rp-source='true'] + .rp-translation-block {
            font-size: inherit !important;
            line-height: inherit !important;
            margin-left: 0 !important;
            margin-right: 0 !important;
            margin-top: 0 !important;
            margin-bottom: 1.1em !important;
        }
        .rp-translation-block:is(h1, h2, h3, h4, h5, h6) {
            line-height: 1.45 !important;
            margin-top: 0.35em !important;
            margin-bottom: 0.75em !important;
        }
        """)
        if style.parent() == nil, let head = document.head() {
            try head.appendChild(style)
        }
    }
}

/// paper.html during one translation run. The parsed page lives here, off the
/// main actor: each save serializes the whole page, which takes hundreds of
/// milliseconds on long pages in Debug builds.
private actor HTMLTranslationPage {
    struct Translation: Sendable {
        var candidate: HTMLTranslationCandidate
        var text: String
    }

    private let url: URL
    private var document: Document?

    init(url: URL) {
        self.url = url
    }

    /// Marks the candidates, adds the translation styles and saves the page.
    func prepare() throws -> [HTMLTranslationCandidate] {
        let document = try SwiftSoup.parse(String(contentsOf: url, encoding: .utf8))
        let candidates = try HTMLTranslationPipeline.prepare(document)
        try HTMLTranslationPipeline.injectDisplayStyles(into: document)
        try HTMLTranslationPipeline.writeDocument(document, to: url)
        self.document = document
        return candidates
    }

    /// Inserts the translation blocks and saves the page once.
    func apply(_ translations: [Translation]) throws {
        guard let document, translations.isEmpty == false else { return }
        for translation in translations {
            try HTMLTranslationPipeline.applyTranslation(
                translation.text,
                candidate: translation.candidate,
                to: document
            )
        }
        try HTMLTranslationPipeline.writeDocument(document, to: url)
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
