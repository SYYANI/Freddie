import Foundation
import BabelDocKit
import LaTeXTransKit
import XCTest
@testable import ReadPaper

final class BabelDocSemanticHintServiceTests: XCTestCase {
    func testDisabledPreferenceSkipsSourceAcquisition() async throws {
        XCTAssertTrue(BabelDocSemanticHintPreference.defaultValue)
        let temporary = try SemanticTemporaryDirectory()
        defer { temporary.remove() }
        let source = try makeProject(in: temporary.url)
        let acquirer = CountingSemanticAcquirer(source: .localDirectory(source))
        let service = BabelDocSemanticHintService(
            fileStore: PaperFileStore(
                applicationSupportDirectory: temporary.url.appendingPathComponent("support")
            ),
            acquirer: acquirer
        )

        let artifact = try await service.prepareIfAvailable(
            isEnabled: false,
            paperID: UUID(),
            arxivIdentifier: "2401.00001v2"
        )
        let acquisitionCount = await acquirer.acquisitionCount()

        XCTAssertNil(artifact)
        XCTAssertEqual(acquisitionCount, 0)
    }

    func testBuildsCompilerFreeSidecarAndReusesExactVersionCache() async throws {
        let temporary = try SemanticTemporaryDirectory()
        defer { temporary.remove() }
        let source = try makeProject(in: temporary.url)
        let acquirer = CountingSemanticAcquirer(source: .localDirectory(source))
        let service = BabelDocSemanticHintService(
            fileStore: PaperFileStore(
                applicationSupportDirectory: temporary.url.appendingPathComponent("support")
            ),
            acquirer: acquirer
        )
        let paperID = UUID()

        let first = try await service.prepare(
            paperID: paperID, arxivIdentifier: "2401.00001v2"
        )
        let second = try await service.prepare(
            paperID: paperID, arxivIdentifier: "2401.00001v2"
        )
        let acquisitionCount = await acquirer.acquisitionCount()

        XCTAssertFalse(first.wasCached)
        XCTAssertTrue(second.wasCached)
        XCTAssertEqual(first.document.sourceIdentifier, "2401.00001v2")
        XCTAssertEqual(first.document.schemaVersion, BabelDocSemanticHintService.cacheSchemaVersion)
        XCTAssertEqual(first.document, second.document)
        XCTAssertEqual(acquisitionCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.fileURL.path))
        XCTAssertTrue(first.document.blocks.contains {
            $0.kind == BabelDocSemanticBlockKind.documentTitle
        })
        XCTAssertTrue(first.document.blocks.contains {
            $0.kind == BabelDocSemanticBlockKind.sectionHeading
        })
        XCTAssertTrue(first.document.blocks.contains { block in
            block.atoms.contains { $0.kind == BabelDocSemanticAtomKind.citation }
        })
    }

    func testExactArXivVersionUsesIndependentCacheIdentity() async throws {
        let temporary = try SemanticTemporaryDirectory()
        defer { temporary.remove() }
        let source = try makeProject(in: temporary.url)
        let acquirer = CountingSemanticAcquirer(source: .localDirectory(source))
        let service = BabelDocSemanticHintService(
            fileStore: PaperFileStore(
                applicationSupportDirectory: temporary.url.appendingPathComponent("support")
            ),
            acquirer: acquirer
        )
        let paperID = UUID()

        let v2 = try await service.prepare(paperID: paperID, arxivIdentifier: "2401.00001v2")
        let v3 = try await service.prepare(paperID: paperID, arxivIdentifier: "2401.00001v3")
        let acquisitionCount = await acquirer.acquisitionCount()

        XCTAssertNotEqual(v2.fileURL, v3.fileURL)
        XCTAssertEqual(v2.document.sourceIdentifier, "2401.00001v2")
        XCTAssertEqual(v3.document.sourceIdentifier, "2401.00001v3")
        XCTAssertEqual(acquisitionCount, 2)
    }

    func testCorruptedSemanticCacheIsRebuiltInsteadOfSurfacingAReadFailure() async throws {
        let temporary = try SemanticTemporaryDirectory()
        defer { temporary.remove() }
        let source = try makeProject(in: temporary.url)
        let acquirer = CountingSemanticAcquirer(source: .localDirectory(source))
        let service = BabelDocSemanticHintService(
            fileStore: PaperFileStore(
                applicationSupportDirectory: temporary.url.appendingPathComponent("support")
            ),
            acquirer: acquirer
        )
        let paperID = UUID()

        let initial = try await service.prepare(
            paperID: paperID,
            arxivIdentifier: "2401.00001v2"
        )
        try Data("{corrupted-cache".utf8).write(to: initial.fileURL, options: .atomic)
        let rebuilt = try await service.prepare(
            paperID: paperID,
            arxivIdentifier: "2401.00001v2"
        )
        let acquisitionCount = await acquirer.acquisitionCount()

        XCTAssertFalse(rebuilt.wasCached)
        XCTAssertEqual(rebuilt.document, initial.document)
        XCTAssertEqual(acquisitionCount, 2)
    }

    func testUnavailableSourceFallsBackWithoutFailingPDFTranslationPreparation() async throws {
        let temporary = try SemanticTemporaryDirectory()
        defer { temporary.remove() }
        let statuses = SemanticStatusRecorder()
        let service = BabelDocSemanticHintService(
            fileStore: PaperFileStore(
                applicationSupportDirectory: temporary.url.appendingPathComponent("support")
            ),
            acquirer: FailingSemanticAcquirer()
        )

        let artifact = try await service.prepareIfAvailable(
            paperID: UUID(), arxivIdentifier: "2401.00001v1"
        ) { status in
            statuses.append(status)
        }
        let recordedStatuses = statuses.values()

        XCTAssertNil(artifact)
        XCTAssertTrue(recordedStatuses.contains(.unavailable))
    }

    func testConcurrentPreparationCoalescesSourceAcquisition() async throws {
        let temporary = try SemanticTemporaryDirectory()
        defer { temporary.remove() }
        let source = try makeProject(in: temporary.url)
        let acquirer = CountingSemanticAcquirer(
            source: .localDirectory(source),
            delay: .milliseconds(100)
        )
        let service = BabelDocSemanticHintService(
            fileStore: PaperFileStore(
                applicationSupportDirectory: temporary.url.appendingPathComponent("support")
            ),
            acquirer: acquirer
        )
        let paperID = UUID()

        async let first = service.prepare(
            paperID: paperID,
            arxivIdentifier: "2401.00001v2"
        )
        async let second = service.prepare(
            paperID: paperID,
            arxivIdentifier: "2401.00001v2"
        )
        let artifacts = try await (first, second)
        let acquisitionCount = await acquirer.acquisitionCount()

        XCTAssertEqual(acquisitionCount, 1)
        XCTAssertEqual(artifacts.0.document, artifacts.1.document)
        XCTAssertEqual(BabelDocSemanticHintService.extractorAlgorithmVersion, 2)
    }

    func testFixedVersionPaperCorpusPreservesExpectedSemanticsAndPlaceholders() throws {
        let startedAt = Date()
        var expectedKindCount = 0
        var recoveredKindCount = 0
        var expectedAtomCount = 0
        var recoveredAtomCount = 0

        for fixture in Self.semanticCorpus {
            let parsed = ParsedLaTeXProject(
                mainFile: URL(fileURLWithPath: "/fixtures/\(fixture.arxivID)/main.tex"),
                units: [],
                sections: [.init(identifier: "1", content: fixture.source)]
            )
            let sourceDocument = try StructuredLaTeXSemanticExtractor().extract(
                from: parsed,
                sourceIdentifier: fixture.arxivID
            )
            let data = try JSONEncoder().encode(sourceDocument)
            let bridgeDocument = try JSONDecoder().decode(
                BabelDocSemanticDocument.self,
                from: data
            )
            try bridgeDocument.validate()

            let kinds = Set(sourceDocument.blocks.map(\.kind))
            let atoms = Set(sourceDocument.blocks.flatMap(\.atoms).map(\.kind))
            expectedKindCount += fixture.requiredKinds.count
            recoveredKindCount += fixture.requiredKinds.intersection(kinds).count
            expectedAtomCount += fixture.requiredAtoms.count
            recoveredAtomCount += fixture.requiredAtoms.intersection(atoms).count

            XCTAssertTrue(fixture.requiredKinds.isSubset(of: kinds), fixture.arxivID)
            XCTAssertTrue(fixture.requiredAtoms.isSubset(of: atoms), fixture.arxivID)
            XCTAssertTrue(sourceDocument.blocks.allSatisfy {
                !$0.alignmentText.isEmpty && !$0.translationTemplate.isEmpty
            }, fixture.arxivID)
            for block in sourceDocument.blocks {
                for atom in block.atoms {
                    XCTAssertEqual(
                        block.translationTemplate.components(separatedBy: atom.token).count,
                        2,
                        "\(fixture.arxivID): \(atom.id)"
                    )
                }
            }
        }

        XCTAssertEqual(recoveredKindCount, expectedKindCount)
        XCTAssertEqual(recoveredAtomCount, expectedAtomCount)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2)
    }

    func testParserSupportsSubfileImportNestedEnvironmentsAndLegacyEncoding() async throws {
        let temporary = try SemanticTemporaryDirectory()
        defer { temporary.remove() }
        let project = temporary.url.appendingPathComponent("parser", isDirectory: true)
        let chapters = project.appendingPathComponent("chapters", isDirectory: true)
        let sections = project.appendingPathComponent("sections", isDirectory: true)
        try FileManager.default.createDirectory(at: chapters, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sections, withIntermediateDirectories: true)
        try Data(#"\documentclass{article}\begin{document}\subfile{chapters/a}\import{sections}{b}\end{document}"#.utf8)
            .write(to: project.appendingPathComponent("main.tex"))
        try Data(#"\begin{itemize}\item outer\begin{itemize}\item inner\end{itemize}\item tail\end{itemize}"#.utf8)
            .write(to: chapters.appendingPathComponent("a.tex"))
        let latin1 = try XCTUnwrap("Legacy café paragraph.".data(using: .isoLatin1))
        try latin1.write(to: sections.appendingPathComponent("b.tex"))

        let parsed = try await StructuredLaTeXParser(minimumSectionTokenCount: 0).parse(.init(
            identifier: "parser",
            sourceDirectory: project,
            workspaceDirectory: project
        ))

        XCTAssertEqual(parsed.inputs.count, 2)
        XCTAssertTrue(parsed.inputs.contains { $0.path == "chapters/a" })
        XCTAssertTrue(parsed.inputs.contains { $0.path == "sections/b" })
        XCTAssertTrue(parsed.environments.contains {
            $0.name == "itemize" && $0.content.contains("inner") && $0.content.contains("tail")
        })
        XCTAssertTrue(parsed.sections.map(\.content).joined().contains("café"))
    }

    func testSafeMacroExpansionAndTableCommandVisibleArguments() throws {
        let parsed = ParsedLaTeXProject(
            mainFile: URL(fileURLWithPath: "/fixture/main.tex"),
            units: [],
            newCommands: [.init(
                placeholder: "<PLACEHOLDER_NEWCOMMAND_0>",
                name: "paperterm",
                content: #"\newcommand{\paperterm}[1]{robust #1}"#
            )],
            sections: [.init(
                identifier: "1",
                content: #"\section{Method} We propose a \paperterm{estimator}. The result is \multicolumn{2}{c}{state of the art}."#
            )]
        )

        let document = try StructuredLaTeXSemanticExtractor().extract(
            from: parsed,
            sourceIdentifier: "fixture"
        )
        let body = try XCTUnwrap(document.blocks.first { $0.kind == .paragraph })
        XCTAssertTrue(body.alignmentText.contains("robust estimator"))
        XCTAssertTrue(body.alignmentText.contains("state of the art"))
        XCTAssertFalse(body.alignmentText.contains("2cstate"))
    }

    func testParserAndExtractorRejectOversizedInputWithTypedErrors() async throws {
        let temporary = try SemanticTemporaryDirectory()
        defer { temporary.remove() }
        let project = temporary.url.appendingPathComponent("limits", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data(#"\documentclass{article}\begin{document}source text\end{document}"#.utf8)
            .write(to: project.appendingPathComponent("main.tex"))

        do {
            _ = try await StructuredLaTeXParser(
                limits: .init(maximumSourceCharacters: 10)
            ).parse(.init(
                identifier: "limits",
                sourceDirectory: project,
                workspaceDirectory: project
            ))
            XCTFail("Expected parser source limit failure.")
        } catch let error as LaTeXParserError {
            XCTAssertEqual(error, .sourceCharacterLimitExceeded(limit: 10))
        }

        let parsed = ParsedLaTeXProject(
            mainFile: project.appendingPathComponent("main.tex"),
            units: [],
            sections: [.init(identifier: "1", content: String(repeating: "x", count: 20))]
        )
        XCTAssertThrowsError(try StructuredLaTeXSemanticExtractor(
            configuration: .init(maximumSourceCharacters: 10)
        ).extract(from: parsed, sourceIdentifier: "limits")) { error in
            XCTAssertEqual(error as? LaTeXSemanticExtractorError, .sourceCharacterLimitExceeded(10))
        }
    }

    private struct SemanticCorpusCase {
        let arxivID: String
        let source: String
        let requiredKinds: Set<LaTeXSemanticBlockKind>
        let requiredAtoms: Set<LaTeXSemanticAtomKind>
    }

    private static let semanticCorpus: [SemanticCorpusCase] = [
        .init(arxivID: "1706.03762v7", source: #"\section{Attention Is All You Need} We use attention $A(Q,K,V)$ and compare prior work \cite{vaswani2017}."#, requiredKinds: [.sectionHeading, .paragraph], requiredAtoms: [.math, .citation]),
        .init(arxivID: "1810.04805v2", source: #"\section{BERT} Bidirectional pre-training uses a masked objective \eqref{eq:mlm} and \texttt{[MASK]}."#, requiredKinds: [.sectionHeading, .paragraph], requiredAtoms: [.reference, .code]),
        .init(arxivID: "2005.14165v4", source: #"\section{Few-Shot Learning} Performance is conditioned on examples $x_1,\ldots,x_k$ without gradient updates."#, requiredKinds: [.sectionHeading, .paragraph], requiredAtoms: [.math]),
        .init(arxivID: "2103.00020v1", source: #"\section{Natural Language Supervision} Image and text representations use a contrastive loss $\mathcal{L}$."#, requiredKinds: [.sectionHeading, .paragraph], requiredAtoms: [.math]),
        .init(arxivID: "2010.11929v2", source: #"\section{Vision Transformer} An image is split into $16\times16$ patches and processed as a token sequence."#, requiredKinds: [.sectionHeading, .paragraph], requiredAtoms: [.math]),
        .init(arxivID: "1512.03385v1", source: #"\section{Residual Learning} A residual block learns $F(x)+x$ and eases optimization of deep networks."#, requiredKinds: [.sectionHeading, .paragraph], requiredAtoms: [.math]),
        .init(arxivID: "1412.6980v9", source: #"\section{Adam} The optimizer maintains moments $m_t$ and $v_t$ with adaptive updates."#, requiredKinds: [.sectionHeading, .paragraph], requiredAtoms: [.math]),
        .init(arxivID: "1312.6114v10", source: #"\section{Variational Bayes} We optimize the lower bound $\mathcal{L}(\theta,\phi)$ using reparameterization."#, requiredKinds: [.sectionHeading, .paragraph], requiredAtoms: [.math]),
        .init(arxivID: "1409.1556v6", source: #"\section{Very Deep Networks} Small $3\times3$ filters increase depth while retaining receptive fields."#, requiredKinds: [.sectionHeading, .paragraph], requiredAtoms: [.math]),
        .init(arxivID: "2303.08774v6", source: #"\section{GPT-4 Technical Report} Evaluation results are reported at \url{https://arxiv.org/abs/2303.08774} and compared with \cite{openai2023}."#, requiredKinds: [.sectionHeading, .paragraph], requiredAtoms: [.url, .citation]),
    ]

    private func makeProject(in root: URL) throws -> URL {
        let source = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data(#"""
        \documentclass{article}
        \begin{document}
        \title{Compiler-Free Semantics}
        \section{Method}
        Prior work \cite{smith2024} defines $x$ and this complete paragraph contains enough text for deterministic semantic extraction.
        \end{document}
        """#.utf8).write(to: source.appendingPathComponent("main.tex"))
        return source
    }
}

private actor CountingSemanticAcquirer: ArXivProjectAcquiring {
    let source: TranslationProjectSource
    let delay: Duration?
    private var count = 0

    init(source: TranslationProjectSource, delay: Duration? = nil) {
        self.source = source
        self.delay = delay
    }

    func acquireProject(
        identifier: String,
        workspaceDirectory: URL
    ) async throws -> TranslationProjectSource {
        count += 1
        if let delay { try await Task.sleep(for: delay) }
        return source
    }

    func acquisitionCount() -> Int { count }
}

private struct FailingSemanticAcquirer: ArXivProjectAcquiring {
    enum Failure: Error { case expected }

    func acquireProject(
        identifier: String,
        workspaceDirectory: URL
    ) async throws -> TranslationProjectSource {
        throw Failure.expected
    }
}

private final class SemanticStatusRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [BabelDocSemanticHintStatus] = []
    func append(_ status: BabelDocSemanticHintStatus) { lock.withLock { stored.append(status) } }
    func values() -> [BabelDocSemanticHintStatus] { lock.withLock { stored } }
}

private struct SemanticTemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BabelDocSemanticHintTests-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
