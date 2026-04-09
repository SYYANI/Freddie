import SwiftData
import XCTest
@testable import ReadPaper

final class HTMLTranslationPipelineTests: XCTestCase {
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
            modelName: route.modelName
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
            modelName: cachedRoute.modelName
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
    let translatedText: String
    private(set) var callCount = 0

    init(translatedText: String) {
        self.translatedText = translatedText
    }

    func translate(
        _: String,
        targetLanguage _: String,
        route _: LLMModelRouteSnapshot,
        apiKey _: String
    ) async throws -> String {
        callCount += 1
        return translatedText
    }

    func currentCallCount() -> Int {
        callCount
    }
}
