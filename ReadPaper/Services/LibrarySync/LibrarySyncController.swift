import Foundation
import Observation
import SwiftData
#if os(iOS)
import Security
#endif

@MainActor
protocol LibrarySyncCredentialStorage {
    func save(_ token: String, account: String) throws
    func load(account: String) throws -> String?
}

@MainActor
struct LibrarySyncKeychain: LibrarySyncCredentialStorage {
    private let store = KeychainStore(service: "com.yiyan.ReadPaper.sync", accessPolicy: .unprotected)
    func save(_ token: String, account: String) throws {
        #if os(iOS)
        // A restored iPad/iPhone backup must import its own device credential.
        try store.save(token, account: account, accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
        #else
        try store.save(token, account: account)
        #endif
    }
    func load(account: String) throws -> String? { try store.load(account: account) }
}

@MainActor
@Observable
final class LibrarySyncController {
    static let shared = LibrarySyncController(notifyOpenDocuments: true)
    private(set) var configuration: LibrarySyncConfiguration?
    private(set) var isSyncing = false
    private(set) var statusKey = "Sync is not connected."
    private(set) var errorMessage: String?
    private(set) var lastSuccess: Date?
    private(set) var pendingCount = 0
    private(set) var conflicts: [LibrarySyncConflict] = []
    private(set) var progressCompleted = 0
    private(set) var progressTotal = 0
    private(set) var needsHistoryReview = false
    /// Attachments skipped because their file is missing, unreadable, or outside the library.
    private(set) var unavailableAttachments: [LibrarySyncUnavailableAttachment] = []

    @ObservationIgnored private let root: URL
    @ObservationIgnored private let persistence: LibrarySyncStateStore
    @ObservationIgnored private let vault: any LibrarySyncCredentialStorage
    @ObservationIgnored private let makeTransport: (URL, String) throws -> any LibrarySyncTransport
    @ObservationIgnored private let notifyOpenDocuments: Bool
    @ObservationIgnored private var files: LibrarySyncFiles?
    @ObservationIgnored private var repository: LibrarySyncRepository?
    @ObservationIgnored private var state = LibrarySyncState()
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var automaticallyStarted = false
    @ObservationIgnored private var isForeground = true
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var nextAttempt = Date.distantPast
    /// The model generation the latest `snapshot(repository:files:)` reflects.
    @ObservationIgnored private var snapshotGeneration = 0

    /// A local snapshot carried between incoming batches of one sync. It is only
    /// reused while no other save happened and the same documents are blocked.
    private struct ReusableSnapshot {
        var snapshot: LibrarySyncSnapshot
        var generation: Int
        var papers: Set<UUID>
        var writings: Set<UUID>
    }

    init(
        root: URL? = nil,
        vault: (any LibrarySyncCredentialStorage)? = nil,
        notifyOpenDocuments: Bool = false,
        makeTransport: @escaping (URL, String) throws -> any LibrarySyncTransport = { try LibrarySyncClient(baseURL: $0, token: $1) }
    ) {
        let directory = root ?? ((try? PaperFileStore().applicationSupportDirectory) ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/ReadPaper"))
        self.root = directory
        persistence = .init(root: directory)
        self.vault = vault ?? LibrarySyncKeychain()
        self.notifyOpenDocuments = notifyOpenDocuments
        self.makeTransport = makeTransport
        do {
            files = try LibrarySyncFiles(root: directory)
            configuration = try persistence.loadConfiguration()
            if let configuration { state = try persistence.load(configuration); statusKey = "Ready to sync." }
            refreshStatus()
        } catch { errorMessage = error.localizedDescription }
    }

    func start(modelContainer: ModelContainer, automatically: Bool = true) {
        if repository == nil { repository = .init(container: modelContainer, root: root, notifyOpenDocuments: notifyOpenDocuments) }
        guard automatically, timer == nil,
              NSClassFromString("XCTestCase") == nil,
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        automaticallyStarted = true
        timer = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.isForeground, self.configuration?.isEnabled == true, Date() >= self.nextAttempt {
                    await self.syncNow()
                }
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            }
        }
    }

    func setForeground(_ value: Bool) {
        isForeground = value
        if value, automaticallyStarted, configuration?.isEnabled == true { Task { await syncNow() } }
    }

    func setAutomaticSync(_ value: Bool) {
        guard var configuration else { return }
        configuration.isEnabled = value
        do { try persistence.saveConfiguration(configuration); self.configuration = configuration }
        catch { errorMessage = error.localizedDescription }
    }

    func connect(credentialData: Data) async {
        guard !isSyncing else { return }
        isSyncing = true; statusKey = "Checking connection…"; errorMessage = nil
        defer { isSyncing = false }
        do {
            guard credentialData.count <= 64 * 1024 else { throw LibrarySyncError.message("The device credential is not valid.") }
            let credential = try JSONDecoder().decode(LibrarySyncCredential.self, from: credentialData)
            let url = try LibrarySyncClient.validatedBaseURL(credential.baseURL)
            let transport = try makeTransport(url, credential.token)
            let info = try await transport.info()
            guard info.protocolVersion == 1, info.deviceID == credential.device.id, info.libraryID == credential.device.libraryID else {
                throw LibrarySyncError.message("The credential does not match this server or library.")
            }
            let candidate = LibrarySyncConfiguration(baseURL: url, deviceID: info.deviceID, libraryID: info.libraryID, label: credential.device.label, isEnabled: true)
            let saved = try persistence.load(candidate)
            try vault.save(credential.token, account: Self.account(candidate))
            try persistence.saveConfiguration(candidate)
            configuration = candidate; state = saved; nextAttempt = .distantPast; failures = 0
            statusKey = "Ready to sync."; refreshStatus()
        } catch { errorMessage = AppLocalization.format("Unable to connect sync: %@", error.localizedDescription) }
    }

    func syncNow() async {
        guard !isSyncing, let configuration, let repository, let files else { return }
        isSyncing = true; errorMessage = nil; progressCompleted = 0; progressTotal = 0
        defer { isSyncing = false; refreshStatus() }
        do {
            let lease = try LibrarySyncLease(root: root)
            defer { withExtendedLifetime(lease) {} }
            state = try persistence.load(configuration)
            let offlineSnapshot = try await snapshot(repository: repository, files: files)
            state.stage(offlineSnapshot.entries, protected: uploadProtectedKeys(snapshot: offlineSnapshot))
            try save()
            try await files.cleanCache(keeping: retainedBlobHashes())
            guard let token = try vault.load(account: Self.account(configuration)) else {
                throw LibrarySyncError.message("Import a device credential to connect sync.")
            }
            let client = try makeTransport(configuration.baseURL, token)
            statusKey = "Checking connection…"
            let info = try await client.info()
            guard info.protocolVersion == 1, info.libraryID == configuration.libraryID, info.deviceID == configuration.deviceID else {
                throw LibrarySyncError.message("The credential does not match this server or library.")
            }
            if let previous = state.info, previous.storeID != info.storeID || previous.libraryID != info.libraryID {
                needsHistoryReview = true
                throw LibrarySyncError.message("The server history has changed. Review it before continuing sync.")
            }
            state.info = info; try save()
            if let pending = state.inFlight {
                if pending.deviceID == info.deviceID {
                    do { _ = try await send(pending, client: client) }
                    catch let error as LibrarySyncError where error.rejectsRequest {
                        // Nothing was committed, so replaying it would fail forever. Staging
                        // rebuilds the request from the library and re-checks its blobs.
                        state.inFlight = nil; try save()
                    }
                } else {
                    // A replacement credential cannot replay another device's receipt.
                    // Pull/reconcile instead; local content and cached snapshots remain.
                    state.inFlight = nil; state.outbox = []; try save()
                }
            }
            statusKey = "Fetching library changes…"
            var boundary: UInt64?
            repeat {
                let page: LibrarySyncPage
                do { page = try await client.changes(after: state.cursor, until: boundary) }
                catch LibrarySyncError.server(let status, let code, _) where status == 409 && code == "invalid_cursor" {
                    needsHistoryReview = true
                    throw LibrarySyncError.message("The server history has changed. Review it before continuing sync.")
                }
                guard page.cursor >= state.cursor, !page.hasMore || page.cursor > state.cursor else {
                    throw LibrarySyncError.message("The sync server response is not valid.")
                }
                if boundary == nil { boundary = page.headRevision }
                for record in page.changes where record.revision > (state.known[record.key]?.revision ?? 0) {
                    if (state.incoming[record.key]?.revision ?? 0) < record.revision { state.incoming[record.key] = record }
                }
                state.cursor = page.cursor
                try save() // Durable inbox first; applying/downloading can resume after a crash.
                if !page.hasMore { break }
            } while !Task.isCancelled
            try Task.checkCancellation()
            var uploaded = false
            // A revision conflict queues the server's newer record; apply it and retry.
            for _ in 0..<3 {
                var reusable: ReusableSnapshot?
                progressTotal = 0; progressCompleted = 0
                while try await applyIncoming(client: client, reusing: &reusable) { try Task.checkCancellation() }
                let snapshot = try await snapshot(repository: repository, files: files)
                for (key, entry) in snapshot.entries where state.known[key]?.entry == nil && state.known[key] != nil && !state.explicitRestores.contains(key) {
                    guard state.conflicts[key] == nil else { continue }
                    let tombstone = LibrarySyncRecord(kind: entry.kind, id: entry.id, revision: state.known[key]!.revision, deleted: true, payload: nil, blobs: [], deviceID: "", updatedAt: "")
                    state.conflicts[key] = .init(id: key, title: entry.title, local: entry, remote: tombstone)
                }
                state.stage(snapshot.entries, protected: uploadProtectedKeys(snapshot: snapshot))
                try save()
                uploaded = try await upload(snapshot, deviceID: info.deviceID, client: client, files: files)
                if uploaded { break }
                try Task.checkCancellation()
            }
            failures = 0; nextAttempt = .distantPast
            if uploaded { state.lastSuccess = Date() }
            try save()
            statusKey = !state.conflicts.isEmpty ? "Some changes need review."
                : !uploaded ? "Some changes will upload on the next sync."
                : (!state.incoming.isEmpty || !blockedPapers.isEmpty || !blockedWritings.isEmpty ? "Waiting for open documents…" : "Up to date")
            try await files.cleanCache(keeping: retainedBlobHashes())
        } catch {
            failures += 1
            var delay = min(300, pow(2, Double(min(failures, 7)))) + Double.random(in: 0...3)
            if case LibrarySyncError.server(_, _, let requested) = error, let requested { delay = max(delay, min(requested, 3600)) }
            nextAttempt = Date().addingTimeInterval(delay)
            errorMessage = AppLocalization.format("Unable to sync: %@", error.localizedDescription)
            statusKey = "Sync needs attention."
        }
    }

    /// Returns false when the server rejected a batch for a revision conflict.
    private func upload(_ snapshot: LibrarySyncSnapshot, deviceID: String, client: any LibrarySyncTransport, files: LibrarySyncFiles) async throws -> Bool {
        statusKey = "Uploading changes…"
        // Progress spans every batch; a file confirmed for an earlier batch is not checked again.
        var confirmed = Set<String>()
        progressTotal = Set(state.outbox.flatMap(\.blobs)).count; progressCompleted = 0
        while !state.outbox.isEmpty {
            let mutations = Array(state.outbox.prefix(100))
            let values = Dictionary(uniqueKeysWithValues: mutations.compactMap { mutation in snapshot.entries[mutation.key].map { (mutation.key, $0) } })
            let pending = LibrarySyncPendingPush(request: .init(requestID: UUID().librarySyncID, mutations: mutations), entries: values, deviceID: deviceID)
            let hashes = Set(mutations.flatMap(\.blobs)).subtracting(confirmed).sorted()
            for hash in hashes {
                if try await client.hasBlob(hash) == false {
                    let file = try await files.uploadFile(hash)
                    try await client.upload(file, hash: hash)
                }
                confirmed.insert(hash)
                progressCompleted += 1
            }
            // Persist the exact request before sending. The server's immutable
            // blobs are already present, so retries never depend on a mutable PDF.
            state.inFlight = pending; try save()
            if try await send(pending, client: client) == false { return false }
        }
        return true
    }

    private func send(_ pending: LibrarySyncPendingPush, client: any LibrarySyncTransport) async throws -> Bool {
        do {
            let receipt = try await client.push(pending.request)
            guard receipt.requestID == pending.request.requestID, receipt.revisions.count == pending.request.mutations.count, receipt.revisions.allSatisfy({ $0 > 0 }) else {
                throw LibrarySyncError.message("The sync server response is not valid.")
            }
            for (mutation, revision) in zip(pending.request.mutations, receipt.revisions) {
                let entry = pending.entries[mutation.key]
                state.known[mutation.key] = .init(revision: revision, entry: entry, scope: entry?.scope ?? state.known[mutation.key]?.scope ?? .init())
                state.explicitRestores.remove(mutation.key)
            }
            let keys = Set(pending.request.mutations.map(\.key))
            state.outbox.removeAll { keys.contains($0.key) }
            state.inFlight = nil
            try save()
            return true
        } catch LibrarySyncError.conflict(let current) {
            state.inFlight = nil
            if let current { state.incoming[current.key] = current }
            try save()
            return false
        }
    }

    private var blockedPapers: Set<UUID> { notifyOpenDocuments ? LibrarySyncActivity.shared.busyPaperIDs : [] }
    private var openPapers: Set<UUID> { notifyOpenDocuments ? LibrarySyncActivity.shared.openPaperIDs : [] }
    private var blockedWritings: Set<UUID> {
        guard notifyOpenDocuments else { return [] }
        #if os(macOS)
        return WritingDocumentCenter.shared.syncBlockedWritingIDs
        #else
        return IPadWritingDocumentCenter.shared.syncBlockedWritingIDs
        #endif
    }

    /// Captures saved local state; the whole library is read off the main thread.
    /// Pending edits are left to autosave, and a snapshot is only returned when no
    /// save or edit happened while it was taken, so incoming changes are never
    /// judged against an outdated local version.
    private func snapshot(repository: LibrarySyncRepository, files: LibrarySyncFiles) async throws -> LibrarySyncSnapshot {
        statusKey = "Checking local changes…"
        for attempt in 0..<6 {
            if repository.context.hasChanges {
                // Autosave normally lands within a moment; save here only if it does not.
                if attempt < 3 { try await Task.sleep(for: .milliseconds(500)); continue }
                try repository.context.save()
            }
            #if os(macOS)
            await HTMLRegionWriter.shared.waitForQueuedWrites()
            #endif
            let papers = blockedPapers, writings = blockedWritings
            let generation = repository.generation
            let seed = try await repository.seed(excluding: papers, writings: writings)
            let snapshot = try await files.snapshot(seed)
            guard repository.generation == generation, !repository.context.hasChanges,
                  blockedPapers == papers, blockedWritings == writings else { continue }
            snapshotGeneration = generation
            let unavailable = snapshot.unavailableAttachments.sorted { ($0.paperTitle, $0.filename) < ($1.paperTitle, $1.filename) }
            if unavailable != unavailableAttachments { unavailableAttachments = unavailable }
            return snapshot
        }
        throw LibrarySyncError.fileChanged
    }

    /// Keys staging must leave alone: protected documents, attachments whose file
    /// is unavailable, and records whose newer server version is still queued.
    private func uploadProtectedKeys(snapshot: LibrarySyncSnapshot) -> Set<String> {
        protectedKeys(snapshot: snapshot).union(snapshot.unavailable).union(state.incoming.keys)
    }

    private func protectedKeys(snapshot: LibrarySyncSnapshot) -> Set<String> {
        let papers = blockedPapers, writings = blockedWritings
        func blocked(_ scope: LibrarySyncScope) -> Bool {
            scope.paperID.map { papers.contains($0) } == true || scope.writingID.map { writings.contains($0) } == true
        }
        var protected = Set(state.known.filter { blocked($0.value.scope) }.map(\.key))
        protected.formUnion(snapshot.entries.filter { blocked($0.value.scope) }.map(\.key))
        let deletedPaperConflicts = Set(state.conflicts.values.compactMap { conflict -> UUID? in
            guard conflict.remote.kind == "paper", conflict.remote.deleted else { return nil }
            return UUID(uuidString: conflict.remote.id)
        })
        for (key, value) in state.known where value.scope.paperID.map({ deletedPaperConflicts.contains($0) }) == true { protected.insert(key) }
        for (key, value) in snapshot.entries where value.scope.paperID.map({ deletedPaperConflicts.contains($0) }) == true { protected.insert(key) }
        if notifyOpenDocuments {
            for id in LibrarySyncActivity.shared.editingNoteIDs {
                let key = "note/" + id.librarySyncID
                protected.insert(key)
                if let paperID = snapshot.entries[key]?.scope.paperID ?? state.known[key]?.scope.paperID {
                    protected.insert("paper/" + paperID.librarySyncID)
                }
            }
        }
        return protected
    }

    private func downloadedDocument(_ record: LibrarySyncRecord, client: any LibrarySyncTransport) async throws -> LibrarySyncDocument? {
        guard !record.deleted else { return nil }
        guard let files, let envelope = record.payload, record.blobs.contains(envelope.documentHash) else {
            throw LibrarySyncError.message("The sync server response is not valid.")
        }
        try await ensureBlob(envelope.documentHash, maximumSize: 32 * 1024 * 1024, client: client)
        let document = try await files.document(envelope)
        guard document.identity.kind == record.kind, document.identity.id == record.id,
              Set(record.blobs) == Set([envelope.documentHash] + document.files.map(\.hash)) else {
            throw LibrarySyncError.message("The synced document does not match its record.")
        }
        for file in document.files { try await ensureBlob(file.hash, maximumSize: file.size, client: client) }
        return document
    }

    private func ensureBlob(_ hash: String, maximumSize: Int64, client: any LibrarySyncTransport) async throws {
        guard let files else { return }
        if try await files.contains(hash) { return }
        let downloaded = try await client.download(hash)
        try await files.retainDownload(downloaded, hash: hash, maximumSize: maximumSize)
    }

    private func remoteEntry(_ record: LibrarySyncRecord, document: LibrarySyncDocument) -> LibrarySyncEntry {
        .init(kind: record.kind, id: record.id, payload: record.payload!, blobs: record.blobs.sorted(), scope: document.scope, title: document.title)
    }

    private func applyIncoming(client: any LibrarySyncTransport, reusing reusable: inout ReusableSnapshot?) async throws -> Bool {
        guard let repository, let files, !state.incoming.isEmpty else { return false }
        let records = state.incoming.values.sorted {
            if ($0.kind == "paper" && $0.deleted) != ($1.kind == "paper" && $1.deleted) { return $0.kind == "paper" && $0.deleted }
            let l = LibrarySyncState.priority(kind: $0.kind, deleted: $0.deleted), r = LibrarySyncState.priority(kind: $1.kind, deleted: $1.deleted)
            return l == r ? $0.key < $1.key : l < r
        }
        statusKey = "Downloading changes…"
        var documents: [String: LibrarySyncDocument] = [:]
        var previousDocuments: [String: LibrarySyncDocument] = [:]
        var prepared: [String: [LibrarySyncPreparedFile]] = [:]
        defer { for list in prepared.values { for file in list { try? FileManager.default.removeItem(at: file.temporary) } } }
        var batch: [LibrarySyncRecord] = []
        var removedOld = false
        // Each call applies one batch; progress spans every batch of this download.
        progressTotal = max(progressTotal, progressCompleted + records.count)
        for record in records {
            if batch.count >= 50 { break }
            let knownScope = state.known[record.key]?.scope
            if knownScope?.paperID.map({ blockedPapers.contains($0) }) == true || knownScope?.writingID.map({ blockedWritings.contains($0) }) == true { continue }
            // Views still hold an open paper's models; delete them once it is closed.
            if record.deleted, knownScope?.paperID.map({ openPapers.contains($0) }) == true { continue }
            if record.revision <= (state.known[record.key]?.revision ?? 0) { state.incoming.removeValue(forKey: record.key); removedOld = true; progressCompleted += 1; continue }
            if let document = try await downloadedDocument(record, client: client) {
                if document.scope.paperID.map({ blockedPapers.contains($0) }) == true || document.scope.writingID.map({ blockedWritings.contains($0) }) == true { continue }
                documents[record.key] = document
                prepared[record.key] = try await files.prepare(document)
            }
            batch.append(record)
            if let previous = state.known[record.key]?.entry {
                previousDocuments[record.key] = try await files.document(previous.payload)
            }
            progressCompleted += 1
        }
        let local: LibrarySyncSnapshot, localGeneration: Int
        if let reusable, reusable.generation == repository.generation, !repository.context.hasChanges,
           reusable.papers == blockedPapers, reusable.writings == blockedWritings,
           Self.covers(prepared.values.joined(), snapshot: reusable.snapshot) {
            local = reusable.snapshot; localGeneration = reusable.generation
        } else {
            local = try await snapshot(repository: repository, files: files); localGeneration = snapshotGeneration
        }
        let localPapers = blockedPapers, localWritings = blockedWritings
        let protected = protectedKeys(snapshot: local)
        let deletions = Array(state.incoming.values) + state.conflicts.values.map(\.remote)
        var conflictingPaperDeletions = Set<UUID>()
        for deletion in deletions where deletion.kind == "paper" && deletion.deleted {
            guard let paperID = UUID(uuidString: deletion.id) else { continue }
            let dirtyChild = local.entries.values.contains {
                $0.kind != "readingState" && $0.scope.paperID == paperID && ($0 != state.known[$0.key]?.entry || (state.known[$0.key]?.revision ?? 0) > deletion.revision)
            }
            let laterRemoteChild = state.incoming.values.contains {
                !$0.deleted && $0.kind != "readingState" && $0.payload?.scope?.paperID == paperID && $0.revision > deletion.revision
            }
            if dirtyChild || laterRemoteChild || state.conflicts[deletion.key] != nil { conflictingPaperDeletions.insert(paperID) }
        }
        let creatingPapers = Set(documents.values.compactMap { document -> UUID? in
            guard case .paper(let value) = document.content,
                  local.entries[document.key] == state.known[document.key]?.entry else { return nil }
            return value.id
        })
        let creatingWritings = Set(documents.values.compactMap { document -> UUID? in
            guard case .writing(let value) = document.content,
                  local.entries[document.key] == state.known[document.key]?.entry else { return nil }
            return value.id
        })
        var changes: [LibrarySyncRepository.Change] = []
        var accepted: [(LibrarySyncRecord, LibrarySyncEntry?, LibrarySyncScope)] = []
        var madeProgress = removedOld
        for record in batch {
            if record.revision <= (state.known[record.key]?.revision ?? 0) { continue }
            let known = state.known[record.key]
            // A missing attachment file is not a local edit; the remote version restores it.
            let own = local.entries[record.key] ?? (local.unavailable.contains(record.key) ? known?.entry : nil)
            let document = documents[record.key]
            let scope = document?.scope ?? own?.scope ?? known?.scope ?? .init()
            if record.kind != "paper", scope.paperID.map({ conflictingPaperDeletions.contains($0) }) == true { continue }
            if protected.contains(record.key) || scope.paperID.map({ blockedPapers.contains($0) }) == true || scope.writingID.map({ blockedWritings.contains($0) }) == true { continue }
            if let document, !repository.canApply(document, creating: creatingPapers, writings: creatingWritings) {
                // Wait while the parent paper or writing is still queued. Otherwise it was
                // deleted here, so ask the user instead of waiting forever.
                let parent = document.scope.paperID.map { "paper/" + $0.librarySyncID } ?? document.scope.writingID.map { "writing/" + $0.librarySyncID }
                if parent.flatMap({ state.incoming[$0] }).map({ !$0.deleted }) == true { continue }
                state.conflicts[record.key] = .init(id: record.key, title: document.title, local: nil, remote: record)
                state.incoming.removeValue(forKey: record.key); madeProgress = true
                continue
            }
            guard try local.filesAreCurrent(record.key) else { continue }
            let remote = document.map { remoteEntry(record, document: $0) }
            if own == remote {
                accepted.append((record, remote, scope)); madeProgress = true; continue
            }
            var isClean = own == known?.entry
            if let document, document.files.contains(where: { incomingFile in
                local.documents.values.contains { existing in
                    existing.key != document.key && existing.scope == document.scope && existing.files.contains { $0.relativePath == incomingFile.relativePath && $0.hash != incomingFile.hash }
                }
            }) { isClean = false }
            if record.kind == "paper", record.deleted, let paperID = scope.paperID {
                if conflictingPaperDeletions.contains(paperID) { isClean = false }
            }
            if !isClean, let localDocument = local.documents[record.key], let document,
               let merged = try LibrarySyncMerge.merged(base: previousDocuments[record.key], local: localDocument, remote: document) {
                if merged != localDocument {
                    changes.append(.init(record: record, document: merged, previous: previousDocuments[record.key], files: []))
                }
                accepted.append((record, remote, scope)); madeProgress = true
                continue
            }
            if isClean {
                let previous = previousDocuments[record.key] ?? local.documents[record.key]
                changes.append(.init(record: record, document: document, previous: previous, files: prepared[record.key] ?? []))
                accepted.append((record, remote, scope)); madeProgress = true
            } else {
                state.conflicts[record.key] = .init(id: record.key, title: own?.title ?? document?.title ?? record.kind, local: own, remote: record)
                state.incoming.removeValue(forKey: record.key); madeProgress = true
            }
        }
        statusKey = "Applying changes…"
        changes.sort { LibrarySyncState.priority(kind: $0.record.kind, deleted: $0.record.deleted) < LibrarySyncState.priority(kind: $1.record.kind, deleted: $1.record.deleted) }
        let before = repository.generation
        let saved = try repository.apply(changes)
        let after = repository.generation
        for (record, entry, scope) in accepted { state.accept(record, entry: entry, scope: scope) }
        try save()
        // Carry the snapshot forward only if this apply was the sole save since it was taken.
        if before == localGeneration, after == before + (saved ? 1 : 0) {
            reusable = .init(snapshot: try await files.snapshot(local, applying: changes), generation: after, papers: localPapers, writings: localWritings)
        } else {
            reusable = nil
        }
        return madeProgress && !state.incoming.isEmpty
    }

    /// A reused snapshot has not seen files created since it was taken; any file
    /// about to be replaced must be one it stamped.
    private static func covers(_ files: some Sequence<LibrarySyncPreparedFile>, snapshot: LibrarySyncSnapshot) -> Bool {
        let stamped = Set(snapshot.stamps.values.flatMap(\.keys))
        return files.allSatisfy { !FileManager.default.fileExists(atPath: $0.destination.path) || stamped.contains($0.destination.path) }
    }

    func reviewChangedHistory() {
        guard !isSyncing, let configuration else { return }
        do {
            let data = try LibrarySyncCoding.encoder().encode(state)
            try LibrarySyncStateStore.write(data, to: root.appendingPathComponent("Sync/Recovery/History-" + UUID().uuidString + ".json"))
            state = LibrarySyncState(); try persistence.save(state, configuration: configuration)
            needsHistoryReview = false; errorMessage = nil; nextAttempt = .distantPast; refreshStatus()
        } catch { errorMessage = error.localizedDescription }
    }

    enum ConflictChoice: Equatable { case thisDevice, server, keepBoth }

    func resolve(_ id: String, choice: ConflictChoice) async {
        guard !isSyncing, let configuration, let repository, let files, let conflict = state.conflicts[id] else { return }
        isSyncing = true; errorMessage = nil
        do {
            guard let token = try vault.load(account: Self.account(configuration)) else {
                throw LibrarySyncError.message("Import a device credential to connect sync.")
            }
            let client = try makeTransport(configuration.baseURL, token)
            let document = try await downloadedDocument(conflict.remote, client: client)
            let prepared: [LibrarySyncPreparedFile]
            if let document { prepared = try await files.prepare(document) } else { prepared = [] }
            var knownDocument: LibrarySyncDocument?
            if let entry = state.known[id]?.entry { knownDocument = try await files.document(entry.payload) }
            defer { for file in prepared { try? FileManager.default.removeItem(at: file.temporary) } }
            let local = try await snapshot(repository: repository, files: files)
            let own = local.entries[id]
            let scope = document?.scope ?? own?.scope ?? state.known[id]?.scope ?? .init()
            guard scope.paperID.map({ !blockedPapers.contains($0) }) ?? true,
                  scope.writingID.map({ !blockedWritings.contains($0) }) ?? true else {
                throw LibrarySyncError.message("Finish editing this document before resolving its sync conflict.")
            }
            if choice != .thisDevice, conflict.remote.deleted, scope.paperID.map({ openPapers.contains($0) }) == true {
                throw LibrarySyncError.message("Close this paper before accepting this deletion.")
            }
            if choice != .thisDevice, let document, !repository.canApply(document, creating: [], writings: []) {
                throw LibrarySyncError.message("This change belongs to a paper or writing deleted on this device. Keep this device's version to discard it.")
            }
            if choice == .thisDevice {
                state.known[id] = .init(revision: conflict.remote.revision, entry: document.map { remoteEntry(conflict.remote, document: $0) }, scope: scope)
                if conflict.remote.deleted { state.explicitRestores.insert(id) }
                if conflict.remote.kind == "paper", conflict.remote.deleted, let paperID = scope.paperID {
                    for (key, pending) in state.incoming where key != id && local.entries[key]?.scope.paperID == paperID {
                        let entry = local.entries[key]!
                        let baseline = pending.payload.map { LibrarySyncEntry(kind: pending.kind, id: pending.id, payload: $0, blobs: pending.blobs.sorted(), scope: entry.scope, title: entry.title) }
                        state.known[key] = .init(revision: pending.revision, entry: pending.deleted ? nil : baseline, scope: entry.scope)
                        if pending.deleted { state.explicitRestores.insert(key) }
                        state.incoming.removeValue(forKey: key)
                    }
                }
            } else {
                func group(_ snapshot: LibrarySyncSnapshot) -> [String: LibrarySyncEntry] {
                    snapshot.entries.filter { key, value in
                        key == id || (scope.paperID != nil && value.scope.paperID == scope.paperID) || (scope.writingID != nil && value.scope.writingID == scope.writingID)
                    }
                }
                try await files.preserve(Array(group(local).values))
                if choice == .keepBoth, case .writing(let writing)? = local.documents[id]?.content {
                    _ = try await files.duplicateWriting(writing, resources: Array(local.documents.values), title: AppLocalization.format("%@ (conflict copy)", writing.title))
                }
                let current = try await snapshot(repository: repository, files: files)
                // Duplicating a writing adds a new scope; original scope must be unchanged.
                guard group(current) == group(local), try current.filesAreCurrent(id) else { throw LibrarySyncError.fileChanged }
                let previous = current.documents[id] ?? knownDocument
                try repository.apply([.init(record: conflict.remote, document: document, previous: previous, files: prepared)])
                state.accept(conflict.remote, entry: document.map { remoteEntry(conflict.remote, document: $0) }, scope: scope)
            }
            state.conflicts.removeValue(forKey: id); state.incoming.removeValue(forKey: id)
            try save(); refreshStatus()
            isSyncing = false
            await syncNow()
        } catch {
            errorMessage = AppLocalization.format("Unable to resolve sync conflict: %@", error.localizedDescription)
        }
        isSyncing = false; refreshStatus()
    }

    private func save() throws {
        if let configuration { try persistence.save(state, configuration: configuration) }
        pendingCount = state.outbox.count + state.incoming.count
    }
    private func retainedBlobHashes() -> Set<String> {
        var retained = Set(state.known.values.compactMap { $0.entry?.payload.documentHash })
        for value in state.known.values where value.entry?.kind == "writing" { retained.formUnion(value.entry?.blobs ?? []) }
        for record in state.incoming.values { retained.formUnion(record.blobs) }
        for conflict in state.conflicts.values { retained.formUnion(conflict.remote.blobs); retained.formUnion(conflict.local?.blobs ?? []) }
        retained.formUnion(state.inFlight?.request.mutations.flatMap(\.blobs) ?? [])
        retained.formUnion(state.outbox.flatMap(\.blobs))
        return retained
    }
    private func refreshStatus() {
        conflicts = state.conflicts.values.sorted { $0.id < $1.id }
        pendingCount = state.outbox.count + state.incoming.count
        lastSuccess = state.lastSuccess
    }
    private static func account(_ configuration: LibrarySyncConfiguration) -> String {
        Hashing.sha256Hex(configuration.baseURL.absoluteString + "|" + configuration.deviceID)
    }
}
