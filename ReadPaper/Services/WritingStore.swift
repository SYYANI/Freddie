import Foundation

/// What lists of writings need, cached in `meta.json` next to the Markdown.
struct WritingMetadata: Codable, Equatable, Identifiable, Sendable {
    static let currentVersion = 1

    var version: Int
    var id: UUID
    /// Plain text of the first line with text; empty for an empty writing.
    var title: String
    var createdAt: Date
    var modifiedAt: Date
    var citedPaperIDs: [UUID]
    var wordCount: Int
    /// The citations with their passages, for marking them in the reader. Nil in metadata
    /// written by a version without it, which is then rebuilt from the Markdown.
    var citations: [WritingCitationRecord]?

    init(
        id: UUID,
        title: String = "",
        createdAt: Date,
        modifiedAt: Date,
        citedPaperIDs: [UUID] = [],
        wordCount: Int = 0,
        citations: [WritingCitationRecord]? = [],
        version: Int = WritingMetadata.currentVersion
    ) {
        self.version = version
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.citedPaperIDs = citedPaperIDs
        self.wordCount = wordCount
        self.citations = citations
    }

    init(id: UUID, markdown: String, createdAt: Date, modifiedAt: Date) {
        self.init(
            id: id,
            title: WritingTitle.derive(from: markdown),
            createdAt: createdAt,
            modifiedAt: modifiedAt,
            citedPaperIDs: PaperCitation.citedPaperIDs(in: markdown),
            wordCount: WritingStatistics.wordCount(in: markdown),
            citations: WritingCitationScanner.records(in: markdown)
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        modifiedAt = try container.decode(Date.self, forKey: .modifiedAt)
        citedPaperIDs = try container.decodeIfPresent([UUID].self, forKey: .citedPaperIDs) ?? []
        wordCount = try container.decodeIfPresent(Int.self, forKey: .wordCount) ?? 0
        citations = try? container.decodeIfPresent([WritingCitationRecord].self, forKey: .citations)
    }

    /// Whether the cached citations can be used: a version without them may have written
    /// this metadata after the last citation changed.
    var hasCitationCache: Bool {
        citations != nil || citedPaperIDs.isEmpty
    }
}

/// Writings are Markdown files under `Application Support/ReadPaper/Writings/<id>/`
/// rather than SwiftData rows: an older app version opening a newer store drops the
/// tables it does not know, and a writing must survive that. `meta.json` only caches
/// what lists need and is rebuilt from `writing.md` when it is missing or stale.
struct WritingStore {
    static let directoryName = "Writings"
    static let markdownFilename = "writing.md"
    static let metadataFilename = "meta.json"
    /// How much newer `writing.md` may be than `meta.json` before the metadata is rebuilt;
    /// a save writes the Markdown just before the metadata.
    static let metadataStalenessTolerance: TimeInterval = 2

    var fileStore: PaperFileStore
    /// Uses the system Trash on macOS and app-local Recently Deleted on iPadOS.
    /// Tests can opt into immediate removal.
    var movesDeletedWritingsToTrash: Bool

    init(fileStore: PaperFileStore = PaperFileStore(), movesDeletedWritingsToTrash: Bool = true) {
        self.fileStore = fileStore
        self.movesDeletedWritingsToTrash = movesDeletedWritingsToTrash
    }

    private var fileManager: FileManager {
        fileStore.fileManager
    }

    var writingsDirectory: URL {
        get throws {
            try fileStore.applicationSupportDirectory.appendingPathComponent(Self.directoryName, isDirectory: true)
        }
    }

    func directory(for id: UUID) throws -> URL {
        try writingsDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func markdownURL(for id: UUID) throws -> URL {
        try directory(for: id).appendingPathComponent(Self.markdownFilename, isDirectory: false)
    }

    func create(id: UUID = UUID(), markdown: String = "", now: Date = Date()) throws -> WritingMetadata {
        try save(markdown: markdown, for: id, createdAt: now, now: now)
    }

    /// All writings, most recently modified first. Folders without a `writing.md` are skipped.
    func loadAll() throws -> [WritingMetadata] {
        try loadAll(in: writingsDirectory)
    }

    private func loadAll(in root: URL) throws -> [WritingMetadata] {
        guard fileManager.fileExists(atPath: root.path) else { return [] }

        let entries = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        var writings: [WritingMetadata] = []
        for entry in entries {
            guard let id = UUID(uuidString: entry.lastPathComponent) else { continue }
            let markdownURL = entry.appendingPathComponent(Self.markdownFilename, isDirectory: false)
            guard fileManager.fileExists(atPath: markdownURL.path) else { continue }
            if let metadata = loadMetadata(id: id, directory: entry, markdownURL: markdownURL) {
                writings.append(metadata)
            }
        }
        return writings.sorted { lhs, rhs in
            if lhs.modifiedAt != rhs.modifiedAt {
                return lhs.modifiedAt > rhs.modifiedAt
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    func loadMarkdown(for id: UUID) throws -> String {
        try String(contentsOf: markdownURL(for: id), encoding: .utf8)
    }

    /// Writes the Markdown, then its metadata, both atomically.
    @discardableResult
    func save(markdown: String, for id: UUID, createdAt: Date, now: Date = Date()) throws -> WritingMetadata {
        let directory = try directory(for: id)
        try fileStore.ensureDirectory(directory)
        try Data(markdown.utf8).write(
            to: directory.appendingPathComponent(Self.markdownFilename, isDirectory: false),
            options: .atomic
        )
        let metadata = WritingMetadata(id: id, markdown: markdown, createdAt: createdAt, modifiedAt: now)
        try writeMetadata(metadata, in: directory)
        return metadata
    }

    /// Copies an image into the writing's `assets` folder and returns its path relative to
    /// `writing.md`, ready for a Markdown image.
    func importImage(_ source: WritingImageSource, into id: UUID, now: Date = Date()) throws -> String {
        let assets = try directory(for: id).appendingPathComponent(WritingImagePath.assetsDirectoryName, isDirectory: true)
        try fileStore.ensureDirectory(assets)

        let destination: URL
        switch source {
        case let .file(url):
            let fileExtension = url.pathExtension.lowercased()
            destination = uniqueAssetURL(
                baseName: WritingImagePath.assetBaseName(from: url.deletingPathExtension().lastPathComponent),
                fileExtension: fileExtension.isEmpty ? "png" : fileExtension,
                in: assets
            )
            try fileManager.copyItem(at: url, to: destination)
        case let .data(data, fileExtension):
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            destination = uniqueAssetURL(
                baseName: "image-\(formatter.string(from: now))",
                fileExtension: fileExtension,
                in: assets
            )
            try data.write(to: destination, options: .atomic)
        }
        return "\(WritingImagePath.assetsDirectoryName)/\(destination.lastPathComponent)"
    }

    private func uniqueAssetURL(baseName: String, fileExtension: String, in directory: URL) -> URL {
        var candidate = directory.appendingPathComponent(baseName).appendingPathExtension(fileExtension)
        var number = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(baseName)-\(number)").appendingPathExtension(fileExtension)
            number += 1
        }
        return candidate
    }

    func delete(_ id: UUID) throws {
        let directory = try directory(for: id)
        guard fileManager.fileExists(atPath: directory.path) else { return }
        if movesDeletedWritingsToTrash {
            #if os(iOS)
            let trash = try deletedWritingsDirectory
            try fileStore.ensureDirectory(trash)
            // moveItem refuses to overwrite a previous copy. A failed move leaves the
            // active writing intact, so the library can safely keep showing it.
            try fileManager.moveItem(at: directory, to: trash.appendingPathComponent(id.uuidString, isDirectory: true))
            #else
            try fileManager.trashItem(at: directory, resultingItemURL: nil)
            #endif
        } else {
            try fileManager.removeItem(at: directory)
        }
    }

    #if os(iOS)
    /// Kept outside Writings so normal library scans never rediscover deleted drafts.
    var deletedWritingsDirectory: URL {
        get throws {
            try fileStore.applicationSupportDirectory.appendingPathComponent("DeletedWritings", isDirectory: true)
        }
    }

    func loadDeletedWritings() throws -> [WritingMetadata] {
        try loadAll(in: deletedWritingsDirectory)
    }

    func restoreWriting(_ id: UUID) throws {
        let source = try deletedWritingsDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        try fileStore.ensureDirectory(writingsDirectory)
        // Never replace an active draft with an archived copy.
        try fileManager.moveItem(at: source, to: directory(for: id))
    }
    #endif

    private func loadMetadata(id: UUID, directory: URL, markdownURL: URL) -> WritingMetadata? {
        let values = try? markdownURL.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
        let markdownModifiedAt = values?.contentModificationDate ?? Date()
        let stored = try? readMetadata(in: directory)

        if let stored,
           stored.id == id,
           stored.version <= WritingMetadata.currentVersion,
           stored.hasCitationCache,
           markdownModifiedAt.timeIntervalSince(stored.modifiedAt) <= Self.metadataStalenessTolerance {
            return stored
        }

        guard let markdown = try? String(contentsOf: markdownURL, encoding: .utf8) else { return nil }
        let rebuilt = WritingMetadata(
            id: id,
            markdown: markdown,
            createdAt: stored?.createdAt ?? values?.creationDate ?? markdownModifiedAt,
            modifiedAt: max(markdownModifiedAt, stored?.modifiedAt ?? .distantPast)
        )
        // Leave metadata written by a newer app version alone.
        if (stored?.version ?? 0) <= WritingMetadata.currentVersion {
            try? writeMetadata(rebuilt, in: directory)
        }
        return rebuilt
    }

    private func readMetadata(in directory: URL) throws -> WritingMetadata {
        let data = try Data(contentsOf: directory.appendingPathComponent(Self.metadataFilename, isDirectory: false))
        return try Self.decoder.decode(WritingMetadata.self, from: data)
    }

    private func writeMetadata(_ metadata: WritingMetadata, in directory: URL) throws {
        try Self.encoder.encode(metadata).write(
            to: directory.appendingPathComponent(Self.metadataFilename, isDirectory: false),
            options: .atomic
        )
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
