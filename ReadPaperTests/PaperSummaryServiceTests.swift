import AppKit
import CoreText
import SwiftData
import XCTest
@testable import ReadPaper

@MainActor
final class PaperSummaryServiceTests: XCTestCase {
    func testPDFWithoutConfigurationHidesEvenOfficialArxivAbstract() async throws {
        let fixture = try makeFixture(source: .arxivPDF)
        let service = PaperSummaryService(complete: { _ in
            XCTFail("An unconfigured import must not send a request")
            throw LLMProviderError.emptyResponse
        })

        let content = try await service.content(for: fixture.paper, settings: fixture.settings, modelContext: fixture.context)

        XCTAssertEqual(content, .hidden)
        XCTAssertEqual(fixture.paper.abstractText, "The original official abstract.")
        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<TranslationSegment>()).isEmpty)
    }

    func testGeneratedSummaryIsLimitedAndCachedWithoutChangingMetadata() async throws {
        let fixture = try makeFixture(source: .arxivPDF)
        let route = makeRoute()
        var requests: [LLMCompletionRequest] = []
        let service = PaperSummaryService(resolveRoute: { _, _ in route }, loadAPIKey: { _ in "test-key" }, complete: { request in
            requests.append(request)
            return LLMCompletionResponse(text: String(repeating: "摘", count: 180), resolvedEndpoint: nil)
        })

        let first = try await service.content(for: fixture.paper, settings: fixture.settings, modelContext: fixture.context)
        let second = try await service.content(for: fixture.paper, settings: fixture.settings, modelContext: fixture.context)

        guard case .summary(let text) = first else { return XCTFail("Expected a summary") }
        XCTAssertEqual(text.count, 140)
        XCTAssertEqual(first, second)
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(requests[0].messages[0].content.contains("中文（简体）"))
        XCTAssertTrue(requests[0].messages[0].content.contains("not 140 words"))
        XCTAssertTrue(requests[0].messages[1].content.contains(fixture.paper.abstractText))
        XCTAssertEqual(fixture.paper.abstractText, "The original official abstract.")
        let cached = try XCTUnwrap(fixture.context.fetch(FetchDescriptor<TranslationSegment>()).first)
        XCTAssertEqual(cached.sourceType, "pdf-summary")
        XCTAssertEqual(cached.providerProfileID, route.providerProfileID)
        XCTAssertEqual(cached.modelProfileID, route.modelProfileID)
    }

    func testCachedSummaryDoesNotReadAPIKey() async throws {
        let fixture = try makeFixture()
        let route = makeRoute()
        var keyReads = 0
        let service = PaperSummaryService(resolveRoute: { _, _ in route }, loadAPIKey: { _ in
            keyReads += 1
            return "test-key"
        }, complete: { _ in
            LLMCompletionResponse(text: "A short summary.", resolvedEndpoint: nil)
        })

        _ = try await service.content(for: fixture.paper, settings: fixture.settings, modelContext: fixture.context)
        let cached = try await service.content(for: fixture.paper, settings: fixture.settings, modelContext: fixture.context)

        XCTAssertEqual(cached, .summary("A short summary."))
        // Reading the key may show Touch ID or Face ID; a cache hit must not.
        XCTAssertEqual(keyReads, 1)
    }

    func testCacheSeparatesProviderModelParametersLanguageAndSource() async throws {
        let fixture = try makeFixture()
        var route = makeRoute()
        var requests = 0
        let service = PaperSummaryService(resolveRoute: { _, _ in route }, loadAPIKey: { _ in "test-key" }, complete: { _ in
            requests += 1
            return LLMCompletionResponse(text: "Summary \(requests).", resolvedEndpoint: nil)
        })

        _ = try await service.content(for: fixture.paper, settings: fixture.settings, modelContext: fixture.context)
        route.providerProfileID = UUID()
        _ = try await service.content(for: fixture.paper, settings: fixture.settings, modelContext: fixture.context)
        route.modelProfileID = UUID()
        _ = try await service.content(for: fixture.paper, settings: fixture.settings, modelContext: fixture.context)
        route.temperature = 0.8
        _ = try await service.content(for: fixture.paper, settings: fixture.settings, modelContext: fixture.context)
        fixture.settings.targetLanguage = "EN"
        _ = try await service.content(for: fixture.paper, settings: fixture.settings, modelContext: fixture.context)
        fixture.paper.abstractText = "A revised abstract."
        _ = try await service.content(for: fixture.paper, settings: fixture.settings, modelContext: fixture.context)

        XCTAssertEqual(requests, 6)
        XCTAssertEqual(try fixture.context.fetch(FetchDescriptor<TranslationSegment>()).count, 6)
    }

    func testRemovingConfigurationHidesCachedSummary() async throws {
        let fixture = try makeFixture()
        let route = makeRoute()
        var configured = true
        var requests = 0
        let service = PaperSummaryService(resolveRoute: { _, _ in
            guard configured else { throw LLMRouteError.htmlModelNotSelected }
            return route
        }, loadAPIKey: { _ in "test-key" }, complete: { _ in
            requests += 1
            return LLMCompletionResponse(text: "A short summary.", resolvedEndpoint: nil)
        })
        _ = try await service.content(for: fixture.paper, settings: fixture.settings, modelContext: fixture.context)
        configured = false

        let content = try await service.content(for: fixture.paper, settings: fixture.settings, modelContext: fixture.context)

        XCTAssertEqual(content, .hidden)
        XCTAssertEqual(requests, 1)
    }

    func testLocalAndWebPDFsSummarizeOnlyBoundedOpeningPages() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pdfURL = directory.appendingPathComponent("paper.pdf")
        try makePDF(pages: ["Research question.", "Method description.", "Main finding.", "FOURTH_PAGE_SENTINEL"])
            .write(to: pdfURL)
        let route = makeRoute()
        for source: AttachmentSource in [.localImport, .webPage] {
            let fixture = try makeFixture(source: source, abstract: "", pdfURL: pdfURL)
            let service = PaperSummaryService(resolveRoute: { _, _ in route }, loadAPIKey: { _ in "test-key" }, complete: { request in
                let content = request.messages[1].content
                XCTAssertTrue(content.contains("Research question."))
                XCTAssertTrue(content.contains("Main finding."))
                XCTAssertFalse(content.contains("FOURTH_PAGE_SENTINEL"))
                return LLMCompletionResponse(text: "论文探讨研究问题，介绍方法并报告主要发现。", resolvedEndpoint: nil)
            })

            let content = try await service.content(for: fixture.paper, settings: fixture.settings, modelContext: fixture.context)

            XCTAssertEqual(content, .summary("论文探讨研究问题，介绍方法并报告主要发现。"))
            XCTAssertTrue(fixture.paper.abstractText.isEmpty)
        }
    }

    func testMissingTextDoesNotGenerateInventedSummary() async throws {
        let fixture = try makeFixture(abstract: "")
        let route = makeRoute()
        let service = PaperSummaryService(resolveRoute: { _, _ in route }, loadAPIKey: { _ in "test-key" }, complete: { _ in
            XCTFail("There is no text to summarize")
            throw LLMProviderError.emptyResponse
        })

        let content = try await service.content(for: fixture.paper, settings: fixture.settings, modelContext: fixture.context)

        XCTAssertEqual(content, .hidden)
    }

    func testFailureLeavesOriginalMetadataAndCacheUntouched() async throws {
        let fixture = try makeFixture()
        let route = makeRoute()
        let service = PaperSummaryService(resolveRoute: { _, _ in route }, loadAPIKey: { _ in "test-key" }, complete: { _ in
            throw URLError(.timedOut)
        })

        do {
            _ = try await service.content(for: fixture.paper, settings: fixture.settings, modelContext: fixture.context)
            XCTFail("Expected the provider error")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
        XCTAssertEqual(fixture.paper.abstractText, "The original official abstract.")
        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<TranslationSegment>()).isEmpty)
    }

    func testLateResponseAfterDeletionDoesNotSaveOrphanedSummary() async throws {
        let fixture = try makeFixture()
        let route = makeRoute()
        let service = PaperSummaryService(resolveRoute: { _, _ in route }, loadAPIKey: { _ in "test-key" }, complete: { _ in
            fixture.context.delete(fixture.paper)
            try fixture.context.save()
            return LLMCompletionResponse(text: "Late response.", resolvedEndpoint: nil)
        })

        let content = try await service.content(for: fixture.paper, settings: fixture.settings, modelContext: fixture.context)

        XCTAssertEqual(content, .hidden)
        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<TranslationSegment>()).isEmpty)
    }

    func testCancelledSummaryDoesNotPopulateCache() async throws {
        let fixture = try makeFixture()
        let route = makeRoute()
        let service = PaperSummaryService(resolveRoute: { _, _ in route }, loadAPIKey: { _ in "test-key" }, complete: { _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return LLMCompletionResponse(text: "Cancelled response.", resolvedEndpoint: nil)
        })
        let task = Task {
            try await service.content(for: fixture.paper, settings: fixture.settings, modelContext: fixture.context)
        }
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<TranslationSegment>()).isEmpty)
    }

    func testEmptyResponseKeepsSummaryHidden() async throws {
        let fixture = try makeFixture()
        let route = makeRoute()
        let service = PaperSummaryService(resolveRoute: { _, _ in route }, loadAPIKey: { _ in "test-key" }, complete: { _ in
            LLMCompletionResponse(text: " \n  ", resolvedEndpoint: nil)
        })

        let content = try await service.content(for: fixture.paper, settings: fixture.settings, modelContext: fixture.context)

        XCTAssertEqual(content, .hidden)
        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<TranslationSegment>()).isEmpty)
    }

    func testHTMLOnlyPaperKeepsItsOriginalAbstractWithoutLLM() async throws {
        let fixture = try makeFixture(kind: .html)
        let content = try await PaperSummaryService().content(
            for: fixture.paper, settings: fixture.settings, modelContext: fixture.context
        )
        XCTAssertEqual(content, .original(fixture.paper.abstractText))
    }

    private func makeFixture(
        source: AttachmentSource = .localImport,
        kind: AttachmentKind = .pdf,
        abstract: String = "The original official abstract.",
        pdfURL: URL = URL(fileURLWithPath: "/nonexistent/paper.pdf")
    ) throws -> (container: ModelContainer, context: ModelContext, paper: Paper, settings: AppSettings) {
        let schema = Schema([Paper.self, PaperAttachment.self, TranslationSegment.self, AppSettings.self,
                             LLMProviderProfile.self, LLMModelProfile.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let paper = Paper(title: "Test paper", abstractText: abstract)
        let settings = AppSettings()
        context.insert(paper)
        context.insert(settings)
        context.insert(PaperAttachment(paperID: paper.id, kind: kind, source: source,
                                       filename: "paper.pdf", filePath: pdfURL.path))
        try context.save()
        return (container, context, paper, settings)
    }

    private func makeRoute() -> LLMModelRouteSnapshot {
        LLMModelRouteSnapshot(
            providerProfileID: UUID(), providerName: "Test provider", modelProfileID: UUID(),
            modelProfileName: "Test model", baseURL: "https://example.com/v1", apiKeyRef: "test-ref", modelName: "test-model"
        )
    }

    private func makePDF(pages: [String]) throws -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 400, height: 200)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        for page in pages {
            context.beginPDFPage(nil)
            context.textPosition = CGPoint(x: 20, y: 120)
            let text = NSAttributedString(string: page, attributes: [.font: NSFont.systemFont(ofSize: 14)])
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }
}
