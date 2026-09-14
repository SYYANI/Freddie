import Foundation
import XCTest
@testable import ReadPaper

final class SelectionAssistantOrchestratorTests: XCTestCase {
    func testAutomaticScopeUsesPrivacyAwareLocalFirstPolicy() {
        XCTAssertEqual(
            SelectionAssistantScopeResolver.resolve(
                SelectionAssistantRequest(action: .translate, selection: "A term", scope: .automatic)
            ),
            .nearby
        )
        XCTAssertEqual(
            SelectionAssistantScopeResolver.resolve(
                SelectionAssistantRequest(action: .explain, selection: "A term", scope: .automatic)
            ),
            .nearby
        )
        XCTAssertEqual(
            SelectionAssistantScopeResolver.resolve(
                SelectionAssistantRequest(
                    action: .ask,
                    selection: "Joint Multimodal Reinforcement Learning (RL)",
                    question: "这是什么意思",
                    scope: .automatic
                )
            ),
            .nearby
        )
        XCTAssertEqual(
            SelectionAssistantScopeResolver.resolve(
                SelectionAssistantRequest(
                    action: .ask,
                    selection: "A claim",
                    question: "How do the authors validate it?",
                    scope: .automatic
                )
            ),
            .fullPaper
        )
        XCTAssertEqual(
            SelectionAssistantScopeResolver.resolve(
                SelectionAssistantRequest(
                    action: .ask,
                    selection: "A method",
                    question: "请联网查找相关论文和最新进展",
                    scope: .automatic
                )
            ),
            .external
        )
        XCTAssertEqual(
            SelectionAssistantScopeResolver.resolve(
                SelectionAssistantRequest(
                    action: .ask,
                    selection: "A method",
                    question: "搜索一下再了解这部分内容",
                    scope: .automatic
                )
            ),
            .external
        )
        XCTAssertEqual(
            SelectionAssistantScopeResolver.resolve(
                SelectionAssistantRequest(
                    action: .ask,
                    selection: "A method",
                    question: "在全文中搜索一下这部分的定义",
                    scope: .automatic
                )
            ),
            .fullPaper
        )
        XCTAssertEqual(
            SelectionAssistantScopeResolver.resolve(
                SelectionAssistantRequest(
                    action: .ask,
                    selection: "A method",
                    question: "请联网搜索一下其他论文中的解释",
                    scope: .automatic
                )
            ),
            .external
        )
        // Search phrasings that only differ from "搜索一下" by a following
        // word used to fall through to a nearby-only answer, so no web search
        // was attempted at all.
        for question in [
            "搜索了解一下",
            "搜索了解下背景知识",
            "搜索相关信息告诉我",
            "查询下最新版本是什么"
        ] {
            XCTAssertEqual(
                SelectionAssistantScopeResolver.resolve(
                    SelectionAssistantRequest(
                        action: .ask,
                        selection: "A method",
                        question: question,
                        scope: .automatic
                    )
                ),
                .external,
                question
            )
        }
        XCTAssertEqual(
            SelectionAssistantScopeResolver.resolve(
                SelectionAssistantRequest(
                    action: .ask,
                    selection: "A method",
                    question: "这个搜索空间有多大",
                    scope: .automatic
                )
            ),
            .nearby
        )
        XCTAssertEqual(
            SelectionAssistantScopeResolver.resolve(
                SelectionAssistantRequest(
                    action: .ask,
                    selection: "A method",
                    question: "论文中的搜索算法如何工作",
                    scope: .automatic
                )
            ),
            .fullPaper
        )
        for question in [
            "我想了解一下这个公式",
            "解释一下检索增强生成",
            "这个数据库查询为什么这么慢"
        ] {
            XCTAssertEqual(
                SelectionAssistantScopeResolver.resolve(
                    SelectionAssistantRequest(
                        action: .ask,
                        selection: "A method",
                        question: question,
                        scope: .automatic
                    )
                ),
                .nearby,
                question
            )
        }
        XCTAssertEqual(
            SelectionAssistantScopeResolver.resolve(
                SelectionAssistantRequest(action: .ask, selection: "A claim", scope: .nearby)
            ),
            .nearby
        )
    }

    @MainActor
    func testFullPaperQuestionRetrievesHTMLNeighborsMetadataAndNotes() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let provider = OrchestratorProviderSpy(response: "The held-out benchmark supports the claim [S1].")
        var progress: [SelectionAssistantProgress] = []
        let orchestrator = SelectionAssistantOrchestrator(
            assistantService: SelectionAssistantService(provider: provider),
            fullTextSearchService: PaperFullTextSearchService(fileStore: fixture.fileStore),
            userDefaults: fixture.userDefaults
        )

        let result = try await orchestrator.perform(
            SelectionAssistantRequest(
                action: .ask,
                selection: "this conclusion",
                question: "How do the authors validate this conclusion on the benchmark?",
                scope: .automatic
            ),
            selection: NoteSelectionContext(
                attachmentID: fixture.attachment.id,
                quote: "this conclusion",
                htmlSelector: "rp-anchor:1"
            ),
            paper: fixture.paper,
            attachments: [fixture.attachment],
            notes: [fixture.note],
            targetLanguage: "EN",
            route: makeRoute(),
            onProgress: { progress.append($0) }
        )

        XCTAssertEqual(result.scope, .fullPaper)
        XCTAssertTrue(result.sources.contains(where: {
            $0.kind == .paperHTML && $0.htmlSelector?.contains("data-rp-assistant-block-id") == true
        }))
        XCTAssertTrue(result.sources.contains(where: { $0.kind == .userNote }))
        let selectionSource = try XCTUnwrap(result.sources.first(where: { $0.kind == .currentSelection }))
        XCTAssertEqual(selectionSource.navigationRequest?.quote, "this conclusion")
        let paperSource = try XCTUnwrap(result.sources.first(where: { $0.kind == .paperHTML }))
        XCTAssertEqual(paperSource.navigationRequest?.quote, "We validate the conclusion on a held-out benchmark.")
        XCTAssertTrue(paperSource.excerpt.contains("The setup uses a standard training split."))
        XCTAssertTrue(paperSource.excerpt.contains("The ablation confirms the same trend."))
        let noteSource = try XCTUnwrap(result.sources.first(where: { $0.kind == .userNote }))
        XCTAssertEqual(noteSource.navigationRequest?.quote, "held-out benchmark")
        XCTAssertTrue(progress.contains(.searchingFullText))
        XCTAssertTrue(progress.contains(.generatingAnswer))

        let capturedProviderRequest = await provider.lastRequest()
        let providerRequest = try XCTUnwrap(capturedProviderRequest)
        XCTAssertFalse(providerRequest.webSearchEnabled)
        let prompt = providerRequest.messages.map(\.content).joined(separator: "\n")
        XCTAssertTrue(prompt.contains("Authors: Ada Author"))
        XCTAssertTrue(prompt.contains("Abstract: A test abstract."))
        XCTAssertTrue(prompt.contains("The benchmark note identifies a caveat."))
        XCTAssertTrue(prompt.contains("We validate the conclusion on a held-out benchmark."))
    }

    @MainActor
    func testFullPaperCrossLanguageQueryDoesNotEmitMisleadingNoSupportWarning() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let provider = OrchestratorProviderSpy(response: "The paper discusses the method in its Evaluation section.")
        let orchestrator = SelectionAssistantOrchestrator(
            assistantService: SelectionAssistantService(provider: provider),
            fullTextSearchService: PaperFullTextSearchService(fileStore: fixture.fileStore),
            userDefaults: fixture.userDefaults
        )

        let result = try await orchestrator.perform(
            SelectionAssistantRequest(
                action: .ask,
                selection: "this conclusion",
                question: "论文中作者使用了什么方法？",
                scope: .automatic
            ),
            selection: NoteSelectionContext(
                attachmentID: fixture.attachment.id,
                quote: "this conclusion",
                htmlSelector: "rp-anchor:1"
            ),
            paper: fixture.paper,
            attachments: [fixture.attachment],
            notes: [],
            targetLanguage: "zh-Hans",
            route: makeRoute()
        )

        XCTAssertEqual(result.scope, .fullPaper)
        XCTAssertFalse(result.warnings.contains(AppLocalization.localized(
            "No supporting passage was found in this paper."
        )))
    }

    @MainActor
    func testExternalScopeDoesNotNetworkWhenPrivacyToggleIsOff() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        fixture.userDefaults.set(false, forKey: SelectionAssistantPreferences.externalSearchEnabledKey)
        let provider = OrchestratorProviderSpy(response: "Only paper evidence is available.")
        let orchestrator = SelectionAssistantOrchestrator(
            assistantService: SelectionAssistantService(provider: provider),
            fullTextSearchService: PaperFullTextSearchService(fileStore: fixture.fileStore),
            userDefaults: fixture.userDefaults
        )

        let result = try await orchestrator.perform(
            SelectionAssistantRequest(
                action: .ask,
                selection: "this conclusion",
                question: "Find related work.",
                scope: .external
            ),
            selection: NoteSelectionContext(
                attachmentID: fixture.attachment.id,
                quote: "this conclusion",
                htmlSelector: "rp-anchor:1"
            ),
            paper: fixture.paper,
            attachments: [fixture.attachment],
            notes: [],
            targetLanguage: "EN",
            route: makeRoute()
        )

        XCTAssertTrue(result.warnings.contains(AppLocalization.localized("External search is disabled in Settings.")))
        XCTAssertFalse(result.sources.contains(where: { $0.id == "live-web-search" }))
        let capturedProviderRequest = await provider.lastRequest()
        XCTAssertEqual(capturedProviderRequest?.webSearchEnabled, false)
    }

    @MainActor
    func testExternalScopeRequestsResponsesWebSearchWhenToggleIsOn() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        fixture.userDefaults.set(true, forKey: SelectionAssistantPreferences.externalSearchEnabledKey)
        let provider = OrchestratorProviderSpy(
            response: "The project page and repository are covered by the current web search results."
        )
        var progress: [SelectionAssistantProgress] = []
        let orchestrator = SelectionAssistantOrchestrator(
            assistantService: SelectionAssistantService(provider: provider),
            fullTextSearchService: PaperFullTextSearchService(fileStore: fixture.fileStore),
            userDefaults: fixture.userDefaults
        )

        let result = try await orchestrator.perform(
            SelectionAssistantRequest(
                action: .ask,
                selection: "this conclusion",
                question: "请联网查找该项目的主页和代码仓库。",
                scope: .external
            ),
            selection: NoteSelectionContext(
                attachmentID: fixture.attachment.id,
                quote: "this conclusion",
                htmlSelector: "rp-anchor:1"
            ),
            paper: fixture.paper,
            attachments: [fixture.attachment],
            notes: [],
            targetLanguage: "EN",
            route: makeRoute(apiStyle: .responses, baseURL: "https://api.deepseek.com"),
            onProgress: { progress.append($0) }
        )

        XCTAssertEqual(result.scope, .external)
        XCTAssertTrue(progress.contains(.searchingExternalSources))
        XCTAssertFalse(result.warnings.contains(AppLocalization.localized(
            "No supporting passage was found in this paper."
        )))
        let webSource = try XCTUnwrap(result.sources.first)
        XCTAssertEqual(webSource.kind, .external)
        XCTAssertEqual(webSource.id, "live-web-search")
        XCTAssertEqual(webSource.title, AppLocalization.localized("Live web search"))

        let capturedProviderRequest = await provider.lastRequest()
        let providerRequest = try XCTUnwrap(capturedProviderRequest)
        XCTAssertEqual(providerRequest.apiStyle, .responses)
        XCTAssertTrue(providerRequest.webSearchEnabled)
        let prompt = providerRequest.messages.map(\.content).joined(separator: "\n")
        XCTAssertTrue(prompt.contains("Live web search is enabled for this request"))
        XCTAssertTrue(prompt.contains("[S1] \(AppLocalization.localized("Live web search"))"))
        XCTAssertTrue(prompt.contains("[S1] Live web search entry is only a provisional tool placeholder"))
        XCTAssertTrue(prompt.contains("include the exact concrete URL"))
        XCTAssertTrue(prompt.contains("Never invent, guess, shorten, or reformat a URL"))
    }

    @MainActor
    func testExternalScopeWithoutResponsesRouteAddsWarningAndDoesNotEnableWebSearch() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        fixture.userDefaults.set(true, forKey: SelectionAssistantPreferences.externalSearchEnabledKey)
        let provider = OrchestratorProviderSpy(response: "Only paper evidence is available.")
        let orchestrator = SelectionAssistantOrchestrator(
            assistantService: SelectionAssistantService(provider: provider),
            fullTextSearchService: PaperFullTextSearchService(fileStore: fixture.fileStore),
            userDefaults: fixture.userDefaults
        )

        let result = try await orchestrator.perform(
            SelectionAssistantRequest(
                action: .ask,
                selection: "this conclusion",
                question: "Find related work.",
                scope: .external
            ),
            selection: NoteSelectionContext(
                attachmentID: fixture.attachment.id,
                quote: "this conclusion",
                htmlSelector: "rp-anchor:1"
            ),
            paper: fixture.paper,
            attachments: [fixture.attachment],
            notes: [],
            targetLanguage: "EN",
            route: makeRoute()
        )

        XCTAssertTrue(result.warnings.contains(AppLocalization.localized(
            "Live web search requires the selected assistant model to use the Responses API."
        )))
        XCTAssertFalse(result.sources.contains(where: { $0.id == "live-web-search" }))
        let capturedProviderRequest = await provider.lastRequest()
        XCTAssertEqual(capturedProviderRequest?.webSearchEnabled, false)
    }

    func testStreamingPartialAnswersAreCoalescedBeforeReachingTheUI() async throws {
        let provider = BurstStreamingProviderSpy(chunkCount: 240)
        let service = SelectionAssistantService(
            provider: provider,
            partialAnswerThrottleInterval: .milliseconds(5)
        )
        let collector = PartialAnswerCollector()
        let expectedAnswer = (1...240).map(String.init).joined(separator: " ")

        let result = try await service.perform(
            SelectionAssistantRequest(action: .explain, selection: "A selected passage."),
            paperTitle: "Test Paper",
            targetLanguage: "EN",
            route: makeRoute(),
            onPartialAnswer: { partialAnswer in
                await collector.append(partialAnswer)
            }
        )

        let partialAnswers = await collector.values
        XCTAssertEqual(result.answer, expectedAnswer)
        XCTAssertEqual(partialAnswers.last, expectedAnswer)
        XCTAssertLessThan(partialAnswers.count, 240)
        XCTAssertEqual(partialAnswers, partialAnswers.sorted {
            $0.count < $1.count
        })
    }

    @MainActor
    private func makeFixture() throws -> OrchestratorFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SelectionAssistantOrchestratorTests-\(UUID().uuidString)", isDirectory: true)
        let fileStore = PaperFileStore(applicationSupportDirectory: root)
        let paper = Paper(
            doi: "10.1234/example",
            title: "Evidence Paper",
            abstractText: "A test abstract.",
            authors: ["Ada Author"]
        )
        paper.localDirectoryPath = try fileStore.directory(for: paper.id).path
        let html = """
        <!doctype html><html><head><meta charset="UTF-8"></head><body>
        <h1>Evaluation</h1>
        <p>The setup uses a standard training split.</p>
        <p>We validate the conclusion on a held-out benchmark.</p>
        <p>The ablation confirms the same trend.</p>
        </body></html>
        """
        let htmlURL = try fileStore.write(Data(html.utf8), named: "paper.html", for: paper.id)
        let attachment = PaperAttachment(
            paperID: paper.id,
            kind: .html,
            source: .webPage,
            filename: "paper.html",
            filePath: htmlURL.path
        )
        let note = Note(
            paperID: paper.id,
            attachmentID: attachment.id,
            quote: "held-out benchmark",
            body: "The benchmark note identifies a caveat.",
            htmlSelector: "rp-anchor:2"
        )
        let suiteName = "SelectionAssistantOrchestratorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return OrchestratorFixture(
            root: root,
            userDefaultsSuiteName: suiteName,
            userDefaults: defaults,
            fileStore: fileStore,
            paper: paper,
            attachment: attachment,
            note: note
        )
    }

    private func makeRoute(
        apiStyle: LLMAPIStyle = .chatCompletions,
        baseURL: String = "https://example.test/v1"
    ) -> ResolvedLLMModelRoute {
        ResolvedLLMModelRoute(
            snapshot: LLMModelRouteSnapshot(
                providerProfileID: UUID(),
                providerName: "Test Provider",
                modelProfileID: UUID(),
                modelProfileName: "Assistant Model",
                baseURL: baseURL,
                apiStyle: apiStyle,
                apiKeyRef: "key-ref",
                modelName: "assistant-model"
            ),
            apiKey: "secret"
        )
    }
}

@MainActor
private struct OrchestratorFixture {
    var root: URL
    var userDefaultsSuiteName: String
    var userDefaults: UserDefaults
    var fileStore: PaperFileStore
    var paper: Paper
    var attachment: PaperAttachment
    var note: Note

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
        userDefaults.removePersistentDomain(forName: userDefaultsSuiteName)
    }
}

private actor OrchestratorProviderSpy: SelectionAssistantLLMCompleting {
    private let response: String
    private var requests: [LLMCompletionRequest] = []

    init(response: String) {
        self.response = response
    }

    func complete(request: LLMCompletionRequest) async throws -> LLMCompletionResponse {
        requests.append(request)
        return LLMCompletionResponse(text: response, resolvedEndpoint: nil)
    }

    func lastRequest() -> LLMCompletionRequest? {
        requests.last
    }
}

private actor BurstStreamingProviderSpy: SelectionAssistantLLMCompleting {
    let chunkCount: Int

    init(chunkCount: Int) {
        self.chunkCount = chunkCount
    }

    func complete(request: LLMCompletionRequest) async throws -> LLMCompletionResponse {
        LLMCompletionResponse(text: Self.answer(chunkCount: chunkCount), resolvedEndpoint: nil)
    }

    func completeStreaming(
        request: LLMCompletionRequest,
        onPartialText: @escaping @Sendable (String) async -> Void
    ) async throws -> LLMCompletionResponse {
        var accumulated = ""
        for index in 1...chunkCount {
            let token = String(index)
            accumulated += accumulated.isEmpty ? token : " \(token)"
            await onPartialText(accumulated)
        }
        return LLMCompletionResponse(text: accumulated, resolvedEndpoint: nil)
    }

    private static func answer(chunkCount: Int) -> String {
        (1...chunkCount).map(String.init).joined(separator: " ")
    }
}

private actor PartialAnswerCollector {
    private(set) var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }
}
