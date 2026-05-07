import Foundation
import XCTest
import SwiftData
@testable import ReadPaper

@MainActor
final class AuthorExtractionServiceTests: XCTestCase {
    private var modelContainer: ModelContainer!
    private var modelContext: ModelContext!

    override func setUp() async throws {
        let schema = Schema([
            Paper.self,
            PaperAttachment.self,
            TranslationSegment.self,
            AppSettings.self,
            LLMProviderProfile.self,
            LLMModelProfile.self,
            Note.self
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        modelContainer = try ModelContainer(for: schema, configurations: config)
        modelContext = ModelContext(modelContainer)
    }

    override func tearDown() async throws {
        modelContext = nil
        modelContainer = nil
    }

    // MARK: - parseAuthors

    func testParseAuthorsOnePerLine() {
        let input = "John Smith\nJane Doe\nBob Wilson"
        let result = AuthorExtractionService.parseAuthors(from: input)
        XCTAssertEqual(result, ["John Smith", "Jane Doe", "Bob Wilson"])
    }

    func testParseAuthorsTrimsWhitespace() {
        let input = "  John Smith  \n\n  Jane Doe  \n"
        let result = AuthorExtractionService.parseAuthors(from: input)
        XCTAssertEqual(result, ["John Smith", "Jane Doe"])
    }

    func testParseAuthorsEmptyString() {
        let result = AuthorExtractionService.parseAuthors(from: "")
        XCTAssertEqual(result, [])
    }

    func testParseAuthorsFiltersNoisePrefixes() {
        let input = "Authors:\nJohn Smith\nTitle: Test\nJane Doe"
        let result = AuthorExtractionService.parseAuthors(from: input)
        XCTAssertEqual(result, ["John Smith", "Jane Doe"])
    }

    func testParseAuthorsFiltersNA() {
        let input = "John Smith\nN/A\nJane Doe\nNone\nunknown"
        let result = AuthorExtractionService.parseAuthors(from: input)
        XCTAssertEqual(result, ["John Smith", "Jane Doe"])
    }

    func testParseAuthorsSingleAuthor() {
        let result = AuthorExtractionService.parseAuthors(from: "Albert Einstein")
        XCTAssertEqual(result, ["Albert Einstein"])
    }

    func testParseAuthorsStripsByPrefixWithAffiliation() {
        let input = "By Ryan Lopopolo, Member of the Technical Staff"
        let result = AuthorExtractionService.parseAuthors(from: input)
        XCTAssertEqual(result, ["Ryan Lopopolo"])
    }

    func testParseAuthorsStripsByPrefixWithCommaAffiliation() {
        let input = "By John Smith, University of Science"
        let result = AuthorExtractionService.parseAuthors(from: input)
        XCTAssertEqual(result, ["John Smith"])
    }

    func testParseAuthorsStripsLowercaseByPrefix() {
        let input = "by Jane Doe, PhD"
        let result = AuthorExtractionService.parseAuthors(from: input)
        XCTAssertEqual(result, ["Jane Doe"])
    }

    func testParseAuthorsHandlesAndSeparator() {
        let input = "By John Smith and Jane Doe"
        let result = AuthorExtractionService.parseAuthors(from: input)
        XCTAssertEqual(result, ["John Smith", "Jane Doe"])
    }

    func testParseAuthorsHandlesCommaAndSeparator() {
        let input = "John Smith, and Jane Doe"
        let result = AuthorExtractionService.parseAuthors(from: input)
        XCTAssertEqual(result, ["John Smith", "Jane Doe"])
    }

    func testParseAuthorsHandlesAmpersand() {
        let input = "John Smith & Jane Doe"
        let result = AuthorExtractionService.parseAuthors(from: input)
        XCTAssertEqual(result, ["John Smith", "Jane Doe"])
    }

    func testParseAuthorsPreservesKnownOrganizationWithAmpersand() {
        let result = AuthorExtractionService.parseAuthors(from: "Taylor & Francis")
        XCTAssertEqual(result, ["Taylor & Francis"])
    }

    func testParseAuthorsStripsByAndAffiliationMultiline() {
        let input = "By Ryan Lopopolo, Member of the Technical Staff\nJohn Smith, University of Science"
        let result = AuthorExtractionService.parseAuthors(from: input)
        XCTAssertEqual(result, ["Ryan Lopopolo", "John Smith"])
    }

    // MARK: - buildUserContent

    func testBuildUserContentTitleOnly() {
        let result = AuthorExtractionService.buildUserContent(
            title: "Test Title",
            abstract: "",
            htmlURLString: nil
        )
        XCTAssertEqual(result, "Title: Test Title")
    }

    func testBuildUserContentWithAbstract() {
        let abstract = String(repeating: "a", count: 500)
        let result = AuthorExtractionService.buildUserContent(
            title: "Test Title",
            abstract: abstract,
            htmlURLString: nil
        )
        XCTAssertTrue(result.contains("Title: Test Title"))
        XCTAssertTrue(result.contains("Abstract (first 200 chars):"))
        let abstractLine = result.components(separatedBy: "\n").first { $0.hasPrefix("Abstract") }!
        let prefix = abstractLine.replacingOccurrences(of: "Abstract (first 200 chars): ", with: "")
        XCTAssertEqual(prefix.count, 200)
        XCTAssertFalse(result.contains("Source URL:"))
    }

    func testBuildUserContentWithURL() {
        let result = AuthorExtractionService.buildUserContent(
            title: "Test Title",
            abstract: "",
            htmlURLString: "https://arxiv.org/html/2303.08774"
        )
        XCTAssertTrue(result.contains("Title: Test Title"))
        XCTAssertTrue(result.contains("Source URL: https://arxiv.org/html/2303.08774"))
    }

    func testBuildUserContentAllFields() {
        let result = AuthorExtractionService.buildUserContent(
            title: "A Novel Approach",
            abstract: "This paper presents a novel approach.",
            htmlURLString: "https://example.com/paper"
        )
        XCTAssertTrue(result.contains("Title: A Novel Approach"))
        XCTAssertTrue(result.contains("Abstract (first 200 chars): This paper presents a novel approach."))
        XCTAssertTrue(result.contains("Source URL: https://example.com/paper"))
    }

    func testBuildUserContentEmptyURLString() {
        let result = AuthorExtractionService.buildUserContent(
            title: "Test",
            abstract: "",
            htmlURLString: ""
        )
        XCTAssertEqual(result, "Title: Test")
        XCTAssertFalse(result.contains("Source URL:"))
    }

    func testBuildUserContentIncludesLocalHTMLEvidence() {
        let result = AuthorExtractionService.buildUserContent(
            title: "Harness engineering: leveraging Codex in an agent-first world",
            abstract: "",
            htmlURLString: "https://openai.com/index/harness-engineering/",
            localHTMLContext: AuthorExtractionService.LocalHTMLContext(
                metaAuthors: [],
                bylines: ["By Ryan Lopopolo, Member of the Technical Staff"],
                textSnippet: "Harness engineering: leveraging Codex in an agent-first world By Ryan Lopopolo"
            )
        )

        XCTAssertTrue(result.contains("Local HTML byline candidates:\nBy Ryan Lopopolo, Member of the Technical Staff"))
        XCTAssertTrue(result.contains("Local HTML visible text excerpt:\nHarness engineering"))
        XCTAssertTrue(result.contains("Source URL: https://openai.com/index/harness-engineering/"))
        XCTAssertTrue(result.contains("Source organization inferred from URL: OpenAI"))
    }

    // MARK: - local HTML context

    func testExtractLocalHTMLContextFindsReadabilityBylineAndMetadata() throws {
        let html = """
        <html>
          <head>
            <meta name="author" content="Ryan Lopopolo">
          </head>
          <body class="rp-readability-body">
            <main class="rp-readability-shell">
              <h1 class="rp-readability-title">Harness engineering</h1>
              <p class="rp-readability-byline">By Ryan Lopopolo, Member of the Technical Staff</p>
              <article>Codex can help teams ship agent-first engineering workflows.</article>
            </main>
          </body>
        </html>
        """

        let context = try AuthorExtractionService.extractLocalHTMLContext(
            from: html,
            maxTextSnippetLength: 120
        )

        XCTAssertEqual(context.metaAuthors, ["Ryan Lopopolo"])
        XCTAssertEqual(context.bylines, ["By Ryan Lopopolo, Member of the Technical Staff"])
        XCTAssertTrue(context.textSnippet?.contains("Harness engineering") == true)
    }

    func testExtractAndAssignUsesLocalHTMLBylineWithoutLLMRoute() async throws {
        let paper = Paper(
            title: "Harness engineering: leveraging Codex in an agent-first world",
            authors: [],
            htmlURLString: "https://openai.com/index/harness-engineering/"
        )
        modelContext.insert(paper)

        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let htmlURL = directoryURL.appendingPathComponent("paper.html")
        try """
        <html>
          <body>
            <p class="rp-readability-byline">By Ryan Lopopolo, Member of the Technical Staff</p>
            <article>Harness engineering: leveraging Codex in an agent-first world</article>
          </body>
        </html>
        """.write(to: htmlURL, atomically: true, encoding: .utf8)

        modelContext.insert(PaperAttachment(
            paperID: paper.id,
            kind: .html,
            source: .webPage,
            filename: "paper.html",
            filePath: htmlURL.path
        ))
        try modelContext.save()

        let didExtract = try await AuthorExtractionService().extractAndAssign(
            paperID: paper.id,
            title: paper.title,
            abstract: paper.abstractText,
            htmlURLString: paper.htmlURLString,
            modelContext: modelContext
        )

        XCTAssertTrue(didExtract)
        XCTAssertEqual(paper.authors, ["Ryan Lopopolo"])
    }

    // MARK: - source organization fallback

    func testInferSourceOrganizationUsesKnownDomainName() {
        let organization = AuthorExtractionService.inferSourceOrganization(
            from: "https://openai.com/index/harness-engineering/"
        )

        XCTAssertEqual(organization, "OpenAI")
    }

    func testInferSourceOrganizationFormatsRegistrableDomain() {
        let organization = AuthorExtractionService.inferSourceOrganization(
            from: "https://research.example-lab.org/papers/test"
        )

        XCTAssertEqual(organization, "Example Lab")
    }

    func testInferSourceOrganizationHandlesMultiPartSuffix() {
        let organization = AuthorExtractionService.inferSourceOrganization(
            from: "https://www.example-lab.ac.uk/research/test"
        )

        XCTAssertEqual(organization, "Example Lab")
    }

    func testInferSourceOrganizationReturnsNilForInvalidURL() {
        XCTAssertNil(AuthorExtractionService.inferSourceOrganization(from: "not a url"))
        XCTAssertNil(AuthorExtractionService.inferSourceOrganization(from: nil))
    }

    func testExtractAndAssignFallsBackToSourceOrganizationWithoutLLMRoute() async throws {
        let paper = Paper(
            title: "Harness engineering: leveraging Codex in an agent-first world",
            authors: [],
            htmlURLString: "https://openai.com/index/harness-engineering/"
        )
        modelContext.insert(paper)
        try modelContext.save()

        let didExtract = try await AuthorExtractionService().extractAndAssign(
            paperID: paper.id,
            title: paper.title,
            abstract: paper.abstractText,
            htmlURLString: paper.htmlURLString,
            modelContext: modelContext
        )

        XCTAssertTrue(didExtract)
        XCTAssertEqual(paper.authors, ["OpenAI"])
    }

    // MARK: - extractAuthorsIfNeeded guard conditions

    func testSkipsWhenAuthorsNotEmpty() {
        let paper = Paper(title: "Test", authors: ["Existing Author"])
        modelContext.insert(paper)

        AuthorExtractionService.extractAuthorsIfNeeded(for: paper, modelContext: modelContext)
        // Should not crash or update — guard catches non-empty authors
        XCTAssertEqual(paper.authors, ["Existing Author"])
    }

    func testSkipsWhenTitleEmpty() {
        let paper = Paper(title: "", authors: [])
        modelContext.insert(paper)

        AuthorExtractionService.extractAuthorsIfNeeded(for: paper, modelContext: modelContext)
        // Should not crash — guard catches empty title
        XCTAssertTrue(paper.authors.isEmpty)
    }

    func testTriggersWhenAuthorsEmptyAndTitlePresent() {
        let paper = Paper(title: "A Novel Approach to AI", authors: [])
        modelContext.insert(paper)

        // Even though the LLM call will fail (no route configured),
        // the guard should pass and not crash.
        AuthorExtractionService.extractAuthorsIfNeeded(for: paper, modelContext: modelContext)
        // The Task fires asynchronously; we just verify no immediate crash.
        XCTAssertTrue(paper.authors.isEmpty)
    }
}
