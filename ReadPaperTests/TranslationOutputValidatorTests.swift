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

    init(responses: [String]) {
        self.responses = responses
    }

    func translate(
        _: String,
        targetLanguage _: String,
        route _: LLMModelRouteSnapshot,
        apiKey _: String,
        context _: AcademicTranslationContext
    ) async throws -> String {
        callCount += 1
        return responses[min(callCount, responses.count) - 1]
    }
}
