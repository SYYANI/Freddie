import XCTest
@testable import ReadPaper

final class TranslationOutputValidatorTests: XCTestCase {
    private let source = "The school texts found in 1st millennium Babylonian contexts contain many of the same texts and genres."
    private let context = AcademicTranslationContext(
        documentTitle: "Gods in the Classroom",
        sectionTitle: "Identifying Religious Education",
        previousSegment: "The extant written material produced during formal education is referred to as school texts.",
        nextSegment: "In the 1st millennium there existed at least two visible pedagogical spheres of influence."
    )

    func testAcceptsFaithfulTranslation() {
        XCTAssertNil(TranslationOutputValidator.issue(
            in: "在公元前一千纪巴比伦语境中发现的学校文本包含许多相同的文本和体裁。",
            source: source,
            context: context
        ))
    }

    func testRejectsEchoedPromptEnvelope() {
        let echoed = AcademicTranslationPrompt.userPrompt(sourceText: source, context: context)
        XCTAssertEqual(TranslationOutputValidator.issue(in: echoed, source: source, context: context), .promptEcho)

        let flattened = echoed.replacingOccurrences(of: "\n", with: " ")
        let withOriginalPrefix = source + "\n" + flattened
        XCTAssertEqual(
            TranslationOutputValidator.issue(in: withOriginalPrefix, source: source, context: context),
            .promptEcho
        )
    }

    func testRejectsUntranslatedSourceIgnoringQuotesAndWhitespace() {
        let echoed = "  the school texts found in 1st  millennium Babylonian contexts\ncontain many of the same texts and genres "
        XCTAssertEqual(TranslationOutputValidator.issue(in: echoed, source: source, context: context), .sourceEcho)
    }

    func testAllowsIdenticalShortSegments() {
        XCTAssertNil(TranslationOutputValidator.issue(
            in: "BERT",
            source: "BERT",
            context: AcademicTranslationContext()
        ))
    }

    func testRejectsNeighborContextEcho() {
        let output = "学校文本包含许多相同的文本。 In the 1st millennium there existed at least two visible pedagogical spheres of influence."
        XCTAssertEqual(TranslationOutputValidator.issue(in: output, source: source, context: context), .contextEcho)
    }

    func testRejectsExcessivelyLongOutput() {
        let output = String(repeating: "解释", count: source.count * 3)
        XCTAssertEqual(TranslationOutputValidator.issue(in: output, source: source, context: context), .excessiveLength)
    }

    func testPlaceholderMismatchIsNonFatal() {
        let source = "We minimize [PROTECTED_0] subject to [PROTECTED_1] as shown in prior work."
        XCTAssertNil(TranslationOutputValidator.issue(
            in: "我们在 [PROTECTED_1] 约束下最小化 [PROTECTED_0]，如先前工作所示。",
            source: source,
            context: AcademicTranslationContext()
        ))
        let issue = TranslationOutputValidator.issue(
            in: "我们最小化 [PROTECTED_0]，如先前工作所示。",
            source: source,
            context: AcademicTranslationContext()
        )
        XCTAssertEqual(issue, .placeholderMismatch)
        XCTAssertEqual(issue?.isFatal, false)
    }

    func testValidatedTranslateFallsBackToPlaceholderMismatchAfterRetries() async throws {
        let source = "We minimize [PROTECTED_0] subject to the stated constraints in practice."
        let client = ScriptedTranslationClient(responses: ["我们在实践中按约束最小化目标。"])

        let translation = try await client.validatedTranslate(
            source,
            targetLanguage: "zh-CN",
            route: Self.route,
            apiKey: "sk-test",
            context: AcademicTranslationContext()
        )

        XCTAssertEqual(translation, "我们在实践中按约束最小化目标。")
        let callCount = await client.callCount
        XCTAssertEqual(callCount, TranslationOutputValidator.maximumAttempts)
    }

    func testValidatedTranslateThrowsWhenEveryAttemptEchoes() async {
        let client = ScriptedTranslationClient(responses: [source])

        do {
            _ = try await client.validatedTranslate(
                source,
                targetLanguage: "zh-CN",
                route: Self.route,
                apiKey: "sk-test",
                context: context
            )
            XCTFail("Expected validation error")
        } catch let error as TranslationOutputValidationError {
            XCTAssertEqual(error.issue, .sourceEcho)
            XCTAssertEqual(error.attempts, TranslationOutputValidator.maximumAttempts)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testEchoedEnvelopeRetriesWithPlainPrompt() async throws {
        let echoed = AcademicTranslationPrompt.userPrompt(sourceText: source, context: context)
        let client = ScriptedTranslationClient(responses: [echoed, "学校文本包含许多相同的文本和体裁。"])

        let result = try await client.validatedTranslation(
            source,
            targetLanguage: "zh-CN",
            route: Self.route,
            apiKey: "sk-test",
            context: context,
            startsWithPlainPrompt: false
        )

        XCTAssertEqual(result.text, "学校文本包含许多相同的文本和体裁。")
        XCTAssertTrue(result.neededPlainPrompt)
        let contexts = await client.contexts
        let styles = contexts.map(\.promptStyle)
        XCTAssertEqual(styles, [.contextual, .plain])
    }

    func testOtherEchoesDropNeighborsBeforeTheFinalPlainAttempt() async throws {
        let client = ScriptedTranslationClient(responses: [source, source, "学校文本包含许多相同的文本和体裁。"])

        let result = try await client.validatedTranslation(
            source,
            targetLanguage: "zh-CN",
            route: Self.route,
            apiKey: "sk-test",
            context: context,
            startsWithPlainPrompt: false
        )

        XCTAssertFalse(result.neededPlainPrompt)
        let contexts = await client.contexts
        XCTAssertEqual(contexts.map(\.promptStyle), [.contextual, .contextual, .plain])
        XCTAssertNotNil(contexts[0].nextSegment)
        XCTAssertNil(contexts[1].nextSegment)
        XCTAssertEqual(contexts[1].documentTitle, "Gods in the Classroom")
    }

    func testTranslationOnlyRouteStartsWithPlainPrompt() async throws {
        var route = Self.route
        route.translationModelKind = .translationOnly
        let client = ScriptedTranslationClient(responses: ["学校文本包含许多相同的文本和体裁。"])

        _ = try await client.validatedTranslate(
            source,
            targetLanguage: "zh-CN",
            route: route,
            apiKey: "sk-test",
            context: context
        )

        let contexts = await client.contexts
        XCTAssertEqual(contexts.map(\.promptStyle), [.plain])

        // Only an explicit kind starts plain; the model name is never guessed from.
        route.modelName = "HY-MT1.5-1.8B-8bit"
        route.translationModelKind = .automatic
        XCTAssertFalse(route.startsWithPlainTranslationPrompt)
        XCTAssertTrue(route.adaptsTranslationPrompt)
        route.translationModelKind = .general
        XCTAssertFalse(route.startsWithPlainTranslationPrompt)
        XCTAssertFalse(route.adaptsTranslationPrompt)
    }

    func testProbeFindsGeneralModel() async throws {
        let client = ScriptedTranslationClient(responses: ["注意力层让每个词元权衡序列中的所有其他词元。"])

        let outcome = try await TranslationModelKindProbe.detect(
            client: client,
            route: Self.route,
            apiKey: "sk-test",
            targetLanguage: "zh-CN"
        )

        XCTAssertEqual(outcome.result, .general)
        let contexts = await client.contexts
        XCTAssertEqual(contexts.map(\.promptStyle), [.contextual])
        XCTAssertNotNil(contexts.first?.previousSegment)
    }

    func testProbeFindsTranslationOnlyModelThatTranslatesTheEnvelope() async throws {
        let echoed = AcademicTranslationPrompt.userPrompt(
            sourceText: TranslationModelKindProbe.source,
            context: TranslationModelKindProbe.context
        )
        let client = ScriptedTranslationClient(responses: [echoed, "注意力层让每个词元权衡序列中的所有其他词元。"])

        let outcome = try await TranslationModelKindProbe.detect(
            client: client,
            route: Self.route,
            apiKey: "sk-test",
            targetLanguage: "zh-CN"
        )

        XCTAssertEqual(outcome.result, .translationOnly)
        XCTAssertEqual(outcome.contextualOutput, echoed)
        let contexts = await client.contexts
        XCTAssertEqual(contexts.map(\.promptStyle), [.contextual, .plain])
    }

    func testProbeIsInconclusiveWhenNeitherPromptWorks() async throws {
        let untranslated = ScriptedTranslationClient(responses: [TranslationModelKindProbe.source])
        let first = try await TranslationModelKindProbe.detect(
            client: untranslated,
            route: Self.route,
            apiKey: "sk-test",
            targetLanguage: "zh-CN"
        )
        XCTAssertEqual(first.result, .inconclusive(.sourceEcho))
        let untranslatedCalls = await untranslated.callCount
        XCTAssertEqual(untranslatedCalls, 1)

        let echoed = AcademicTranslationPrompt.userPrompt(
            sourceText: TranslationModelKindProbe.source,
            context: TranslationModelKindProbe.context
        )
        let echoing = ScriptedTranslationClient(responses: [echoed, TranslationModelKindProbe.source])
        let second = try await TranslationModelKindProbe.detect(
            client: echoing,
            route: Self.route,
            apiKey: "sk-test",
            targetLanguage: "zh-CN"
        )
        XCTAssertEqual(second.result, .inconclusive(.sourceEcho))
    }

    func testPlainPromptHasNoEnvelopeOrSystemPrompt() {
        let plainContext = AcademicTranslationContext(
            documentTitle: "Gods in the Classroom",
            previousSegment: "Earlier text.",
            glossary: "school texts 翻译成 学校文本",
            promptStyle: .plain
        )
        let messages = TranslationLLMClient.messages(for: source, targetLanguage: "zh-CN", context: plainContext)

        XCTAssertEqual(messages.map(\.role), ["user"])
        let prompt = messages[0].content
        XCTAssertEqual(
            prompt,
            "参考下面的翻译：\nschool texts 翻译成 学校文本\n\n把下面的文本翻译成简体中文，不要额外解释。\n\n\(source)"
        )
        XCTAssertFalse(AcademicTranslationPrompt.envelopeLabels.contains(where: prompt.contains))
        XCTAssertFalse(prompt.contains("Gods in the Classroom"))
        XCTAssertTrue(AcademicTranslationPrompt.plainPrompt(sourceText: "x", targetLanguage: "zh-TW", glossary: nil)
            .hasPrefix("把下面的文本翻译成繁体中文"))
        XCTAssertEqual(
            AcademicTranslationPrompt.plainPrompt(sourceText: "x", targetLanguage: "ja", glossary: nil),
            "Translate the following segment into Japanese, without additional explanation.\n\nx"
        )

        let contextual = TranslationLLMClient.messages(for: source, targetLanguage: "zh-CN", context: context)
        XCTAssertEqual(contextual.map(\.role), ["system", "user"])
    }

    private static let route = LLMModelRouteSnapshot(
        providerProfileID: UUID(),
        providerName: "Provider",
        modelProfileID: UUID(),
        modelProfileName: "Model",
        baseURL: "https://api.example.test/v1",
        apiKeyRef: "provider-ref",
        modelName: "model",
        temperature: nil,
        topP: nil,
        maxTokens: nil
    )
}

private actor ScriptedTranslationClient: TranslationLLMClientProtocol {
    let responses: [String]
    private(set) var callCount = 0
    private(set) var contexts: [AcademicTranslationContext] = []

    init(responses: [String]) {
        self.responses = responses
    }

    func translate(
        _: String,
        targetLanguage _: String,
        route _: LLMModelRouteSnapshot,
        apiKey _: String,
        context: AcademicTranslationContext
    ) async throws -> String {
        callCount += 1
        contexts.append(context)
        return responses[min(callCount, responses.count) - 1]
    }
}
