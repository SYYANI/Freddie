import XCTest
@testable import ReadPaper

final class SelectionAssistantServiceTests: XCTestCase {
    func testTranslationUsesSelectedTextAndLocalContext() async throws {
        let provider = SelectionAssistantProviderSpy(response: "译文")
        let service = SelectionAssistantService(provider: provider)

        let output = try await service.perform(
            SelectionAssistantRequest(
                action: .translate,
                selection: " ambiguous term ",
                localContext: "The previous and current paragraphs."
            ),
            paperTitle: "A Test Paper",
            targetLanguage: "zh-CN",
            route: makeRoute()
        )

        XCTAssertEqual(output.answer, "译文")
        XCTAssertEqual(output.scope, .nearby)
        let capturedRequest = await provider.lastRequest()
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.model, "test-model")
        XCTAssertTrue(request.messages[0].content.contains("Translate only SELECTED_TEXT into zh-CN"))
        XCTAssertTrue(request.messages[0].content.contains("untrusted source material"))
        XCTAssertTrue(request.messages[1].content.contains("<<<SELECTED_TEXT>>>\nambiguous term"))
        XCTAssertTrue(request.messages[1].content.contains("<<<LOCAL_CONTEXT>>>\nThe previous and current paragraphs."))
    }

    func testExplanationPromptRequestsContextualAcademicExplanation() {
        let messages = SelectionAssistantPrompt.messages(
            for: SelectionAssistantRequest(
                action: .explain,
                selection: "static site generator",
                localContext: "This tool emits HTML pages."
            ),
            paperTitle: "Paper Blog",
            targetLanguage: "zh-CN"
        )

        XCTAssertTrue(messages[0].content.contains("Explain SELECTED_TEXT clearly"))
        XCTAssertTrue(messages[0].content.contains("Do not invent claims"))
        XCTAssertTrue(messages[1].content.contains("<<<PAPER_TITLE>>>\nPaper Blog"))
    }

    func testEvidenceSourcesAreLabeledAndReturnedStructurally() async throws {
        let provider = SelectionAssistantProviderSpy(response: "The claim is supported [S1].")
        let service = SelectionAssistantService(provider: provider)
        let source = AssistantSource(
            id: "source-1",
            kind: .paperHTML,
            title: "§3.2 Method",
            excerpt: "The method uses a constrained decoder.",
            sectionPath: ["3 Method", "3.2 Decoder"],
            attachmentID: UUID(),
            htmlSelector: "[data-rp-assistant-block-id=\"source-1\"]"
        )

        let result = try await service.perform(
            SelectionAssistantRequest(
                action: .ask,
                selection: "constrained decoder",
                question: "How is this validated?",
                scope: .fullPaper
            ),
            paperTitle: "Paper",
            targetLanguage: "EN",
            route: makeRoute(),
            paperMetadata: "Authors: A. Author",
            userNotes: "[N1] This assumption matters.",
            sources: [source]
        )

        XCTAssertEqual(result.sources, [source])
        XCTAssertEqual(result.scope, .fullPaper)
        let providerRequest = await provider.lastRequest()
        let captured = try XCTUnwrap(providerRequest)
        XCTAssertTrue(captured.messages[0].content.contains("cite their labels like [S1]"))
        XCTAssertTrue(captured.messages[1].content.contains("<<<PAPER_METADATA>>>"))
        XCTAssertTrue(captured.messages[1].content.contains("<<<USER_NOTES>>>"))
        XCTAssertTrue(captured.messages[1].content.contains("[S1] §3.2 Method"))
        XCTAssertTrue(captured.messages[1].content.contains("SECTION_PATH: 3 Method > 3.2 Decoder"))
    }

    func testWebSearchGuidanceRequiresS1CitationsWithConcreteURLs() {
        let messages = SelectionAssistantPrompt.messages(
            for: SelectionAssistantRequest(
                action: .ask,
                selection: "a claim",
                question: "Find the project page and repository.",
                scope: .external
            ),
            paperTitle: "Paper",
            targetLanguage: "EN",
            webSearchEnabled: true
        )

        let system = messages[0].content
        XCTAssertTrue(system.contains("Live web search is enabled for this request"))
        XCTAssertTrue(system.contains("cite every claim that relies on them as [S1]"))
        XCTAssertTrue(system.contains("Include the concrete URL each relied-on result provides"))
        XCTAssertTrue(system.contains("Never invent, guess, or reformat a URL"))
    }

    func testWebSearchResultsBecomeClickableS1SourceTags() async throws {
        let provider = SelectionAssistantProviderSpy(
            response: "Current information [S1] https://docs.example.test/current",
            webSearchSources: [
                LLMWebSearchSource(
                    urlString: "https://docs.example.test/current",
                    title: "Current documentation"
                )!
            ]
        )
        let service = SelectionAssistantService(provider: provider)

        let result = try await service.perform(
            SelectionAssistantRequest(
                action: .ask,
                selection: "a claim",
                question: "Search for current documentation.",
                scope: .external
            ),
            paperTitle: "Paper",
            targetLanguage: "EN",
            route: makeRoute(),
            webSearchEnabled: true
        )

        XCTAssertEqual(result.sources.first?.id, AssistantSource.liveWebSearchID)
        let webResult = try XCTUnwrap(result.sources.first(where: \.isLiveWebSearchResult))
        XCTAssertEqual(webResult.title, "docs.example.test")
        XCTAssertEqual(webResult.excerpt, "Current documentation\nhttps://docs.example.test/current")
        XCTAssertEqual(webResult.urlString, "https://docs.example.test/current")
    }

    func testQuestionIsRequiredForAskAction() async {
        let provider = SelectionAssistantProviderSpy(response: "unused")
        let service = SelectionAssistantService(provider: provider)

        do {
            _ = try await service.perform(
                SelectionAssistantRequest(action: .ask, selection: "selected text"),
                paperTitle: "Paper",
                targetLanguage: "EN",
                route: makeRoute()
            )
            XCTFail("Expected a missing-question error")
        } catch {
            guard let providerError = error as? LLMProviderError,
                  case .invalidConfiguration = providerError else {
                return XCTFail("Expected invalidConfiguration, got \(error)")
            }
            let capturedRequest = await provider.lastRequest()
            XCTAssertNil(capturedRequest)
        }
    }

    func testRequestLimitsUntrustedInputSizes() {
        let history = (0..<15).map {
            SelectionAssistantConversationTurn(question: "Question \($0)", answer: "Answer \($0)")
        }
        let request = SelectionAssistantRequest(
            action: .ask,
            selection: String(repeating: "s", count: 5_000),
            localContext: String(repeating: "c", count: 9_000),
            question: String(repeating: "q", count: 2_000),
            conversation: history
        )

        XCTAssertEqual(request.selection.count, 4_000)
        XCTAssertEqual(request.localContext?.count, 8_000)
        XCTAssertEqual(request.question?.count, 1_000)
        XCTAssertEqual(request.conversation.count, 12)
        XCTAssertEqual(request.conversation.first?.question, "Question 3")
    }

    func testFollowUpPromptIncludesPriorConversationInOrder() {
        let messages = SelectionAssistantPrompt.messages(
            for: SelectionAssistantRequest(
                action: .ask,
                selection: "A selected claim.",
                localContext: "Nearby evidence.",
                question: "How does that affect the conclusion?",
                conversation: [
                    SelectionAssistantConversationTurn(
                        question: "What does this claim mean?",
                        answer: "It describes the model assumption."
                    )
                ]
            ),
            paperTitle: "Paper",
            targetLanguage: "EN"
        )

        XCTAssertEqual(messages.map(\.role), ["system", "user", "user", "assistant", "user"])
        XCTAssertTrue(messages[1].content.contains("<<<SELECTED_TEXT>>>\nA selected claim."))
        XCTAssertTrue(messages[2].content.contains("<<<PRIOR_QUESTION>>>\nWhat does this claim mean?"))
        XCTAssertEqual(messages[3].content, "It describes the model assumption.")
        XCTAssertTrue(messages[4].content.contains("<<<QUESTION>>>\nHow does that affect the conclusion?"))
    }

    private func makeRoute() -> ResolvedLLMModelRoute {
        ResolvedLLMModelRoute(
            snapshot: LLMModelRouteSnapshot(
                providerProfileID: UUID(),
                providerName: "Test Provider",
                modelProfileID: UUID(),
                modelProfileName: "Test Model",
                baseURL: "https://example.test/v1",
                apiKeyRef: "test-key-ref",
                modelName: "test-model"
            ),
            apiKey: "secret"
        )
    }
}

private actor SelectionAssistantProviderSpy: SelectionAssistantLLMCompleting {
    private let response: String
    private let webSearchSources: [LLMWebSearchSource]
    private var requests: [LLMCompletionRequest] = []

    init(response: String, webSearchSources: [LLMWebSearchSource] = []) {
        self.response = response
        self.webSearchSources = webSearchSources
    }

    func complete(request: LLMCompletionRequest) async throws -> LLMCompletionResponse {
        requests.append(request)
        return LLMCompletionResponse(
            text: response,
            resolvedEndpoint: nil,
            webSearchSources: webSearchSources
        )
    }

    func lastRequest() -> LLMCompletionRequest? {
        requests.last
    }
}
