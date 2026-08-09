import BabelDocKit
import Foundation
import LaTeXTransKit

struct BabelDocSemanticHintArtifact: Sendable {
    let document: BabelDocSemanticDocument
    let fileURL: URL
    let wasCached: Bool
}

enum BabelDocSemanticHintPreference {
    static let userDefaultsKey = "ReadPaper.Settings.BabelDocSemanticHintsEnabled"
    static let defaultValue = true
}

enum BabelDocSemanticHintStatus: Sendable, Equatable {
    case checkingCache
    case downloadingSource
    case parsingSource
    case ready(cached: Bool)
    case unavailable

    var localizedMessage: String {
        switch self {
        case .checkingCache:
            AppLocalization.localized("Checking cached arXiv structure...")
        case .downloadingSource:
            AppLocalization.localized("Downloading arXiv LaTeX source...")
        case .parsingSource:
            AppLocalization.localized("Extracting LaTeX structure for PDF translation...")
        case .ready(let cached):
            cached
                ? AppLocalization.localized("Using cached LaTeX structure to improve PDF translation.")
                : AppLocalization.localized("LaTeX structure is ready for PDF translation.")
        case .unavailable:
            AppLocalization.localized("LaTeX source is unavailable; continuing with PDF layout analysis.")
        }
    }
}

/// Builds the cross-platform, compiler-free LaTeX semantic sidecar consumed by BabelDOC.
/// The JSON contract is deliberately decoded through BabelDocKit before it is cached,
/// so macOS helper and iPad in-process translation receive the exact same validated data.
actor BabelDocSemanticHintService {
    typealias StatusHandler = @Sendable (BabelDocSemanticHintStatus) -> Void

    static let cacheSchemaVersion = 1

    private let fileStore: PaperFileStore
    private let acquirer: any ArXivProjectAcquiring
    private let archiveReader: any TranslationArchiveReading

    init(
        fileStore: PaperFileStore = PaperFileStore(),
        acquirer: any ArXivProjectAcquiring = ReadPaperArXivProjectAcquirer(),
        archiveReader: any TranslationArchiveReading = AutomaticTranslationArchiveReader()
    ) {
        self.fileStore = fileStore
        self.acquirer = acquirer
        self.archiveReader = archiveReader
    }

    func prepareIfAvailable(
        isEnabled: Bool = BabelDocSemanticHintPreference.defaultValue,
        paperID: UUID,
        arxivIdentifier: String?,
        onStatus: @escaping StatusHandler = { _ in }
    ) async throws -> BabelDocSemanticHintArtifact? {
        guard isEnabled else { return nil }
        guard let identifier = arxivIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !identifier.isEmpty else { return nil }
        do {
            return try await prepare(
                paperID: paperID,
                arxivIdentifier: identifier,
                onStatus: onStatus
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            onStatus(.unavailable)
            return nil
        }
    }

    func prepare(
        paperID: UUID,
        arxivIdentifier: String,
        onStatus: @escaping StatusHandler = { _ in }
    ) async throws -> BabelDocSemanticHintArtifact {
        let normalized = try ArxivClient.normalizeIdentifier(arxivIdentifier)
        let exactIdentifier = normalized.queryID
        let root = try fileStore.latexSemanticDirectory(for: paperID)
        let cacheKey = String(Hashing.sha256Hex(
            "schema=\(Self.cacheSchemaVersion)|source=\(exactIdentifier)"
        ).prefix(24))
        let semanticURL = root.appendingPathComponent("semantic-\(cacheKey).json")
        let metadataURL = root.appendingPathComponent("semantic-\(cacheKey).metadata.json")

        onStatus(.checkingCache)
        if let cached = try? loadValidatedCache(
            semanticURL: semanticURL,
            metadataURL: metadataURL,
            expectedIdentifier: exactIdentifier
        ) {
            onStatus(.ready(cached: true))
            return .init(document: cached, fileURL: semanticURL, wasCached: true)
        }

        onStatus(.downloadingSource)
        let workspace = root
            .appendingPathComponent("workspaces", isDirectory: true)
            .appendingPathComponent(cacheKey, isDirectory: true)
        try fileStore.ensureDirectory(workspace)
        let acquiredSource = try await acquirer.acquireProject(
            identifier: exactIdentifier,
            workspaceDirectory: workspace
        )
        onStatus(.parsingSource)
        let preparer = RoutedProjectPreparer(
            localArchive: SecureArchiveProjectPreparer(reader: archiveReader)
        )
        let prepared = try await preparer.prepare(TranslationRequest(
            source: acquiredSource,
            workspaceDirectory: workspace,
            configuration: .init(compilationPolicy: .sourceOnly)
        ))
        let sourceDocument = try await LaTeXSemanticProjectAnalyzer().analyze(.init(
            identifier: exactIdentifier,
            sourceDirectory: prepared.sourceDirectory,
            workspaceDirectory: prepared.workspaceDirectory
        ))
        try Task.checkCancellation()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(sourceDocument)
        let document = try JSONDecoder().decode(BabelDocSemanticDocument.self, from: data)
        try document.validate()
        guard document.schemaVersion == Self.cacheSchemaVersion,
              document.sourceIdentifier == exactIdentifier else {
            throw BabelDocSemanticHintCacheError.invalidGeneratedDocument
        }
        try data.write(to: semanticURL, options: .atomic)
        let metadata = CacheMetadata(
            cacheSchemaVersion: Self.cacheSchemaVersion,
            sourceIdentifier: exactIdentifier,
            semanticSHA256: Hashing.sha256Hex(data)
        )
        try encoder.encode(metadata).write(to: metadataURL, options: .atomic)
        onStatus(.ready(cached: false))
        return .init(document: document, fileURL: semanticURL, wasCached: false)
    }

    private func loadValidatedCache(
        semanticURL: URL,
        metadataURL: URL,
        expectedIdentifier: String
    ) throws -> BabelDocSemanticDocument? {
        guard FileManager.default.fileExists(atPath: semanticURL.path),
              FileManager.default.fileExists(atPath: metadataURL.path) else { return nil }
        let metadata = try JSONDecoder().decode(
            CacheMetadata.self, from: Data(contentsOf: metadataURL)
        )
        let data = try Data(contentsOf: semanticURL)
        guard metadata.cacheSchemaVersion == Self.cacheSchemaVersion,
              metadata.sourceIdentifier == expectedIdentifier,
              metadata.semanticSHA256 == Hashing.sha256Hex(data) else { return nil }
        let document = try JSONDecoder().decode(BabelDocSemanticDocument.self, from: data)
        try document.validate()
        guard document.schemaVersion == Self.cacheSchemaVersion,
              document.sourceIdentifier == expectedIdentifier else { return nil }
        return document
    }

    private struct CacheMetadata: Codable {
        let cacheSchemaVersion: Int
        let sourceIdentifier: String
        let semanticSHA256: String
    }
}

enum BabelDocSemanticHintCacheError: Error {
    case invalidGeneratedDocument
}
