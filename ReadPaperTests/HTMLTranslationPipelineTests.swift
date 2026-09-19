import SwiftData
import SwiftSoup
import XCTest
@testable import ReadPaper

final class HTMLTranslationPipelineTests: XCTestCase {
    func testHTMLReaderTypographyClampsFontSize() {
        XCTAssertEqual(HTMLReaderTypography.clampFontSize(8), 13)
        XCTAssertEqual(HTMLReaderTypography.clampFontSize(17), 17)
        XCTAssertEqual(HTMLReaderTypography.clampFontSize(40), 28)
    }

    @MainActor
    func testHTMLSelectionInstrumentationKeepsJavaScriptNewlineEscapesIntact() {
        let script = HTMLReaderView.Coordinator.instrumentationScript

        XCTAssertTrue(script.contains(".join('\\n\\n')"))
        XCTAssertFalse(script.contains(".join('\n\n')"))
        XCTAssertTrue(script.contains("rpSelection.postMessage({ quote, selector, localContext })"))
        XCTAssertTrue(script.contains("CSS.highlights.set('rp-assistant-selection'"))
        XCTAssertTrue(script.contains("window.__rpClearSelectionAssistantHighlight"))
        XCTAssertTrue(script.contains("::highlight(rp-assistant-selection)"))
        XCTAssertTrue(script.contains("window.__rpSetSelectionAssistantHistory"))
        XCTAssertTrue(script.contains("::highlight(rp-assistant-history)"))
        XCTAssertTrue(script.contains("rp-assistant-history-fallback"))
        XCTAssertTrue(script.contains("assistantHistorySelectionGraceUntil"))
        XCTAssertTrue(script.contains("Date.now() < assistantHistorySelectionGraceUntil"))
        XCTAssertTrue(HTMLReaderView.Coordinator.nativeSelectionClearScript.contains("removeAllRanges"))
        XCTAssertTrue(script.contains("rpSelectionReset.postMessage(null)"))
        XCTAssertTrue(script.contains("document.addEventListener('pointerdown'"))
    }

    @MainActor
    func testExtractsSegmentsAndProtectsMathAndCitations() throws {
        let html = """
        <html><body>
        <p>We show that <math><mi>x</mi></math> improves the baseline <cite>[1]</cite> in a controlled setting.</p>
        <p class="rp-translation-block" data-rp-translation="true">Already translated.</p>
        </body></html>
        """
        let candidates = try HTMLTranslationPipeline.extractCandidates(from: html)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertTrue(candidates[0].sourceText.contains("[PROTECTED_0]"))
        XCTAssertTrue(candidates[0].sourceText.contains("[PROTECTED_1]"))
        XCTAssertEqual(candidates[0].protectedFragments.count, 2)
    }

    @MainActor
    func testCandidatesCarrySectionAndNeighborContext() throws {
        let html = """
        <html><body>
        <h2>Methods</h2>
        <p>The previous paragraph is long enough to be translated.</p>
        <p>The current paragraph is also long enough to be translated.</p>
        <p>The next paragraph is long enough to be translated.</p>
        </body></html>
        """

        let candidates = try HTMLTranslationPipeline.extractCandidates(from: html)

        XCTAssertEqual(candidates.count, 4)
        XCTAssertNil(candidates[0].sectionTitle)
        XCTAssertEqual(candidates[1].sectionTitle, "Methods")
        XCTAssertEqual(candidates[2].sectionTitle, "Methods")
        XCTAssertEqual(candidates[2].previousSourceText, candidates[1].sourceText)
        XCTAssertEqual(candidates[2].nextSourceText, candidates[3].sourceText)
    }

    func testAcademicPromptEnforcesFaithfulTranslationAndCarriesContext() {
        let systemPrompt = AcademicTranslationPrompt.systemPrompt(targetLanguage: "zh-CN")
        XCTAssertTrue(systemPrompt.contains("into zh-CN"))
        XCTAssertTrue(systemPrompt.contains("faithful"))
        XCTAssertTrue(systemPrompt.contains("Do not omit, summarize, simplify, expand"))
        XCTAssertTrue(systemPrompt.contains("keep terms, abbreviations, symbols, and named concepts consistent"))
        XCTAssertTrue(systemPrompt.contains("[BABELDOC_FORMULA_1]"))
        XCTAssertTrue(systemPrompt.contains("every placeholder token in the source appears exactly once"))
        XCTAssertTrue(systemPrompt.contains("Output only the translation"))

        let userPrompt = AcademicTranslationPrompt.userPrompt(
            sourceText: "Current source",
            context: AcademicTranslationContext(
                documentTitle: "Context Paper",
                sectionTitle: "Methods",
                previousSegment: "Previous source",
                nextSegment: "Next source",
                glossary: "attention = 注意力"
            )
        )
        XCTAssertTrue(userPrompt.contains("<<<DOCUMENT_TITLE>>>\nContext Paper"))
        XCTAssertTrue(userPrompt.contains("<<<SECTION_TITLE>>>\nMethods"))
        XCTAssertTrue(userPrompt.contains("<<<PREVIOUS_SEGMENT>>>\nPrevious source"))
        XCTAssertTrue(userPrompt.contains("<<<NEXT_SEGMENT>>>\nNext source"))
        XCTAssertTrue(userPrompt.contains("<<<OPTIONAL_GLOSSARY>>>\nattention = 注意力"))
        XCTAssertTrue(userPrompt.contains("<<<SOURCE_SEGMENT_TO_TRANSLATE>>>\nCurrent source"))
    }

    func testPromptVersionAndAPIStyleArePartOfRouteCacheIdentity() {
        let route = makeRoute(modelID: UUID(), providerID: UUID(), modelName: "paper-model")
        XCTAssertTrue(route.translationCacheIdentity.contains("prompt=\(AcademicTranslationPrompt.version)"))
        XCTAssertTrue(route.translationCacheIdentity.contains("api=chat-completions"))
    }

    @MainActor
    func testAppliesTranslationBlocks() throws {
        let html = "<html><body><p>This is a long enough paragraph for translation.</p></body></html>"
        let prepared = try HTMLTranslationPipeline.prepareDocument(html)
        let output = try HTMLTranslationPipeline.applyTranslations(
            toPreparedHTML: prepared.preparedHTML,
            candidates: prepared.candidates,
            translations: [prepared.candidates[0].segmentID: "Translated paragraph."]
        )
        XCTAssertTrue(output.contains("rp-translation-block"))
        XCTAssertTrue(output.contains("Translated paragraph."))
    }

    @MainActor
    func testTitleTranslationBlocksResetCrampedHeadingLayout() throws {
        let html = """
        <html>
        <head>
        <style>h1 { line-height: 0.7; max-height: 1em; overflow: hidden; }</style>
        <style id="rp-translation-display-style">.rp-translation-block { color: red; }</style>
        </head>
        <body>
        <h1>A title that will wrap after translation</h1>
        </body>
        </html>
        """
        let prepared = try HTMLTranslationPipeline.prepareDocument(html)
        let candidate = try XCTUnwrap(prepared.candidates.first)
        let output = try HTMLTranslationPipeline.applyTranslations(
            toPreparedHTML: prepared.preparedHTML,
            candidates: prepared.candidates,
            translations: [
                candidate.segmentID: "这是一个会在阅读器中换行的中文标题译文，用来验证标题译文不会上下重叠。"
            ]
        )

        XCTAssertTrue(output.contains("<h1 class=\"rp-translation-block\""))
        XCTAssertTrue(output.contains(".rp-translation-block:is(h1, h2, h3, h4, h5, h6)"))
        XCTAssertTrue(output.contains(".rp-readability-content [data-rp-source='true'] + .rp-translation-block"))
        XCTAssertTrue(output.contains("font-size: inherit !important"))
        XCTAssertTrue(output.contains("margin-left: 0 !important"))
        XCTAssertTrue(output.contains("line-height: 1.45 !important"))
        XCTAssertTrue(output.contains("max-height: none !important"))
        XCTAssertFalse(output.contains("color: red"))
    }

    @MainActor
    func testNestedListParagraphsDoNotCreateParentListCandidates() throws {
        let html = """
        <html><body>
        <ul>
        <li><p>Nested list paragraph that should be translated once only.</p></li>
        <li>Plain list item that still needs its own translation.</li>
        </ul>
        </body></html>
        """
        let prepared = try HTMLTranslationPipeline.prepareDocument(html)

        XCTAssertEqual(prepared.candidates.count, 2)
        XCTAssertEqual(prepared.candidates.map(\.tagName), ["p", "li"])

        let preparedDocument = try SwiftSoup.parse(prepared.preparedHTML)
        let items = try preparedDocument.select("li").array()
        XCTAssertEqual(items.count, 2)
        XCTAssertFalse(items[0].hasAttr("data-rp-source"))
        XCTAssertNotNil(try items[0].select("p[data-rp-source=true]").first())
        XCTAssertTrue(items[1].hasAttr("data-rp-source"))

        let translations = Dictionary(uniqueKeysWithValues: prepared.candidates.enumerated().map { index, candidate in
            (candidate.segmentID, "Translated block \(index).")
        })
        let output = try HTMLTranslationPipeline.applyTranslations(
            toPreparedHTML: prepared.preparedHTML,
            candidates: prepared.candidates,
            translations: translations
        )
        let translatedBlocks = try SwiftSoup.parse(output).select("body .rp-translation-block").array()
        XCTAssertEqual(translatedBlocks.count, 2)
        XCTAssertEqual(translatedBlocks.map { $0.tagName() }, ["p", "li"])
    }

    @MainActor
    func testPrepareDocumentClearsStaleSourceMarkersFromSkippedContainers() throws {
        let html = """
        <html><body>
        <ul>
        <li data-rp-segment-id="old-li" data-rp-source="true">
            <p data-rp-segment-id="old-p" data-rp-source="true">Nested paragraph with stale markers should keep only paragraph source markers.</p>
            <p class="rp-translation-block" data-rp-translation="true" data-rp-source-segment-id="old-p">Old nested translation.</p>
        </li>
        <li class="rp-translation-block" data-rp-translation="true" data-rp-source-segment-id="old-li">Old parent translation.</li>
        </ul>
        </body></html>
        """
        let prepared = try HTMLTranslationPipeline.prepareDocument(html)
        let preparedDocument = try SwiftSoup.parse(prepared.preparedHTML)

        XCTAssertNil(try preparedDocument.select(".rp-translation-block").first())
        XCTAssertNil(try preparedDocument.select("li[data-rp-source=true]").first())
        XCTAssertNotNil(try preparedDocument.select("li p[data-rp-source=true]").first())
        XCTAssertFalse(prepared.preparedHTML.contains("old-li"))
        XCTAssertFalse(prepared.preparedHTML.contains("old-p"))
    }

    @MainActor
    func testTranslateHTMLUsesCacheOnlyWhenRouteMatches() async throws {
        let environment = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.rootURL) }

        let sourceHTML = "<html><body><p>This is a long enough paragraph for translation.</p></body></html>"
        try sourceHTML.write(to: environment.attachment.fileURL, atomically: true, encoding: .utf8)

        let prepared = try HTMLTranslationPipeline.prepareDocument(sourceHTML)
        let candidate = try XCTUnwrap(prepared.candidates.first)
        let route = makeRoute(modelID: UUID(), providerID: UUID(), modelName: "cached-model")

        environment.modelContext.insert(TranslationSegment(
            paperID: environment.paper.id,
            sourceType: "html",
            targetLanguage: "zh-CN",
            sourceHash: candidate.sourceHash,
            sourceText: candidate.sourceText,
            translatedText: "Cached translation.",
            providerProfileID: route.providerProfileID,
            modelProfileID: route.modelProfileID,
            modelName: route.translationCacheIdentity
        ))
        try environment.modelContext.save()

        let client = MockTranslationLLMClient(translatedText: "Fresh translation.")
        try await HTMLTranslationPipeline(client: client).translateHTML(
            attachment: environment.attachment,
            paper: environment.paper,
            preferences: TranslationPreferencesSnapshot(
                targetLanguage: "zh-CN",
                htmlTranslationConcurrency: 2,
                babelDocQPS: 4,
                babelDocVersion: "0.5.24"
            ),
            route: route,
            apiKey: "sk-test",
            modelContext: environment.modelContext
        )

        let translatedHTML = try String(contentsOf: environment.attachment.fileURL, encoding: .utf8)
        XCTAssertTrue(translatedHTML.contains("Cached translation."))
        let cacheHitCallCount = await client.currentCallCount()
        XCTAssertEqual(cacheHitCallCount, 0)
    }

    @MainActor
    func testTranslateHTMLSkipsCacheWhenModelRouteChanges() async throws {
        let environment = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.rootURL) }

        let sourceHTML = "<html><body><p>This is a long enough paragraph for translation.</p></body></html>"
        try sourceHTML.write(to: environment.attachment.fileURL, atomically: true, encoding: .utf8)

        let prepared = try HTMLTranslationPipeline.prepareDocument(sourceHTML)
        let candidate = try XCTUnwrap(prepared.candidates.first)
        let cachedRoute = makeRoute(modelID: UUID(), providerID: UUID(), modelName: "cached-model")
        let activeRoute = makeRoute(modelID: UUID(), providerID: cachedRoute.providerProfileID, modelName: "fresh-model")

        environment.modelContext.insert(TranslationSegment(
            paperID: environment.paper.id,
            sourceType: "html",
            targetLanguage: "zh-CN",
            sourceHash: candidate.sourceHash,
            sourceText: candidate.sourceText,
            translatedText: "Old translation.",
            providerProfileID: cachedRoute.providerProfileID,
            modelProfileID: cachedRoute.modelProfileID,
            modelName: cachedRoute.translationCacheIdentity
        ))
        try environment.modelContext.save()

        let client = MockTranslationLLMClient(translatedText: "Fresh translation.")
        try await HTMLTranslationPipeline(client: client).translateHTML(
            attachment: environment.attachment,
            paper: environment.paper,
            preferences: TranslationPreferencesSnapshot(
                targetLanguage: "zh-CN",
                htmlTranslationConcurrency: 2,
                babelDocQPS: 4,
                babelDocVersion: "0.5.24"
            ),
            route: activeRoute,
            apiKey: "sk-test",
            modelContext: environment.modelContext
        )

        let translatedHTML = try String(contentsOf: environment.attachment.fileURL, encoding: .utf8)
        XCTAssertTrue(translatedHTML.contains("Fresh translation."))
        let cacheMissCallCount = await client.currentCallCount()
        XCTAssertEqual(cacheMissCallCount, 1)

        let storedSegments = try environment.modelContext.fetch(FetchDescriptor<TranslationSegment>())
        XCTAssertEqual(storedSegments.count, 2)
        XCTAssertTrue(storedSegments.contains(where: { $0.modelProfileID == activeRoute.modelProfileID }))
    }

    @MainActor
    func testTranslateHTMLSkipsCacheWhenReasoningConfigurationChanges() async throws {
        let environment = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.rootURL) }

        let sourceHTML = "<html><body><p>This is a long enough paragraph for translation.</p></body></html>"
        try sourceHTML.write(to: environment.attachment.fileURL, atomically: true, encoding: .utf8)

        let candidate = try XCTUnwrap(HTMLTranslationPipeline.prepareDocument(sourceHTML).candidates.first)
        let modelID = UUID()
        let providerID = UUID()
        let cachedRoute = makeRoute(
            modelID: modelID,
            providerID: providerID,
            modelName: "deepseek-v4-pro"
        )
        var activeRoute = cachedRoute
        activeRoute.thinkingMode = .enabled
        activeRoute.reasoningEffort = .max

        environment.modelContext.insert(TranslationSegment(
            paperID: environment.paper.id,
            sourceType: "html",
            targetLanguage: "zh-CN",
            sourceHash: candidate.sourceHash,
            sourceText: candidate.sourceText,
            translatedText: "Old translation.",
            providerProfileID: cachedRoute.providerProfileID,
            modelProfileID: cachedRoute.modelProfileID,
            modelName: cachedRoute.translationCacheIdentity
        ))
        try environment.modelContext.save()

        let client = MockTranslationLLMClient(translatedText: "Reasoned translation.")
        try await HTMLTranslationPipeline(client: client).translateHTML(
            attachment: environment.attachment,
            paper: environment.paper,
            preferences: TranslationPreferencesSnapshot(
                targetLanguage: "zh-CN",
                htmlTranslationConcurrency: 2,
                babelDocQPS: 4,
                babelDocVersion: "0.5.24"
            ),
            route: activeRoute,
            apiKey: "sk-test",
            modelContext: environment.modelContext
        )

        let translatedHTML = try String(contentsOf: environment.attachment.fileURL, encoding: .utf8)
        XCTAssertTrue(translatedHTML.contains("Reasoned translation."))
        let callCount = await client.currentCallCount()
        XCTAssertEqual(callCount, 1)
    }

    @MainActor
    func testTranslateHTMLPassesDocumentSectionNeighborsAndGlossary() async throws {
        let environment = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.rootURL) }
        let sourceHTML = """
        <html><body>
        <h2>Methods</h2>
        <p>The previous paragraph is long enough to be translated.</p>
        <p>The current paragraph is long enough to be translated.</p>
        <p>The next paragraph is long enough to be translated.</p>
        </body></html>
        """
        try sourceHTML.write(to: environment.attachment.fileURL, atomically: true, encoding: .utf8)
        let client = MockTranslationLLMClient(translatedText: "译文")

        try await HTMLTranslationPipeline(client: client).translateHTML(
            attachment: environment.attachment,
            paper: environment.paper,
            preferences: TranslationPreferencesSnapshot(
                targetLanguage: "zh-CN",
                htmlTranslationConcurrency: 1,
                babelDocQPS: 4,
                babelDocVersion: "0.5.24",
                translationGlossary: "attention = 注意力"
            ),
            route: makeRoute(modelID: UUID(), providerID: UUID(), modelName: "paper-model"),
            apiKey: "sk-test",
            modelContext: environment.modelContext
        )

        let requests = await client.currentRequests()
        let current = try XCTUnwrap(requests.first(where: {
            $0.text.contains("current paragraph")
        }))
        XCTAssertEqual(current.context.documentTitle, "Pipeline Test")
        XCTAssertEqual(current.context.sectionTitle, "Methods")
        XCTAssertEqual(
            current.context.previousSegment,
            "The previous paragraph is long enough to be translated."
        )
        XCTAssertEqual(
            current.context.nextSegment,
            "The next paragraph is long enough to be translated."
        )
        XCTAssertEqual(current.context.glossary, "attention = 注意力")
    }

    @MainActor
    func testGlossaryChangeInvalidatesHTMLTranslationCache() async throws {
        let environment = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.rootURL) }
        let sourceHTML = "<html><body><p>This is a long enough paragraph for translation.</p></body></html>"
        try sourceHTML.write(to: environment.attachment.fileURL, atomically: true, encoding: .utf8)
        let candidate = try XCTUnwrap(HTMLTranslationPipeline.prepareDocument(sourceHTML).candidates.first)
        let route = makeRoute(modelID: UUID(), providerID: UUID(), modelName: "paper-model")
        environment.modelContext.insert(TranslationSegment(
            paperID: environment.paper.id,
            sourceType: "html",
            targetLanguage: "zh-CN",
            sourceHash: candidate.sourceHash,
            sourceText: candidate.sourceText,
            translatedText: "Old glossary translation.",
            providerProfileID: route.providerProfileID,
            modelProfileID: route.modelProfileID,
            modelName: route.translationCacheIdentity
        ))
        try environment.modelContext.save()
        let client = MockTranslationLLMClient(translatedText: "New glossary translation.")

        try await HTMLTranslationPipeline(client: client).translateHTML(
            attachment: environment.attachment,
            paper: environment.paper,
            preferences: TranslationPreferencesSnapshot(
                targetLanguage: "zh-CN",
                htmlTranslationConcurrency: 1,
                babelDocQPS: 4,
                babelDocVersion: "0.5.24",
                translationGlossary: "model = 模型"
            ),
            route: route,
            apiKey: "sk-test",
            modelContext: environment.modelContext
        )

        let callCount = await client.currentCallCount()
        XCTAssertEqual(callCount, 1)
        let translatedHTML = try String(contentsOf: environment.attachment.fileURL, encoding: .utf8)
        XCTAssertTrue(translatedHTML.contains("New glossary translation."))
    }

    @MainActor
    func testPromptVersionChangeInvalidatesLegacyHTMLTranslationCache() async throws {
        let environment = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.rootURL) }
        let sourceHTML = "<html><body><p>This is a long enough paragraph for translation.</p></body></html>"
        try sourceHTML.write(to: environment.attachment.fileURL, atomically: true, encoding: .utf8)
        let candidate = try XCTUnwrap(HTMLTranslationPipeline.prepareDocument(sourceHTML).candidates.first)
        let route = makeRoute(modelID: UUID(), providerID: UUID(), modelName: "paper-model")
        let legacyCacheIdentity = route.translationCacheIdentity.replacingOccurrences(
            of: "|prompt=\(AcademicTranslationPrompt.version)",
            with: ""
        )
        environment.modelContext.insert(TranslationSegment(
            paperID: environment.paper.id,
            sourceType: "html",
            targetLanguage: "zh-CN",
            sourceHash: candidate.sourceHash,
            sourceText: candidate.sourceText,
            translatedText: "Legacy prompt translation.",
            providerProfileID: route.providerProfileID,
            modelProfileID: route.modelProfileID,
            modelName: legacyCacheIdentity
        ))
        try environment.modelContext.save()
        let client = MockTranslationLLMClient(translatedText: "Versioned prompt translation.")

        try await HTMLTranslationPipeline(client: client).translateHTML(
            attachment: environment.attachment,
            paper: environment.paper,
            preferences: TranslationPreferencesSnapshot(
                targetLanguage: "zh-CN",
                htmlTranslationConcurrency: 1,
                babelDocQPS: 4,
                babelDocVersion: "0.5.24"
            ),
            route: route,
            apiKey: "sk-test",
            modelContext: environment.modelContext
        )

        let callCount = await client.currentCallCount()
        XCTAssertEqual(callCount, 1)
        let translatedHTML = try String(contentsOf: environment.attachment.fileURL, encoding: .utf8)
        XCTAssertTrue(translatedHTML.contains("Versioned prompt translation."))
    }

    @MainActor
    private func makeEnvironment() throws -> HTMLPipelineTestEnvironment {
        let schema = Schema([
            Paper.self,
            PaperAttachment.self,
            TranslationSegment.self,
            TranslationJob.self
        ])
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let modelContext = ModelContext(container)
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let paper = Paper(title: "Pipeline Test")
        let htmlURL = rootURL.appendingPathComponent("paper.html")
        let attachment = PaperAttachment(
            paperID: paper.id,
            kind: .html,
            source: .generated,
            filename: "paper.html",
            filePath: htmlURL.path
        )

        modelContext.insert(paper)
        modelContext.insert(attachment)
        try modelContext.save()

        return HTMLPipelineTestEnvironment(
            rootURL: rootURL,
            modelContext: modelContext,
            paper: paper,
            attachment: attachment
        )
    }

    private func makeRoute(modelID: UUID, providerID: UUID, modelName: String) -> LLMModelRouteSnapshot {
        LLMModelRouteSnapshot(
            providerProfileID: providerID,
            providerName: "Provider",
            modelProfileID: modelID,
            modelProfileName: "Model",
            baseURL: "https://api.example.test/v1",
            apiKeyRef: "provider-ref",
            modelName: modelName,
            temperature: nil,
            topP: nil,
            maxTokens: nil
        )
    }
}

private struct HTMLPipelineTestEnvironment {
    let rootURL: URL
    let modelContext: ModelContext
    let paper: Paper
    let attachment: PaperAttachment
}

private actor MockTranslationLLMClient: TranslationLLMClientProtocol {
    struct Request: Sendable {
        let text: String
        let context: AcademicTranslationContext
    }

    let translatedText: String
    private(set) var callCount = 0
    private(set) var requests: [Request] = []

    init(translatedText: String) {
        self.translatedText = translatedText
    }

    func translate(
        _ text: String,
        targetLanguage _: String,
        route _: LLMModelRouteSnapshot,
        apiKey _: String,
        context: AcademicTranslationContext
    ) async throws -> String {
        callCount += 1
        requests.append(.init(text: text, context: context))
        return translatedText
    }

    func currentCallCount() -> Int {
        callCount
    }

    func currentRequests() -> [Request] {
        requests
    }
}
