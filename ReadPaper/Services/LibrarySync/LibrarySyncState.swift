import Foundation
import Darwin

final class LibrarySyncLease {
    private let descriptor: Int32
    init(root: URL) throws {
        let path = root.appendingPathComponent("Sync/session.lock").path
        descriptor = Darwin.open(path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            throw LibrarySyncError.message("Another Freddie process is already syncing this library.")
        }
    }
    deinit { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
}

struct LibrarySyncKnown: Codable, Sendable {
    var revision: UInt64
    var entry: LibrarySyncEntry?
    var scope: LibrarySyncScope
}

struct LibrarySyncPendingPush: Codable, Sendable {
    var request: LibrarySyncPush
    var entries: [String: LibrarySyncEntry]
    var deviceID: String
}

struct LibrarySyncConflict: Codable, Identifiable, Sendable {
    var id: String
    var title: String
    var local: LibrarySyncEntry?
    var remote: LibrarySyncRecord
}

struct LibrarySyncState: Codable, Sendable {
    var version = 1
    var info: LibrarySyncInfo?
    var cursor: UInt64 = 0
    var known: [String: LibrarySyncKnown] = [:]
    var incoming: [String: LibrarySyncRecord] = [:]
    var outbox: [LibrarySyncMutation] = []
    var inFlight: LibrarySyncPendingPush?
    var conflicts: [String: LibrarySyncConflict] = [:]
    var explicitRestores: Set<String> = []
    var lastSuccess: Date?

    mutating func accept(_ record: LibrarySyncRecord, entry: LibrarySyncEntry?, scope: LibrarySyncScope) {
        known[record.key] = .init(revision: record.revision, entry: entry, scope: scope)
        incoming.removeValue(forKey: record.key)
        conflicts.removeValue(forKey: record.key)
        explicitRestores.remove(record.key)
    }

    /// Captures the current intent before a request is sent. Deletion is only
    /// inferred for records this installation previously applied or uploaded.
    mutating func stage(_ entries: [String: LibrarySyncEntry], protected: Set<String>) {
        var mutations: [LibrarySyncMutation] = []
        for (key, entry) in entries where !protected.contains(key) && conflicts[key] == nil {
            let previous = known[key]
            if previous?.entry == entry { continue }
            if let previous, previous.entry == nil, !explicitRestores.contains(key) { continue }
            mutations.append(.init(
                kind: entry.kind, id: entry.id, baseRevision: previous?.revision ?? 0,
                deleted: false, restore: previous != nil && previous?.entry == nil,
                payload: entry.payload, blobs: entry.blobs
            ))
        }
        for (key, previous) in known where previous.entry != nil && entries[key] == nil && !protected.contains(key) && conflicts[key] == nil {
            guard let entry = previous.entry else { continue }
            mutations.append(.init(kind: entry.kind, id: entry.id, baseRevision: previous.revision, deleted: true, payload: nil, blobs: []))
        }
        // Publish dependencies first. Paper deletions follow their child records.
        outbox = mutations.sorted { lhs, rhs in
            let l = Self.priority(kind: lhs.kind, deleted: lhs.deleted)
            let r = Self.priority(kind: rhs.kind, deleted: rhs.deleted)
            return l == r ? lhs.key < rhs.key : l < r
        }
    }

    static func priority(kind: String, deleted: Bool) -> Int {
        if deleted { return kind == "paper" || kind == "writing" ? 30 : 20 }
        switch kind {
        case "paper", "folder": return 0
        case "htmlState": return 1
        case "attachment", "writing": return 2
        default: return 3
        }
    }
}

struct LibrarySyncStateStore: Sendable {
    let root: URL

    func configurationURL() -> URL { root.appendingPathComponent("Sync/configuration.json") }

    func loadConfiguration() throws -> LibrarySyncConfiguration? {
        let url = configurationURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try LibrarySyncCoding.decoder().decode(LibrarySyncConfiguration.self, from: Data(contentsOf: url))
    }

    func saveConfiguration(_ value: LibrarySyncConfiguration) throws {
        try Self.write(try LibrarySyncCoding.encoder().encode(value), to: configurationURL())
    }

    func stateURL(_ configuration: LibrarySyncConfiguration) -> URL {
        let identity = configuration.baseURL.absoluteString + "|" + configuration.libraryID
        return root.appendingPathComponent("Sync/State-" + Hashing.sha256Hex(identity) + ".json")
    }

    func load(_ configuration: LibrarySyncConfiguration) throws -> LibrarySyncState {
        let url = stateURL(configuration)
        guard FileManager.default.fileExists(atPath: url.path) else { return LibrarySyncState() }
        let state = try LibrarySyncCoding.decoder().decode(LibrarySyncState.self, from: Data(contentsOf: url))
        guard state.version == 1 else { throw LibrarySyncError.message("This sync state was created by a newer version of Freddie.") }
        return state
    }

    func save(_ state: LibrarySyncState, configuration: LibrarySyncConfiguration) throws {
        try Self.write(try LibrarySyncCoding.encoder().encode(state), to: stateURL(configuration))
    }

    static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let handle = try FileHandle(forWritingTo: url)
        try handle.synchronize()
        try handle.close()
    }
}

struct LibrarySyncReaderActivity: Equatable {
    var paperID: UUID?
    var isBusy: Bool
}

@MainActor
final class LibrarySyncActivity {
    static let shared = LibrarySyncActivity()
    private var readers: [UUID: LibrarySyncReaderActivity] = [:]
    private var noteEditors: [UUID: Set<UUID>] = [:]
    private var notePapers: [UUID: UUID] = [:]
    private var work: [UUID: UUID] = [:]
    func update(_ id: UUID, activity: LibrarySyncReaderActivity) { readers[id] = activity }
    func remove(_ id: UUID) { readers.removeValue(forKey: id) }
    var busyPaperIDs: Set<UUID> {
        Set(readers.values.filter(\.isBusy).compactMap(\.paperID)).union(work.values)
            .union(editingNoteIDs.compactMap { notePapers[$0] })
    }
    /// Papers shown in a reader or Inspector, busy or not. Their models must not
    /// be deleted underneath the views that hold them.
    var openPaperIDs: Set<UUID> { Set(readers.values.compactMap(\.paperID)) }
    func beginWork(paperID: UUID) -> UUID { let id = UUID(); work[id] = paperID; return id }
    func endWork(_ id: UUID) { work.removeValue(forKey: id) }
    var editingNoteIDs: Set<UUID> { Set(noteEditors.values.flatMap { $0 }) }
    func noteEditing(_ id: UUID, owner: UUID, active: Bool, paperID: UUID? = nil) {
        if active {
            noteEditors[owner, default: []].insert(id)
            if let paperID { notePapers[id] = paperID }
        } else {
            noteEditors[owner]?.remove(id)
            if !editingNoteIDs.contains(id) { notePapers.removeValue(forKey: id) }
        }
    }
    func removeNoteEditor(_ owner: UUID) {
        let removed = noteEditors.removeValue(forKey: owner) ?? []
        for id in removed where !editingNoteIDs.contains(id) { notePapers.removeValue(forKey: id) }
    }
}

extension Notification.Name {
    static let librarySyncDidApply = Notification.Name("ReadPaper.LibrarySync.DidApply")
}
