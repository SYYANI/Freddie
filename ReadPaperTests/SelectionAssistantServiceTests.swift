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

        XCTAssertEqual(output, "译文")
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
        let request = SelectionAssistantRequest(
            action: .ask,
            selection: String(repeating: "s", count: 5_000),
            localContext: String(repeating: "c", count: 9_000),
            question: String(repeating: "q", count: 2_000)
        )

        XCTAssertEqual(request.selection.count, 4_000)
        XCTAssertEqual(request.localContext?.count, 8_000)
        XCTAssertEqual(request.question?.count, 1_000)
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
