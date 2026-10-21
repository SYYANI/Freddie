import CoreGraphics
import CoreText
import PDFKit
import RebuildPDFKit
import SwiftData
import XCTest
@testable import ReadPaper

final class ScannedPDFTranslationServiceTests: XCTestCase {
    /// Records requests and answers like a provider: page images get page markup, proofreading
    /// finds nothing to change, and text-only requests are translations.
    private final class ScriptedProvider: ReadPaperLLMCompleting, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var requests: [LLMCompletionRequest] = []
        var finishReason: LLMFinishReason? = .stop
        var reviewResponse = "<changes></changes><unchanged/>"
        var transcriptionResponse: String?

        func complete(request: LLMCompletionRequest) async throws -> LLMCompletionResponse {
            lock.withLock { requests.append(request) }
            // Validation retries append text feedback after the original image request.
            let user = request.messages.first { $0.role == "user" }!
            let text: String
            if user.parts == nil {
                let source = String(user.content[user.content.firstIndex(of: "\n")!...].dropFirst())
                text = source.replacingOccurrences(of: "Source words", with: "原文译文")
            } else if user.content.contains("SOURCE region") {
                text = reviewResponse
            } else if let transcriptionResponse {
                text = transcriptionResponse
            } else {
                text = """
                    <page font="serif" columns="1">
                    <header></header>
                    <body>
                    Source words $x$ on the scanned page.
                    </body>
                    <footer>
                    1
                    </footer>
                    <figures>
                    </figures>
                    <notes>
                    </notes>
                    </page>
                    """
            }
            return LLMCompletionResponse(
                text: text,
                resolvedEndpoint: nil,
                finishReason: finishReason,
                usage: LLMTokenUsage(inputTokens: 1, outputTokens: 2, totalTokens: 3)
            )
        }
    }

    private struct NoText: TextRecognizing {
        func recognizeLines(in image: RGBImage) async throws -> [OcrLine] { [] }
    }

    private final class ProgressLog: @unchecked Sendable {
        private let lock = NSLock()
        private var stages: [ScannedPDFTranslationProgress.Stage] = []

        func append(_ progress: ScannedPDFTranslationProgress) {
            lock.withLock { stages.append(progress.stage) }
        }

        var all: [ScannedPDFTranslationProgress.Stage] {
            lock.withLock { stages }
        }
    }

    private func route(model: String = "vision-model") -> LLMModelRouteSnapshot {
        LLMModelRouteSnapshot(
            providerProfileID: UUID(),
            providerName: "Provider",
            modelProfileID: UUID(),
            modelProfileName: "Model",
            baseURL: "https://api.example.com/v1",
            apiStyle: .chatCompletions,
            apiKeyRef: "ref",
            modelName: model,
            thinkingMode: .enabled,
            reasoningEffort: .high
        )
    }

    func testModelClientSendsPageImagesAndKeepsTextOnlyMessagesPlain() async throws {
        let provider = ScriptedProvider()
        let client = ReadPaperRebuildModelClient(route: route(), apiKey: "sk-secret", provider: provider)
        let completion = try await client.complete(RebuildCompletionRequest(
            label: "typeset-page-0001",
            messages: [
                RebuildMessage(role: "system", parts: [.text("Transcribe.")]),
                RebuildMessage(role: "user", parts: [.text("PART 1"), .jpeg(Data([0xFF, 0xD8]))]),
            ],
            maxTokens: 32_768
        ))

        let request = try XCTUnwrap(provider.requests.first)
        XCTAssertNil(request.messages[0].parts)
        XCTAssertEqual(request.messages[0].content, "Transcribe.")
        XCTAssertEqual(request.messages[1].parts, [.text("PART 1"), .image(data: Data([0xFF, 0xD8]), mediaType: "image/jpeg")])
        XCTAssertEqual(request.maxTokens, 32_768)
        XCTAssertEqual(request.timeoutProfile, .scannedPage)
        XCTAssertTrue(request.allowsTruncatedOutput)
        XCTAssertEqual(request.thinkingMode, .enabled)
        XCTAssertEqual(request.reasoningEffort, .high)
        XCTAssertNil(request.temperature)
        XCTAssertEqual(completion.finishReason, .stop)
        XCTAssertEqual(completion.usage, RebuildUsage(promptTokens: 1, completionTokens: 2, totalTokens: 3))
    }

    func testModelClientMapsTruncationAndOtherStops() async throws {
        let provider = ScriptedProvider()
        let client = ReadPaperRebuildModelClient(route: route(), apiKey: "sk-secret", provider: provider)
        let request = RebuildCompletionRequest(
            label: "translate-zh-page-0001",
            messages: [RebuildMessage(role: "user", parts: [.text("Translate page 1 into Simplified Chinese:\nSource words")])],
            maxTokens: 10
        )
        provider.finishReason = .length
        var completion = try await client.complete(request)
        XCTAssertEqual(completion.finishReason, .length)
        provider.finishReason = .other("content_filter")
        completion = try await client.complete(request)
        XCTAssertEqual(completion.finishReason, .other)
        provider.finishReason = nil
        completion = try await client.complete(request)
        XCTAssertEqual(completion.finishReason, .stop)
    }

    func testModelIdentityNamesTheModelButNeverTheKey() {
        let client = ReadPaperRebuildModelClient(route: route(), apiKey: "sk-secret", provider: ScriptedProvider())
        XCTAssertFalse(client.identity.contains("sk-secret"))
        XCTAssertTrue(client.identity.contains("vision-model"))
        let other = ReadPaperRebuildModelClient(route: route(model: "other-model"), apiKey: "sk-secret", provider: ScriptedProvider())
        XCTAssertNotEqual(client.identity, other.identity)
    }

    func testTranscriptionIsTheNewestScanRebuildResourceAndDisplayChoicesRoundTrip() {
        let paperID = UUID()
        let translation = PaperAttachment(paperID: paperID, kind: .translatedPDF, source: .scanRebuild, filename: "t.pdf", filePath: "t.pdf")
        let latexSource = PaperAttachment(paperID: paperID, kind: .resource, source: .latexTrans, filename: "src", filePath: "src")
        let older = PaperAttachment(paperID: paperID, kind: .resource, source: .scanRebuild, filename: "a.pdf", filePath: "a.pdf")
        let newer = PaperAttachment(paperID: paperID, kind: .resource, source: .scanRebuild, filename: "b.pdf", filePath: "b.pdf")
        newer.createdAt = older.createdAt.addingTimeInterval(1)
        XCTAssertNil(ScannedPDFTranscription.attachment(in: [translation, latexSource]))
        XCTAssertTrue(ScannedPDFTranscription.attachment(in: [newer, translation, older]) === newer)

        let ids: Set<UUID> = [UUID(), UUID()]
        XCTAssertEqual(ScannedPDFTranscription.decode(ScannedPDFTranscription.encode(ids)), ids)
        XCTAssertEqual(ScannedPDFTranscription.decode(""), [])
    }

    func testRunOverFirstPagesLeavesTranslationPartial() {
        XCTAssertEqual(ScannedPDFTranslationService.translatedLastPage(pages: [1, 2], pageCount: 9), 2)
        XCTAssertNil(ScannedPDFTranslationService.translatedLastPage(pages: Array(1...9), pageCount: 9))
        XCTAssertNil(ScannedPDFTranslationService.translatedLastPage(pages: nil, pageCount: 9))
    }

    func testOnlySimplifiedChineseIsSupported() {
        XCTAssertTrue(ScannedPDFTranslationPreferences.supports(targetLanguage: TranslationTargetLanguage.simplifiedChinese.code))
        XCTAssertFalse(ScannedPDFTranslationPreferences.supports(targetLanguage: TranslationTargetLanguage.english.code))
    }

    func testRebuildErrorsBecomeReaderMessages() {
        XCTAssertEqual(ScannedPDFTranslationError(.noPagesRebuilt(firstFailure: "transcribing: 401")), .noPagesRebuilt("transcribing: 401"))
        XCTAssertEqual(ScannedPDFTranslationError(.unreadableInput), .unreadablePDF)
        XCTAssertEqual(ScannedPDFTranslationError(.renderingFailed(page: 3)), .renderingFailed(page: 3))
        XCTAssertNil(ScannedPDFTranslationError(.incompleteModelOutput(label: "x", finishReason: "other")))
        for error in [ScannedPDFTranslationError.xelatexNotFound, .unsupportedTargetLanguage, .incompleteTeXInstallation("x"),
                      .unreadablePDF, .renderingFailed(page: 2), .noPagesRebuilt("y"), .outputNotWritten] {
            XCTAssertFalse((error.errorDescription ?? "").isEmpty)
        }
    }

    @MainActor
    func testScannedPageRouteUsesItsOwnModelOrFallsBackToThePDFModel() throws {
        let keychainStore = KeychainStore(service: "ScannedPDFTranslationServiceTests.\(UUID().uuidString)", accessPolicy: .unprotected)
        let suite = "ScannedPDFTranslationServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try ModelContainer(
            for: LLMProviderProfile.self, LLMModelProfile.self, AppSettings.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let modelContext = ModelContext(container)
        let provider = LLMProviderProfile(name: "Provider", baseURL: "https://api.example.com/v1", apiKeyRef: "scan-ref", testModel: "m")
        let pdfModel = LLMModelProfile(providerID: provider.id, name: "PDF", modelName: "text-model")
        let visionModel = LLMModelProfile(providerID: provider.id, name: "Vision", modelName: "vision-model")
        let settings = AppSettings(selectedHTMLModelProfileID: pdfModel.id, selectedPDFModelProfileID: pdfModel.id)
        modelContext.insert(provider)
        modelContext.insert(pdfModel)
        modelContext.insert(visionModel)
        modelContext.insert(settings)
        try modelContext.save()
        try keychainStore.save("sk-test", account: provider.apiKeyRef)
        defer { try? keychainStore.delete(account: provider.apiKeyRef) }
        let resolver = LLMRouteResolver(
            keychainStore: keychainStore, apiStyleStore: LLMProviderAPIStyleStore(userDefaults: defaults), userDefaults: defaults
        )

        XCTAssertEqual(try resolver.resolveScannedPageRoute(settings: settings, modelContext: modelContext).snapshot.modelName, "text-model")
        defaults.set(visionModel.id.uuidString, forKey: ScannedPDFTranslationPreferences.transcriptionModelProfileIDKey)
        XCTAssertEqual(try resolver.resolveScannedPageRoute(settings: settings, modelContext: modelContext).snapshot.modelName, "vision-model")
        XCTAssertEqual(try resolver.resolvePDFRoute(settings: settings, modelContext: modelContext).snapshot.modelName, "text-model")
    }

    /// The whole route with a scripted provider: XeLaTeX check, transcription, proofreading,
    /// translation and typesetting into the paper's translations folder, reusing checkpoints.
    func testTranslatesAScannedPDFIntoThePaperFolderAndReusesFinishedPages() async throws {
        try await assertTranslationReusesFinishedPages()
    }

    func testUnusableProofreadingKeepsTheDraftAndContinuesTranslation() async throws {
        try await assertTranslationReusesFinishedPages(rejectReview: true)
    }

    func testCentSymbolAndColumnBreakAfterCaptionTranslateAndReuseFinishedPages() async throws {
        try await assertTranslationReusesFinishedPages(transcriptionResponse: #"""
            <page font="serif" columns="2">
            <header></header>
            <body>
            \begin{multicols}{2}
            \begin{center}
            Left caption
            \end{center}
            \columnbreak
            {\small
            Source words
            on the scanned page.
            }
            \end{multicols}
            </body>
            <footer>\textcopyright 1984 75\cent</footer>
            </page>
            """#)
    }

    /// Translating the first page of a longer scan yields a partial translation, not one padded
    /// with the untranslated scan; the transcription still has every page.
    func testTranslatingTheFirstPagesEndsTheTranslationThere() async throws {
        let xelatex = try XCTUnwrap(
            ScannedPDFTranslationService.locateXeLaTeX(userDefaults: UserDefaults(suiteName: UUID().uuidString)!),
            "XeLaTeX required"
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ScannedPDFTranslation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fileStore = PaperFileStore(applicationSupportDirectory: root)
        let paperID = UUID()
        let input = root.appendingPathComponent("scan.pdf")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.makePDF(at: input, text: "Original scanned words", pageCount: 3)

        let service = ScannedPDFTranslationService(
            fileStore: fileStore, recognizer: NoText(), provider: ScriptedProvider(), compiler: XeLaTeXCompiler(executable: xelatex)
        )
        let route = ResolvedLLMModelRoute(snapshot: route(), apiKey: "sk-test")
        let output = try await service.translate(ScannedPDFTranslationRequest(
            paperID: paperID, inputPDF: input, pages: [1], transcriptionRoute: route, translationRoute: route
        )) { _ in }

        XCTAssertEqual(output.translatedLastPage, 1)
        XCTAssertEqual(PDFDocument(url: output.outputPDF)?.pageCount, 1)
        let text = try XCTUnwrap(PDFDocument(url: output.outputPDF)?.page(at: 0)?.string).replacingOccurrences(of: " ", with: "")
        XCTAssertTrue(text.contains("原文译文"), text)
        XCTAssertEqual(PDFDocument(url: try XCTUnwrap(output.transcriptionPDF))?.pageCount, 3)
    }

    private func assertTranslationReusesFinishedPages(rejectReview: Bool = false, transcriptionResponse: String? = nil) async throws {
        let xelatex = try XCTUnwrap(
            ScannedPDFTranslationService.locateXeLaTeX(userDefaults: UserDefaults(suiteName: UUID().uuidString)!),
            "XeLaTeX required"
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ScannedPDFTranslation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fileStore = PaperFileStore(applicationSupportDirectory: root)
        let paperID = UUID()
        let input = root.appendingPathComponent("scan.pdf")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.makePDF(at: input, text: "Original scanned words")

        let provider = ScriptedProvider()
        provider.transcriptionResponse = transcriptionResponse
        if rejectReview {
            provider.reviewResponse = "<page font=\"serif\"><body>\\input{x}</body></page>"
        }
        let service = ScannedPDFTranslationService(
            fileStore: fileStore, recognizer: NoText(), provider: provider, compiler: XeLaTeXCompiler(executable: xelatex)
        )
        let route = ResolvedLLMModelRoute(snapshot: route(), apiKey: "sk-test")
        let request = ScannedPDFTranslationRequest(
            paperID: paperID, inputPDF: input, pages: nil, transcriptionRoute: route, translationRoute: route
        )
        let log = ProgressLog()
        let output = try await service.translate(request) { log.append($0) }

        XCTAssertEqual(output.outputPDF, try fileStore.translationsDirectory(for: paperID).appendingPathComponent("scan-rebuild.zh.pdf"))
        XCTAssertEqual(output.rebuiltPages, [1])
        XCTAssertTrue(output.fallbacks.isEmpty)
        let text = try XCTUnwrap(PDFDocument(url: output.outputPDF)?.page(at: 0)?.string).replacingOccurrences(of: " ", with: "")
        XCTAssertTrue(text.contains("原文译文"), text)
        let transcription = try XCTUnwrap(output.transcriptionPDF)
        XCTAssertEqual(transcription, try service.artifactsDirectory(for: paperID).appendingPathComponent("transcription.pdf"))
        XCTAssertTrue(try XCTUnwrap(PDFDocument(url: transcription)?.page(at: 0)?.string).contains("Source words"))
        XCTAssertEqual(log.all.first, .checkingTeX)
        XCTAssertEqual(log.all.last, .rebuilding(.assembling))
        let expectedRequests = rejectReview ? 5 : 3  // transcription, up to three review attempts, translation
        XCTAssertEqual(provider.requests.count, expectedRequests)
        if rejectReview {
            let stateURL = try service.artifactsDirectory(for: paperID).appendingPathComponent("typeset/page-0001.json")
            let state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
            XCTAssertEqual(state["rounds"] as? Int, 1)
            XCTAssertEqual((state["usage"] as? [String: Int])?["total_tokens"], 12)
            XCTAssertTrue((state["changes"] as? [String])?.last?.contains("校对结果被拒绝") == true)
        }

        _ = try await service.translate(request) { _ in }
        XCTAssertEqual(provider.requests.count, expectedRequests)
    }

    private static func makePDF(at url: URL, text: String, pageCount: Int = 1) throws {
        var box = CGRect(x: 0, y: 0, width: 300, height: 400)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Times-Roman" as CFString, 11, nil),
        ]))
        for _ in 0..<pageCount {
            context.beginPDFPage(nil)
            context.textPosition = CGPoint(x: 40, y: 340)
            CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF()
    }
}
