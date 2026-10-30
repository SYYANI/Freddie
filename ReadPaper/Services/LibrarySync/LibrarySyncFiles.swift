import CryptoKit
import Darwin
import Foundation

struct LibrarySyncStamp: Codable, Equatable, Sendable {
    var size: Int64
    var modified: TimeInterval
    var inode: UInt64

    static func read(_ url: URL) throws -> Self? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let values = try FileManager.default.attributesOfItem(atPath: url.path)
        guard values[.type] as? FileAttributeType == .typeRegular else {
            throw LibrarySyncError.message("Sync cannot read a symbolic link or special file.")
        }
        return .init(size: (values[.size] as? NSNumber)?.int64Value ?? 0,
                     modified: (values[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
                     inode: (values[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0)
    }
}

enum LibrarySyncPaths {
    static func directory(root: URL, scope: LibrarySyncScope) throws -> URL {
        switch (scope.paperID, scope.writingID) {
        case (let id?, nil): root.appendingPathComponent("Library/" + id.uuidString, isDirectory: true)
        case (nil, let id?): root.appendingPathComponent("Writings/" + id.uuidString, isDirectory: true)
        default: throw LibrarySyncError.message("The synced document scope is not valid.")
        }
    }

    static func file(root: URL, scope: LibrarySyncScope, path: String) throws -> URL {
        guard !path.isEmpty, path.utf8.count <= 4096, !path.hasPrefix("/"),
              !path.contains("\\"), !path.contains("\0") else {
            throw LibrarySyncError.message("The synced file path is not safe.")
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count <= 32, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".Sync") }) else {
            throw LibrarySyncError.message("The synced file path is not safe.")
        }
        let directory = try directory(root: root, scope: scope)
        let target = directory.appendingPathComponent(path).standardizedFileURL
        let absoluteRoot = root.standardizedFileURL.path + "/"
        guard target.path.hasPrefix(absoluteRoot) else { throw LibrarySyncError.message("The synced file path is not safe.") }
        var current = root
        for part in target.path.dropFirst(absoluteRoot.count).split(separator: "/") {
            current.appendPathComponent(String(part))
            if let values = try? current.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true {
                throw LibrarySyncError.message("Sync cannot read a symbolic link or special file.")
            }
        }
        return target
    }

    static func relative(_ url: URL, root: URL, scope: LibrarySyncScope) throws -> String {
        let directory = try directory(root: root, scope: scope).standardizedFileURL.path + "/"
        guard url.standardizedFileURL.path.hasPrefix(directory) else {
            throw LibrarySyncError.message("An attachment is outside the managed paper library.")
        }
        let path = String(url.standardizedFileURL.path.dropFirst(directory.count))
        _ = try file(root: root, scope: scope, path: path)
        return path
    }

    static func rename(_ source: URL, to destination: URL) throws {
        guard Darwin.rename(source.path, destination.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
}

struct LibrarySyncAttachmentSeed: Equatable, Sendable {
    var value: LibrarySyncAttachment
    var url: URL
    /// False when the file lies outside the managed paper directory.
    var isManaged = true
}

struct LibrarySyncSeed: Equatable, Sendable {
    var documents: [LibrarySyncDocument]
    var attachments: [LibrarySyncAttachmentSeed]
    var paperIDs: [UUID]
    var blockedWritingIDs: Set<UUID> = []
}

struct LibrarySyncUnavailableAttachment: Equatable, Identifiable, Sendable {
    enum Reason: Equatable, Sendable { case missing, unreadable, outsideLibrary }
    var id: UUID
    var paperID: UUID
    var paperTitle: String
    var filename: String
    var url: URL
    var reason: Reason
}

struct LibrarySyncSnapshot: Sendable {
    var entries: [String: LibrarySyncEntry] = [:]
    var documents: [String: LibrarySyncDocument] = [:]
    var stamps: [String: [String: LibrarySyncStamp]] = [:]
    /// Attachments whose file is missing or outside the library. They are neither
    /// uploaded nor inferred as deleted; a remote version may restore the file.
    var unavailable: Set<String> = []
    var unavailableAttachments: [LibrarySyncUnavailableAttachment] = []

    func filesAreCurrent(_ key: String) throws -> Bool {
        for (path, stamp) in stamps[key] ?? [:] {
            if try LibrarySyncStamp.read(URL(fileURLWithPath: path)) != stamp { return false }
        }
        return true
    }

    mutating func removeAll(where shouldRemove: (LibrarySyncDocument) -> Bool) {
        for (key, document) in documents where shouldRemove(document) {
            entries.removeValue(forKey: key); documents.removeValue(forKey: key); stamps.removeValue(forKey: key)
        }
    }
}

struct LibrarySyncPreparedFile: Sendable {
    var temporary: URL
    var destination: URL
}

actor LibrarySyncFiles {
    private struct Cached: Codable { var stamp: LibrarySyncStamp; var hash: String }
    let root: URL
    private let cache: URL
    private var fingerprints: [String: Cached] = [:]
    private var sources: [String: URL] = [:]
    private var documentEntries: (documents: [LibrarySyncDocument], entries: [LibrarySyncEntry])?

    init(root: URL) throws {
        self.root = root
        cache = root.appendingPathComponent("Sync/Blobs", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = root.appendingPathComponent("Sync/file-fingerprints.json")
        if let data = try? Data(contentsOf: url) {
            // This is only an optimization; state/queue corruption is never ignored.
            fingerprints = (try? LibrarySyncCoding.decoder().decode([String: Cached].self, from: data)) ?? [:]
        }
    }

    func blobURL(_ hash: String) throws -> URL {
        try LibrarySyncClient.validateHash(hash)
        return cache.appendingPathComponent(hash)
    }

    func contains(_ hash: String) throws -> Bool { FileManager.default.fileExists(atPath: try blobURL(hash).path) }

    func hashFile(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func retainDownload(_ downloaded: URL, hash: String, maximumSize: Int64) throws {
        defer { try? FileManager.default.removeItem(at: downloaded) }
        guard let stamp = try LibrarySyncStamp.read(downloaded), stamp.size <= maximumSize,
              try hashFile(downloaded) == hash else {
            throw LibrarySyncError.message("The downloaded file failed its size or SHA-256 check.")
        }
        let destination = try blobURL(hash)
        if FileManager.default.fileExists(atPath: destination.path) { return }
        try FileManager.default.copyItem(at: downloaded, to: destination)
        let handle = try FileHandle(forWritingTo: destination)
        try handle.synchronize(); try handle.close()
    }

    private func dataBlob(_ data: Data) throws -> String {
        guard data.count <= 32 * 1024 * 1024 else { throw LibrarySyncError.message("A sync document exceeds the supported size.") }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let url = try blobURL(hash)
        if !FileManager.default.fileExists(atPath: url.path) { try LibrarySyncStateStore.write(data, to: url) }
        return hash
    }

    func entry(_ document: LibrarySyncDocument) throws -> LibrarySyncEntry {
        let hash = try dataBlob(LibrarySyncCoding.encoder().encode(document))
        return .init(kind: document.identity.kind, id: document.identity.id, payload: .init(documentHash: hash, scope: document.scope),
                     blobs: Array(Set([hash] + document.files.map(\.hash))).sorted(), scope: document.scope, title: document.title)
    }

    func document(_ envelope: LibrarySyncEnvelope) throws -> LibrarySyncDocument {
        guard envelope.schemaVersion == 1 else { throw LibrarySyncError.message("This synced document requires a newer version of Freddie.") }
        let url = try blobURL(envelope.documentHash)
        guard let stamp = try LibrarySyncStamp.read(url), stamp.size <= 32 * 1024 * 1024 else {
            throw LibrarySyncError.message("A sync document exceeds the supported size.")
        }
        let value = try LibrarySyncCoding.decoder().decode(LibrarySyncDocument.self, from: Data(contentsOf: url))
        guard value.schemaVersion == 1 else { throw LibrarySyncError.message("This synced document requires a newer version of Freddie.") }
        guard envelope.scope == nil || envelope.scope == value.scope else { throw LibrarySyncError.message("The synced document does not match its record.") }
        for file in value.files {
            try LibrarySyncClient.validateHash(file.hash)
            guard file.size >= 0, file.size <= 512 * 1024 * 1024 else { throw LibrarySyncError.message("A synced file exceeds the supported size.") }
            _ = try LibrarySyncPaths.file(root: root, scope: value.scope, path: file.relativePath)
        }
        if case .resource(let resource) = value.content {
            _ = try LibrarySyncPaths.directory(root: root, scope: resource.scope)
            let path = resource.file.relativePath
            let allowed = resource.scope.paperID != nil
                ? (path.hasPrefix("Resources/") || path.hasSuffix(".pdf.diagnostics.json"))
                : path.hasPrefix("assets/")
            guard allowed else { throw LibrarySyncError.message("The synced file path is not safe.") }
        }
        if case .writing(let writing) = value.content, writing.file.relativePath != "writing.md" {
            throw LibrarySyncError.message("The synced file path is not safe.")
        }
        if case .writing(let writing) = value.content, writing.file.size > 32 * 1024 * 1024 {
            throw LibrarySyncError.message("A sync document exceeds the supported size.")
        }
        if case .attachment(let attachment) = value.content {
            guard !attachment.file.relativePath.hasPrefix("notes/"), attachment.translatedLastPage.map({ $0 > 0 }) ?? true else {
                throw LibrarySyncError.message("The synced attachment metadata is not valid.")
            }
        }
        if case .translations(let translations) = value.content {
            guard Set(translations.segments.map(\.id)).count == translations.segments.count,
                  Set(translations.segments.map(\.cacheKey)).count == translations.segments.count else {
                throw LibrarySyncError.message("The synced translation cache is not valid.")
            }
        }
        return value
    }

    private func captureFile(_ url: URL, scope: LibrarySyncScope) throws -> (LibrarySyncFile, LibrarySyncStamp) {
        let relative = try LibrarySyncPaths.relative(url, root: root, scope: scope)
        guard let before = try LibrarySyncStamp.read(url) else { throw LibrarySyncError.fileChanged }
        guard before.size <= 512 * 1024 * 1024 else { throw LibrarySyncError.message("A synced file exceeds the supported size.") }
        let hash: String
        if let cached = fingerprints[url.path], cached.stamp == before {
            hash = cached.hash
        } else {
            let temporary = cache.appendingPathComponent(".snapshot-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: temporary) }
            try FileManager.default.copyItem(at: url, to: temporary)
            hash = try hashFile(temporary)
            guard try LibrarySyncStamp.read(url) == before else { throw LibrarySyncError.fileChanged }
            let destination = try blobURL(hash)
            if !FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.moveItem(at: temporary, to: destination) }
            fingerprints[url.path] = Cached(stamp: before, hash: hash)
        }
        sources[hash] = url
        return (.init(relativePath: relative, hash: hash, size: before.size), before)
    }

    func uploadFile(_ hash: String) throws -> URL {
        let destination = try blobURL(hash)
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        guard let source = sources[hash] else { throw LibrarySyncError.fileChanged }
        let temporary = cache.appendingPathComponent(".upload-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: source, to: temporary)
        guard try hashFile(temporary) == hash else { throw LibrarySyncError.fileChanged }
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    func snapshot(_ seed: LibrarySyncSeed) throws -> LibrarySyncSnapshot {
        var result = LibrarySyncSnapshot()
        sources = [:]
        func add(_ document: LibrarySyncDocument, stamps: [String: LibrarySyncStamp] = [:]) throws {
            let value = try entry(document)
            result.entries[value.key] = value
            result.documents[value.key] = document
            result.stamps[value.key] = stamps
        }
        // An unchanged library reuses its encoded entries; the seed's array is
        // usually the same buffer, so the comparison is O(1).
        let reusable = documentEntries.flatMap { $0.documents == seed.documents ? $0.entries : nil }
        var entries: [LibrarySyncEntry] = []
        for (index, document) in seed.documents.enumerated() {
            if let entry = reusable?[index], FileManager.default.fileExists(atPath: try blobURL(entry.payload.documentHash).path) {
                result.entries[entry.key] = entry; result.documents[entry.key] = document; result.stamps[entry.key] = [:]
            } else {
                try add(document)
            }
            entries.append(result.entries[document.key]!)
        }
        documentEntries = (seed.documents, entries)
        let fileStore = PaperFileStore(applicationSupportDirectory: root)
        let annotations = PDFAnnotationStore(fileStore: fileStore)
        var paperTitles: [UUID: String] = [:]
        for document in seed.documents { if case .paper(let paper) = document.content { paperTitles[paper.id] = paper.title } }
        for attachment in seed.attachments {
            var value = attachment.value
            let scope = LibrarySyncScope(paperID: value.paperID)
            var isDirectory: ObjCBool = false
            if attachment.isManaged, FileManager.default.fileExists(atPath: attachment.url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                // A folder attachment is device-local output, not a missing file: keep it
                // out of uploads and deletions without listing it as a problem.
                result.unavailable.insert(LibrarySyncDocument(content: .attachment(value)).key)
                continue
            }
            let reason: LibrarySyncUnavailableAttachment.Reason?
            if !attachment.isManaged { reason = .outsideLibrary }
            else { do { reason = try LibrarySyncStamp.read(attachment.url) == nil ? .missing : nil } catch { reason = .unreadable } }
            if let reason {
                // One missing or foreign file must not stop the whole library from syncing.
                result.unavailable.insert(LibrarySyncDocument(content: .attachment(value)).key)
                result.unavailableAttachments.append(.init(id: value.id, paperID: value.paperID, paperTitle: paperTitles[value.paperID] ?? "", filename: value.filename, url: attachment.url, reason: reason))
            } else {
                let (file, stamp) = try captureFile(attachment.url, scope: scope)
                value.file = file
                try add(.init(content: .attachment(value)), stamps: [attachment.url.path: stamp])
            }
            let sidecar = try annotations.sidecarURL(paperID: value.paperID, attachmentID: value.id)
            let beforeSidecar = try LibrarySyncStamp.read(sidecar)
            let records = try annotations.load(paperID: value.paperID, attachmentID: value.id)
            let sidecarStamp = try LibrarySyncStamp.read(sidecar)
            guard beforeSidecar == sidecarStamp else { throw LibrarySyncError.fileChanged }
            for record in records {
                try add(.init(content: .annotation(.init(paperID: value.paperID, attachmentID: value.id, annotation: record))),
                        stamps: sidecarStamp.map { [sidecar.path: $0] } ?? [:])
            }
            let diagnostics = attachment.url.appendingPathExtension("diagnostics.json")
            if attachment.isManaged, FileManager.default.fileExists(atPath: diagnostics.path) {
                let (file, stamp) = try captureFile(diagnostics, scope: scope)
                try add(.init(content: .resource(.init(scope: scope, file: file))), stamps: [diagnostics.path: stamp])
            }
        }
        for paperID in seed.paperIDs {
            let scope = LibrarySyncScope(paperID: paperID)
            for url in try resourceFiles(in: root.appendingPathComponent("Library/" + paperID.uuidString + "/Resources")) {
                let (file, stamp) = try captureFile(url, scope: scope)
                try add(.init(content: .resource(.init(scope: scope, file: file))), stamps: [url.path: stamp])
            }
        }
        let writings = WritingStore(fileStore: fileStore)
        for metadata in try writings.loadAll() {
            if seed.blockedWritingIDs.contains(metadata.id) { continue }
            guard metadata.version <= WritingMetadata.currentVersion else { throw LibrarySyncError.message("This synced document requires a newer version of Freddie.") }
            let scope = LibrarySyncScope(writingID: metadata.id)
            let markdown = try writings.markdownURL(for: metadata.id)
            let (file, stamp) = try captureFile(markdown, scope: scope)
            guard file.size <= 32 * 1024 * 1024 else { throw LibrarySyncError.message("A sync document exceeds the supported size.") }
            let snapshotMarkdown = try String(contentsOf: uploadFile(file.hash), encoding: .utf8)
            let modifiedAt = max(metadata.modifiedAt, Date(timeIntervalSince1970: stamp.modified))
            try add(.init(content: .writing(.init(id: metadata.id, title: WritingTitle.derive(from: snapshotMarkdown), createdAt: metadata.createdAt, modifiedAt: modifiedAt, file: file))), stamps: [markdown.path: stamp])
            for url in try resourceFiles(in: writings.directory(for: metadata.id).appendingPathComponent("assets")) {
                let (file, stamp) = try captureFile(url, scope: scope)
                try add(.init(content: .resource(.init(scope: scope, file: file))), stamps: [url.path: stamp])
            }
        }
        try LibrarySyncStateStore.write(try LibrarySyncCoding.encoder().encode(fingerprints), to: root.appendingPathComponent("Sync/file-fingerprints.json"))
        return result
    }

    /// Brings `local` up to date after `changes` were applied, so incoming batches
    /// do not rescan the whole library. Only files this sync wrote are re-stamped;
    /// a user's edit to any other file still fails `filesAreCurrent`.
    func snapshot(_ local: LibrarySyncSnapshot, applying changes: [LibrarySyncRepository.Change]) throws -> LibrarySyncSnapshot {
        var result = local
        var touched = Set<String>()
        let annotations = PDFAnnotationStore(fileStore: PaperFileStore(applicationSupportDirectory: root))
        func paths(_ document: LibrarySyncDocument) throws -> [String] {
            var paths = try document.files.map { try LibrarySyncPaths.file(root: root, scope: document.scope, path: $0.relativePath).path }
            if case .annotation(let value) = document.content {
                paths.append(try annotations.sidecarURL(paperID: value.paperID, attachmentID: value.attachmentID).path)
            }
            return paths
        }
        for change in changes {
            let key = change.record.key
            if change.record.deleted {
                guard let previous = change.previous else { continue }
                touched.formUnion(try paths(previous))
                result.entries.removeValue(forKey: key); result.documents.removeValue(forKey: key); result.stamps.removeValue(forKey: key)
                switch previous.content {
                case .paper(let paper): result.removeAll { $0.scope.paperID == paper.id }
                case .writing(let writing): result.removeAll { $0.scope.writingID == writing.id }
                case .attachment(let attachment):
                    result.removeAll { if case .annotation(let value) = $0.content { value.attachmentID == attachment.id } else { false } }
                default: break
                }
            } else if let document = change.document {
                let written = try paths(document)
                touched.formUnion(written)
                result.entries[key] = try entry(document); result.documents[key] = document
                result.stamps[key] = Dictionary(written.map { ($0, LibrarySyncStamp(size: -1, modified: 0, inode: 0)) }) { first, _ in first }
                result.unavailable.remove(key)
                if case .attachment(let value) = document.content { result.unavailableAttachments.removeAll { $0.id == value.id } }
            }
        }
        for (key, stamps) in result.stamps {
            for path in stamps.keys where touched.contains(path) {
                result.stamps[key]?[path] = try LibrarySyncStamp.read(URL(fileURLWithPath: path))
            }
        }
        return result
    }

    private func resourceFiles(in directory: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else {
            throw LibrarySyncError.fileChanged
        }
        var result: [URL] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { throw LibrarySyncError.message("Sync cannot read a symbolic link or special file.") }
            if values.isDirectory == true {
                if ["Outline", "LaTeXSemantic", "ScanRebuild", "BabelDOC"].contains(url.lastPathComponent) { enumerator.skipDescendants() }
            } else { result.append(url) }
        }
        return result.sorted { $0.path < $1.path }
    }

    func prepare(_ document: LibrarySyncDocument) throws -> [LibrarySyncPreparedFile] {
        var result: [LibrarySyncPreparedFile] = []
        do {
            for file in document.files {
                let target = try LibrarySyncPaths.file(root: root, scope: document.scope, path: file.relativePath)
                let source = try blobURL(file.hash)
                guard try LibrarySyncStamp.read(source)?.size == file.size else { throw LibrarySyncError.message("The downloaded file failed its size or SHA-256 check.") }
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                let temporary = target.deletingLastPathComponent().appendingPathComponent(".SyncIncoming-" + UUID().uuidString)
                try FileManager.default.copyItem(at: source, to: temporary)
                let handle = try FileHandle(forWritingTo: temporary)
                try handle.synchronize(); try handle.close()
                result.append(.init(temporary: temporary, destination: target))
            }
            return result
        } catch {
            for file in result { try? FileManager.default.removeItem(at: file.temporary) }
            throw error
        }
    }

    func cleanCache(keeping hashes: Set<String>) throws {
        for url in try FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil) {
            if !hashes.contains(url.lastPathComponent) { try FileManager.default.removeItem(at: url) }
        }
    }

    func preserve(_ entries: [LibrarySyncEntry]) throws {
        let directory = root.appendingPathComponent("Sync/Recovery/Conflict-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Blobs"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for hash in Set(entries.flatMap(\.blobs)) {
            let source = try uploadFile(hash)
            try FileManager.default.linkItem(at: source, to: directory.appendingPathComponent("Blobs/" + hash))
        }
        try LibrarySyncStateStore.write(try LibrarySyncCoding.encoder().encode(entries), to: directory.appendingPathComponent("entries.json"))
    }

    func duplicateWriting(_ writing: LibrarySyncWriting, resources: [LibrarySyncDocument], title: String) throws -> UUID {
        let source = try uploadFile(writing.file.hash)
        let markdown = try String(contentsOf: source, encoding: .utf8)
        let store = WritingStore(fileStore: PaperFileStore(applicationSupportDirectory: root))
        let id = UUID()
        let edit = WritingTitle.renaming(markdown, to: title, selection: NSRange(location: 0, length: 0))
        let renamed = edit.map { (markdown as NSString).replacingCharacters(in: $0.range, with: $0.replacement) } ?? markdown
        _ = try store.create(id: id, markdown: renamed)
        for document in resources {
            guard case .resource(let resource) = document.content,
                  resource.scope.writingID == writing.id else { continue }
            let target = try LibrarySyncPaths.file(root: root, scope: .init(writingID: id), path: resource.file.relativePath)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: uploadFile(resource.file.hash), to: target)
        }
        return id
    }
}
