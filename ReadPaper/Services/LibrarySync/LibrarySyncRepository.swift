import Foundation
import os
import SwiftData

/// Counts SwiftData saves from every context (autosave included), so an
/// unchanged library can reuse its last seed instead of refetching every row.
final class LibrarySyncSaveCounter: @unchecked Sendable {
    private let count = OSAllocatedUnfairLock(initialState: 0)
    private var observer: (any NSObjectProtocol)? // Only touched in init and deinit.

    init() {
        observer = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: nil) { [count] _ in
            count.withLock { $0 += 1 }
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    var value: Int { count.withLock { $0 } }
}

/// Builds seeds from a fresh private model context, so reading the whole library
/// never blocks the main thread. It only sees saved data; callers save first.
actor LibrarySyncSeedReader {
    let container: ModelContainer
    let root: URL

    init(container: ModelContainer, root: URL) { self.container = container; self.root = root }

    func seed(excluding paperIDs: Set<UUID>, writings: Set<UUID>) throws -> LibrarySyncSeed {
        // A new context per seed: a long-lived one would return its stale registered rows.
        let context = ModelContext(container)
        let papers = Dictionary(try context.fetch(FetchDescriptor<Paper>()).map { ($0.id, $0) }) { first, _ in first }
        let attachments = try context.fetch(FetchDescriptor<PaperAttachment>())
        let folders = try context.fetch(FetchDescriptor<PaperFolder>())
        let memberships = Dictionary(try context.fetch(FetchDescriptor<PaperFolderMembership>()).map { ($0.paperID, $0) }) { first, _ in first }
        let itemTypes = Dictionary(try context.fetch(FetchDescriptor<PaperItemTypeAssignment>()).map { ($0.paperID, $0) }) { first, _ in first }
        let notes = try context.fetch(FetchDescriptor<Note>())
        var readings: [UUID: ReadingState] = [:]
        for state in try context.fetch(FetchDescriptor<ReadingState>()).sorted(by: { $0.modifiedAt > $1.modifiedAt }) where readings[state.paperID] == nil {
            readings[state.paperID] = state
        }
        let segments = Dictionary(grouping: try context.fetch(FetchDescriptor<TranslationSegment>()), by: \.paperID)
        var documents = papers.values.map { LibrarySyncDocument(content: .paper(Self.paper($0))) }
        documents += folders.map { .init(content: .folder(.init(id: $0.id, name: $0.name, parentID: $0.parentID, createdAt: $0.createdAt, modifiedAt: $0.modifiedAt))) }
        documents += memberships.values.map { .init(content: .membership(.init(paperID: $0.paperID, folderID: $0.folderID, addedAt: $0.addedAt))) }
        documents += itemTypes.values.map { .init(content: .itemType(.init(paperID: $0.paperID, rawValue: $0.itemTypeRawValue, assignedAt: $0.assignedAt))) }
        documents += notes.map { .init(content: .note(.init(id: $0.id, paperID: $0.paperID, attachmentID: $0.attachmentID, quote: $0.quote, body: $0.body, pageIndex: $0.pageIndex, htmlSelector: $0.htmlSelector, createdAt: $0.createdAt, modifiedAt: $0.modifiedAt))) }
        documents += readings.values.map { .init(content: .reading(.init(paperID: $0.paperID, attachmentID: $0.attachmentID, readerMode: $0.readerModeRawValue, pageIndex: $0.pageIndex, scrollRatio: $0.scrollRatio, htmlAnchor: $0.htmlAnchor, modifiedAt: $0.modifiedAt))) }
        for (paperID, rows) in segments {
            let values = rows.map(Self.translation)
            // A cache key can have duplicates from older versions; export only its latest value.
            let unique = Dictionary(grouping: values, by: \.cacheKey).compactMap { $0.value.max { $0.modifiedAt < $1.modifiedAt } }.sorted { $0.cacheKey < $1.cacheKey }
            documents.append(.init(content: .translations(.init(paperID: paperID, segments: unique))))
        }
        documents = documents.filter { $0.scope.paperID.map { papers[$0] != nil && !paperIDs.contains($0) } ?? true }.sorted { $0.key < $1.key }
        let fileStore = PaperFileStore(applicationSupportDirectory: root)
        let seeds: [LibrarySyncAttachmentSeed] = attachments.filter { !paperIDs.contains($0.paperID) && papers[$0.paperID] != nil && !Self.isDeviceLocal($0) }.map { value in
            let url = value.resolvedFileURL(fileStore: fileStore)
            let relative = try? LibrarySyncPaths.relative(url, root: root, scope: .init(paperID: value.paperID))
            return .init(value: .init(id: value.id, paperID: value.paperID, kind: value.kindRawValue, source: value.sourceRawValue, filename: value.filename, file: .init(relativePath: relative ?? "", hash: "", size: 0), translatedLastPage: value.translatedLastPage, createdAt: value.createdAt), url: url, isManaged: relative != nil)
        }.sorted { $0.value.id.librarySyncID < $1.value.id.librarySyncID }
        return LibrarySyncSeed(documents: documents, attachments: seeds, paperIDs: papers.keys.filter { !paperIDs.contains($0) }.sorted { $0.librarySyncID < $1.librarySyncID }, blockedWritingIDs: writings)
    }

    /// The translated LaTeX project is a build folder kept next to its PDF. Only
    /// the PDF syncs; the folder stays on the device that compiled it.
    static func isDeviceLocal(_ attachment: PaperAttachment) -> Bool {
        attachment.kindRawValue == AttachmentKind.resource.rawValue && attachment.sourceRawValue == AttachmentSource.latexTrans.rawValue
    }

    static func translation(_ row: TranslationSegment) -> LibrarySyncTranslation {
        .init(id: row.id, sourceType: row.sourceType, targetLanguage: row.targetLanguage, sourceHash: row.sourceHash, sourceText: row.sourceText, translatedText: row.translatedText, modelName: row.modelName, createdAt: row.createdAt, modifiedAt: row.modifiedAt, providerProfileID: row.providerProfileID, modelProfileID: row.modelProfileID)
    }

    private static func paper(_ value: Paper) -> LibrarySyncPaper {
        .init(id: value.id, arxivID: value.arxivID, arxivVersion: value.arxivVersion, doi: value.doi, title: value.title, abstractText: value.abstractText, authorsStorage: value.authorsStorage, categoriesStorage: value.categoriesStorage, publishedAt: value.publishedAt, updatedAt: value.updatedAt, pdfURLString: value.pdfURLString, htmlURLString: value.htmlURLString, tagsStorage: value.tagsStorage, isFavorite: value.isFavorite, createdAt: value.createdAt, modifiedAt: value.modifiedAt)
    }
}

/// Applies remote changes on the main context. Rows are looked up one at a time
/// when they are written; the full library is only read by `LibrarySyncSeedReader`.
@MainActor
final class LibrarySyncRepository {
    let context: ModelContext
    let root: URL
    let notifyOpenDocuments: Bool
    private let reader: LibrarySyncSeedReader
    private let saves = LibrarySyncSaveCounter()
    private var cachedSeed: (seed: LibrarySyncSeed, generation: Int, papers: Set<UUID>, writings: Set<UUID>, date: Date)?

    /// Changes whenever any context saves. Equal values mean no saved model changed.
    var generation: Int { saves.value }

    init(container: ModelContainer, root: URL, notifyOpenDocuments: Bool = false) {
        context = container.mainContext; self.root = root; self.notifyOpenDocuments = notifyOpenDocuments
        reader = .init(container: container, root: root)
    }

    /// Reflects saved data only. Unsaved main-context edits are the caller's concern.
    func seed(excluding paperIDs: Set<UUID> = [], writings: Set<UUID> = []) async throws -> LibrarySyncSeed {
        // The age limit only bounds the damage of a save that somehow posts nothing.
        if let cached = cachedSeed, cached.generation == generation,
           cached.papers == paperIDs, cached.writings == writings, Date().timeIntervalSince(cached.date) < 300 {
            return cached.seed
        }
        let startGeneration = generation
        let seed = try await reader.seed(excluding: paperIDs, writings: writings)
        cachedSeed = (seed, startGeneration, paperIDs, writings, Date())
        return seed
    }

    private func first<Model: PersistentModel>(_ predicate: Predicate<Model>, sortBy: [SortDescriptor<Model>] = []) throws -> Model? {
        var descriptor = FetchDescriptor(predicate: predicate, sortBy: sortBy)
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func paperExists(_ id: UUID) -> Bool {
        ((try? context.fetchCount(FetchDescriptor<Paper>(predicate: #Predicate { $0.id == id }))) ?? 0) > 0
    }

    func canApply(_ document: LibrarySyncDocument, creating papersInBatch: Set<UUID>, writings: Set<UUID>) -> Bool {
        if case .paper = document.content { return true }
        if case .folder = document.content { return true }
        if case .writing = document.content { return true }
        if let id = document.scope.paperID { return papersInBatch.contains(id) || paperExists(id) }
        if let id = document.scope.writingID { return writings.contains(id) || FileManager.default.fileExists(atPath: root.appendingPathComponent("Writings/" + id.uuidString + "/writing.md").path) }
        return true
    }

    struct Change {
        var record: LibrarySyncRecord
        var document: LibrarySyncDocument?
        var previous: LibrarySyncDocument?
        var files: [LibrarySyncPreparedFile]
    }

    /// Download/copy work happens before this call. Model and file publication are
    /// synchronous on the main actor; save once, then notify open readers once.
    /// Returns whether the model context was saved.
    @discardableResult
    func apply(_ changes: [Change]) throws -> Bool {
        guard !changes.isEmpty else { return false }
        let manager = FileManager.default
        let recovery = root.appendingPathComponent("Sync/Recovery/" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: recovery, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var undo: [(destination: URL, backup: URL?)] = []
        var moved: [(original: URL, backup: URL)] = []
        var changedPapers = Set<UUID>()
        var changedWritings = Set<UUID>()
        let deletedPapers = Set(changes.compactMap { change -> UUID? in
            guard change.record.deleted, case .paper(let paper)? = change.previous?.content else { return nil }
            return paper.id
        })
        var annotationGroups: [UUID: (paperID: UUID, records: [UUID: PDFAnnotationRecord])] = [:]
        var saved = false
        let annotationStore = PDFAnnotationStore(fileStore: PaperFileStore(applicationSupportDirectory: root))
        for change in changes {
            let content = change.record.deleted ? change.previous?.content : change.document?.content
            guard case .annotation(let value)? = content, !deletedPapers.contains(value.paperID) else { continue }
            if annotationGroups[value.attachmentID] == nil {
                let existing = try annotationStore.load(paperID: value.paperID, attachmentID: value.attachmentID)
                annotationGroups[value.attachmentID] = (value.paperID, Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) }))
            }
            annotationGroups[value.attachmentID]?.records[value.annotation.id] = change.record.deleted ? nil : value.annotation
        }
        do {
            for (attachmentID, group) in annotationGroups {
                let destination = try annotationStore.sidecarURL(paperID: group.paperID, attachmentID: attachmentID)
                var backup: URL?
                if manager.fileExists(atPath: destination.path) {
                    backup = recovery.appendingPathComponent(UUID().uuidString)
                    try manager.linkItem(at: destination, to: backup!)
                }
                undo.append((destination, backup))
                try annotationStore.save(Array(group.records.values), paperID: group.paperID, attachmentID: attachmentID)
            }
            for change in changes {
                for file in change.files {
                    // Revalidate every path immediately before publication, after all awaits.
                    if let document = change.document {
                        for value in document.files { _ = try LibrarySyncPaths.file(root: root, scope: document.scope, path: value.relativePath) }
                    }
                    var backup: URL?
                    if manager.fileExists(atPath: file.destination.path) {
                        backup = recovery.appendingPathComponent(UUID().uuidString)
                        try manager.linkItem(at: file.destination, to: backup!)
                    }
                    try LibrarySyncPaths.rename(file.temporary, to: file.destination)
                    undo.append((file.destination, backup))
                }
                if change.record.deleted {
                    if let previous = change.previous {
                        try remove(previous, recovery: recovery, moved: &moved)
                        if let id = previous.scope.paperID { changedPapers.insert(id) }
                        if let id = previous.scope.writingID { changedWritings.insert(id) }
                    }
                } else if let document = change.document {
                    try upsert(document)
                    switch document.content {
                    case .attachment, .annotation, .resource:
                        if let id = document.scope.paperID { changedPapers.insert(id) }
                        if let id = document.scope.writingID { changedWritings.insert(id) }
                    case .writing(let writing): changedWritings.insert(writing.id)
                    default: break
                    }
                }
            }
            if context.hasChanges { try context.save(); saved = true }
            // Deletions are kept in Recovery. Rollback links for successful replacements
            // can be discarded; a crash before here leaves a recoverable old version.
            for (_, backup) in undo { if let backup { try? manager.removeItem(at: backup) } }
            if (try? manager.contentsOfDirectory(atPath: recovery.path).isEmpty) == true { try? manager.removeItem(at: recovery) }
        } catch {
            context.rollback()
            for item in moved.reversed() { try? manager.moveItem(at: item.backup, to: item.original) }
            for item in undo.reversed() {
                if let backup = item.backup { try? LibrarySyncPaths.rename(backup, to: item.destination) }
                else { try? manager.removeItem(at: item.destination) }
            }
            throw error
        }
        if notifyOpenDocuments, !changedWritings.isEmpty {
            WritingLibrary.shared.reload()
            #if os(macOS)
            WritingDocumentCenter.shared.reloadAfterSync(changedWritings)
            #else
            IPadWritingDocumentCenter.shared.reloadAfterSync(changedWritings)
            #endif
        }
        if notifyOpenDocuments, !changedPapers.isEmpty {
            NotificationCenter.default.post(name: .librarySyncDidApply, object: nil, userInfo: ["paperIDs": changedPapers])
        }
        return saved
    }

    private func upsert(_ document: LibrarySyncDocument) throws {
        switch document.content {
        case .paper(let v):
            let id = v.id
            let row = try first(#Predicate<Paper> { $0.id == id }) ?? { let row = Paper(id: v.id, title: v.title); context.insert(row); return row }()
            row.arxivID = v.arxivID; row.arxivVersion = v.arxivVersion; row.doi = v.doi
            row.title = v.title; row.abstractText = v.abstractText; row.authorsStorage = v.authorsStorage
            row.categoriesStorage = v.categoriesStorage; row.publishedAt = v.publishedAt; row.updatedAt = v.updatedAt
            row.pdfURLString = v.pdfURLString; row.htmlURLString = v.htmlURLString; row.tagsStorage = v.tagsStorage
            row.isFavorite = v.isFavorite; row.createdAt = v.createdAt; row.modifiedAt = v.modifiedAt
            row.localDirectoryPath = try PaperFileStore(applicationSupportDirectory: root).directory(for: v.id).path
        case .attachment(let v):
            let url = try LibrarySyncPaths.file(root: root, scope: .init(paperID: v.paperID), path: v.file.relativePath)
            let id = v.id
            let row = try first(#Predicate<PaperAttachment> { $0.id == id }) ?? {
                let row = PaperAttachment(id: v.id, paperID: v.paperID, kind: AttachmentKind(rawValue: v.kind) ?? .resource, source: AttachmentSource(rawValue: v.source) ?? .generated, filename: v.filename, filePath: url.path)
                context.insert(row); return row
            }()
            row.paperID = v.paperID; row.kindRawValue = v.kind; row.sourceRawValue = v.source
            row.filename = v.filename; row.filePath = url.path; row.translatedLastPage = v.translatedLastPage; row.createdAt = v.createdAt
        case .folder(let v):
            let id = v.id
            let row = try first(#Predicate<PaperFolder> { $0.id == id }) ?? { let row = PaperFolder(id: v.id, name: v.name); context.insert(row); return row }()
            row.name = v.name; row.parentID = v.parentID; row.createdAt = v.createdAt; row.modifiedAt = v.modifiedAt
        case .membership(let v):
            let paperID = v.paperID
            let row = try first(#Predicate<PaperFolderMembership> { $0.paperID == paperID }) ?? {
                let row = PaperFolderMembership(paperID: v.paperID, folderID: v.folderID); context.insert(row); return row
            }()
            row.folderID = v.folderID; row.addedAt = v.addedAt
        case .itemType(let v):
            let paperID = v.paperID
            let row = try first(#Predicate<PaperItemTypeAssignment> { $0.paperID == paperID }) ?? {
                let row = PaperItemTypeAssignment(paperID: v.paperID, itemType: PaperItemType(rawValue: v.rawValue) ?? .document); context.insert(row); return row
            }()
            row.itemTypeRawValue = v.rawValue; row.assignedAt = v.assignedAt
        case .note(let v):
            let id = v.id
            let row = try first(#Predicate<Note> { $0.id == id }) ?? { let row = Note(id: v.id, paperID: v.paperID); context.insert(row); return row }()
            row.paperID = v.paperID; row.attachmentID = v.attachmentID; row.quote = v.quote; row.body = v.body
            row.pageIndex = v.pageIndex; row.htmlSelector = v.htmlSelector; row.createdAt = v.createdAt; row.modifiedAt = v.modifiedAt
        case .reading(let v):
            // The seed exports a paper's latest row, so that is the one to update.
            let paperID = v.paperID
            let row = try first(#Predicate<ReadingState> { $0.paperID == paperID }, sortBy: [SortDescriptor(\.modifiedAt, order: .reverse)]) ?? {
                let row = ReadingState(paperID: v.paperID); context.insert(row); return row
            }()
            row.attachmentID = v.attachmentID; row.readerModeRawValue = v.readerMode; row.pageIndex = max(0, v.pageIndex)
            row.scrollRatio = ReadingStateStore.clampedScrollRatio(v.scrollRatio); row.htmlAnchor = v.htmlAnchor; row.modifiedAt = v.modifiedAt
        case .translations(let v):
            // Match by ID first, then by the full cache identity including the
            // route, so one model's text never lands in another model's row and
            // no two rows end up sharing an ID.
            let paperID = v.paperID
            let rows = try context.fetch(FetchDescriptor<TranslationSegment>(predicate: #Predicate { $0.paperID == paperID }))
            let byID = Dictionary(rows.map { ($0.id, $0) }) { first, _ in first }
            let byKey = Dictionary(grouping: rows) { LibrarySyncSeedReader.translation($0).cacheKey }
            var kept = Set<ObjectIdentifier>()
            for value in v.segments {
                let unused = { (row: TranslationSegment) in !kept.contains(ObjectIdentifier(row)) }
                let row: TranslationSegment
                if let match = byID[value.id].flatMap({ unused($0) ? $0 : nil }) ?? byKey[value.cacheKey]?.first(where: unused) {
                    row = match
                } else {
                    row = TranslationSegment(id: value.id, paperID: v.paperID, sourceType: value.sourceType, targetLanguage: value.targetLanguage, sourceHash: value.sourceHash, sourceText: value.sourceText, translatedText: value.translatedText, modelName: value.modelName)
                    context.insert(row)
                }
                row.id = value.id; row.sourceType = value.sourceType; row.targetLanguage = value.targetLanguage; row.sourceHash = value.sourceHash
                row.sourceText = value.sourceText; row.translatedText = value.translatedText
                row.providerProfileID = value.providerProfileID; row.modelProfileID = value.modelProfileID; row.modelName = value.modelName
                row.createdAt = value.createdAt; row.modifiedAt = value.modifiedAt
                kept.insert(ObjectIdentifier(row))
            }
            for row in rows where !kept.contains(ObjectIdentifier(row)) { context.delete(row) }
        case .annotation: break // Sidecars are written once per attachment and batch.
        case .resource: break // Already atomically installed above.
        case .writing(let v):
            let store = WritingStore(fileStore: PaperFileStore(applicationSupportDirectory: root))
            try store.refreshSyncedMetadata(for: v.id, createdAt: v.createdAt, modifiedAt: v.modifiedAt)
            // meta.json freshness is measured against the Markdown's timestamp.
            // A download must not look like a new local edit just because it arrived today.
            try FileManager.default.setAttributes([.modificationDate: v.modifiedAt], ofItemAtPath: store.markdownURL(for: v.id).path)
        }
    }

    private func remove(_ document: LibrarySyncDocument, recovery: URL, moved: inout [(original: URL, backup: URL)]) throws {
        func preserve(_ url: URL) throws {
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            let destination = recovery.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: destination)
            moved.append((url, destination))
        }
        switch document.content {
        case .paper(let v):
            try preserve(LibrarySyncPaths.directory(root: root, scope: .init(paperID: v.id)))
            let id = v.id
            if let row = try first(#Predicate<Paper> { $0.id == id }) { try PaperDeletionService.deleteRecords(of: row, in: context) }
        case .attachment(let v):
            let id = v.id
            if let row = try first(#Predicate<PaperAttachment> { $0.id == id }) { context.delete(row) }
        case .folder(let v):
            let id = v.id
            if let row = try first(#Predicate<PaperFolder> { $0.id == id }) { context.delete(row) }
        case .membership(let v):
            let paperID = v.paperID
            try context.fetch(FetchDescriptor<PaperFolderMembership>(predicate: #Predicate { $0.paperID == paperID })).forEach(context.delete)
        case .itemType(let v):
            let paperID = v.paperID
            try context.fetch(FetchDescriptor<PaperItemTypeAssignment>(predicate: #Predicate { $0.paperID == paperID })).forEach(context.delete)
        case .note(let v):
            let id = v.id
            if let row = try first(#Predicate<Note> { $0.id == id }) { context.delete(row) }
        case .reading(let v):
            let paperID = v.paperID
            try context.fetch(FetchDescriptor<ReadingState>(predicate: #Predicate { $0.paperID == paperID })).forEach(context.delete)
        case .translations(let v):
            let paperID = v.paperID
            try context.fetch(FetchDescriptor<TranslationSegment>(predicate: #Predicate { $0.paperID == paperID })).forEach(context.delete)
        case .annotation: break
        case .resource(let v): try preserve(LibrarySyncPaths.file(root: root, scope: v.scope, path: v.file.relativePath))
        case .writing(let v): try preserve(LibrarySyncPaths.directory(root: root, scope: .init(writingID: v.id)))
        }
    }
}
