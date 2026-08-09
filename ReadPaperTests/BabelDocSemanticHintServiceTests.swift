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
    private var count = 0

    init(source: TranslationProjectSource) {
        self.source = source
    }

    func acquireProject(
        identifier: String,
        workspaceDirectory: URL
    ) async throws -> TranslationProjectSource {
        count += 1
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
