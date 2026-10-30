import Foundation
import SwiftData
import PDFKit
import XCTest
#if os(macOS)
@testable import ReadPaper
#else
@testable import ReadPaperiPad
#endif

private actor SyncTestServer {
    var storeID = UUID().uuidString
    let libraryID = UUID().uuidString
    var records: [String: LibrarySyncRecord] = [:]
    var history: [LibrarySyncRecord] = []
    var blobs: [String: Data] = [:]
    var receipts: [String: LibrarySyncReceipt] = [:]
    var offline = false
    var loseNextCommitResponse = false
    var successfulPushes = 0
    var rejectNextPush = false
    var rejectedRequests: Set<String> = []
    var beforeNextPush: (@Sendable () async -> Void)?
    var onTransfer: (@Sendable () async -> Void)?

    func setOffline(_ value: Bool) { offline = value }
    func loseResponse() { loseNextCommitResponse = true }
    func rejectPush() { rejectNextPush = true }
    func setBeforeNextPush(_ hook: @escaping @Sendable () async -> Void) { beforeNextPush = hook }
    func setOnTransfer(_ hook: (@Sendable () async -> Void)?) { onTransfer = hook }
    func replaceHistory() { storeID = UUID().uuidString; records = [:]; history = []; receipts = [:] }
    func recordCount() -> Int { records.count }
    func pushCount() -> Int { successfulPushes }
    func liveRecords() -> [LibrarySyncRecord] { records.values.filter { !$0.deleted } }
    private func online() throws { if offline { throw URLError(.notConnectedToInternet) } }

    func info(_ deviceID: String) throws -> LibrarySyncInfo {
        try online()
        return .init(protocolVersion: 1, storeID: storeID, libraryID: libraryID, deviceID: deviceID)
    }
    func changes(after: UInt64, until: UInt64?) throws -> LibrarySyncPage {
        try online()
        let head = UInt64(history.count)
        guard after <= head else { throw LibrarySyncError.server(status: 409, code: "invalid_cursor", retryAfter: nil) }
        let matches = history.filter { $0.revision > after && $0.revision <= (until ?? head) }
        let page = Array(matches.prefix(7)) // Deliberately force pagination in ordinary tests.
        return .init(changes: page, cursor: page.last?.revision ?? after, headRevision: head, hasMore: matches.count > page.count)
    }
    func push(_ push: LibrarySyncPush, deviceID: String) async throws -> LibrarySyncReceipt {
        try online()
        if let hook = beforeNextPush { beforeNextPush = nil; await hook() }
        await onTransfer?()
        let requestKey = deviceID + "/" + push.requestID
        if rejectedRequests.contains(requestKey) {
            throw LibrarySyncError.server(status: 409, code: "request_id_reused", retryAfter: nil)
        }
        if rejectNextPush {
            // Like a rolled-back quota failure whose request can never be replayed.
            rejectNextPush = false; rejectedRequests.insert(requestKey)
            throw LibrarySyncError.server(status: 507, code: "metadata_quota_exceeded", retryAfter: nil)
        }
        if let previous = receipts[requestKey] { return previous }
        for mutation in push.mutations {
            let current = records[mutation.key]
            if (current?.revision ?? 0) != mutation.baseRevision || (current?.deleted == true && !mutation.restore) {
                throw LibrarySyncError.conflict(current)
            }
            for hash in mutation.blobs where blobs[hash] == nil {
                throw LibrarySyncError.server(status: 409, code: "missing_blob", retryAfter: nil)
            }
        }
        var revisions: [UInt64] = []
        for mutation in push.mutations {
            let revision = UInt64(history.count + 1)
            let record = LibrarySyncRecord(kind: mutation.kind, id: mutation.id, revision: revision, deleted: mutation.deleted, payload: mutation.payload, blobs: mutation.blobs, deviceID: deviceID, updatedAt: "2026-10-30T00:00:00Z")
            records[mutation.key] = record; history.append(record); revisions.append(revision)
        }
        let receipt = LibrarySyncReceipt(requestID: push.requestID, revisions: revisions)
        receipts[requestKey] = receipt; successfulPushes += 1
        if loseNextCommitResponse { loseNextCommitResponse = false; throw URLError(.networkConnectionLost) }
        return receipt
    }
    func hasBlob(_ hash: String) throws -> Bool { try online(); return blobs[hash] != nil }
    func upload(_ file: URL, hash: String) throws {
        try online()
        let data = try Data(contentsOf: file)
        guard Hashing.sha256Hex(data) == hash else { throw LibrarySyncError.message("Test upload hash mismatch") }
        blobs[hash] = data
    }
    func download(_ hash: String) async throws -> URL {
        try online()
        await onTransfer?()
        guard let data = blobs[hash] else { throw URLError(.fileDoesNotExist) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("sync-download-" + UUID().uuidString)
        try data.write(to: file)
        return file
    }
}

private struct SyncTestTransport: LibrarySyncTransport {
    let server: SyncTestServer
    let deviceID: String
    func info() async throws -> LibrarySyncInfo { try await server.info(deviceID) }
    func changes(after: UInt64, until: UInt64?) async throws -> LibrarySyncPage { try await server.changes(after: after, until: until) }
    func push(_ request: LibrarySyncPush) async throws -> LibrarySyncReceipt { try await server.push(request, deviceID: deviceID) }
    func hasBlob(_ hash: String) async throws -> Bool { try await server.hasBlob(hash) }
    func upload(_ file: URL, hash: String) async throws { try await server.upload(file, hash: hash) }
    func download(_ hash: String) async throws -> URL { try await server.download(hash) }
}

@MainActor
private final class SyncTestVault: LibrarySyncCredentialStorage {
    var values: [String: String] = [:]
    func save(_ token: String, account: String) throws { values[account] = token }
    func load(account: String) throws -> String? { values[account] }
}

@MainActor
final class LibrarySyncTests: XCTestCase {
    @MainActor private struct Device {
        var root: URL
        var container: ModelContainer
        var vault: SyncTestVault
        var controller: LibrarySyncController
        var context: ModelContext { container.mainContext }
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LibrarySyncTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func device(server: SyncTestServer, notifyOpenDocuments: Bool = false) async throws -> Device {
        let root = try temporaryDirectory()
        let schema = ReadPaperModelStore.schema
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let vault = SyncTestVault(), id = UUID().librarySyncID
        let controller = LibrarySyncController(root: root, vault: vault, notifyOpenDocuments: notifyOpenDocuments) { _, _ in SyncTestTransport(server: server, deviceID: id) }
        controller.start(modelContainer: container, automatically: false)
        let info = try await server.info(id)
        let credential = try JSONSerialization.data(withJSONObject: [
            "baseURL": "https://sync.example/freddie-sync/", "token": "fs1_" + String(repeating: "a", count: 64),
            "device": ["id": id, "libraryID": info.libraryID, "label": "Test device"]
        ])
        await controller.connect(credentialData: credential)
        XCTAssertNil(controller.errorMessage)
        return Device(root: root, container: container, vault: vault, controller: controller)
    }

    @discardableResult
    private func addPaper(_ device: Device, title: String = "A paper") throws -> (Paper, PaperAttachment) {
        let paper = Paper(title: title, authors: ["Author"], isFavorite: false)
        let store = PaperFileStore(applicationSupportDirectory: device.root)
        let file = try store.write(Data("%PDF-1.7\nOffline fixture".utf8), named: "paper.pdf", for: paper.id)
        paper.localDirectoryPath = file.deletingLastPathComponent().path
        let attachment = PaperAttachment(paperID: paper.id, kind: .pdf, source: .localImport, filename: "paper.pdf", filePath: file.path)
        device.context.insert(paper); device.context.insert(attachment)
        try device.context.save()
        return (paper, attachment)
    }

    private func sync(_ device: Device, file: StaticString = #filePath, line: UInt = #line) async {
        await device.controller.syncNow()
        XCTAssertNil(device.controller.errorMessage, file: file, line: line)
    }

    func testTwoDevicesSyncMetadataFilesFoldersNotesAnnotationsAndWritings() async throws {
        let server = SyncTestServer(), a = try await device(server: server), b = try await device(server: server)
        let (paper, attachment) = try addPaper(a)
        let folder = PaperFolder(name: "Research")
        a.context.insert(folder)
        a.context.insert(PaperFolderMembership(paperID: paper.id, folderID: folder.id))
        a.context.insert(PaperItemTypeAssignment(paperID: paper.id, itemType: .journalArticle))
        a.context.insert(Note(paperID: paper.id, attachmentID: attachment.id, quote: "source", body: "note", pageIndex: 2))
        a.context.insert(ReadingState(paperID: paper.id, attachmentID: attachment.id, readerMode: .pdf, pageIndex: 4, scrollRatio: 0.4, zoomScale: 2))
        a.context.insert(TranslationSegment(paperID: paper.id, sourceType: "html", targetLanguage: "zh-CN", sourceHash: "source", sourceText: "source", translatedText: "译文", modelName: "test-model"))
        try a.context.save()
        let ink = PDFAnnotationRecord(pageIndex: 0, kind: .ink, bounds: CGRect(x: 1, y: 2, width: 30, height: 10), color: PDFAnnotationColorPreset.purple.color(for: .ink),
                                      inkPaths: [[CGPoint(x: 1, y: 2), CGPoint(x: 3, y: 4)]],
                                      inkSamplePaths: [[.init(point: CGPoint(x: 1, y: 2), width: 0.5), .init(point: CGPoint(x: 3, y: 4), width: 1.2)]])
        let annotationsA = PDFAnnotationStore(fileStore: .init(applicationSupportDirectory: a.root))
        try annotationsA.save([ink], paperID: paper.id, attachmentID: attachment.id)
        let writingsA = WritingStore(fileStore: .init(applicationSupportDirectory: a.root))
        let writing = try writingsA.create(markdown: "# My writing\n\nSome notes.\n\n![image](assets/image.png)")
        let assets = try writingsA.directory(for: writing.id).appendingPathComponent("assets")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try Data([1, 2, 3, 4]).write(to: assets.appendingPathComponent("image.png"))
        await sync(a); await sync(b)
        let remotePaper = try XCTUnwrap(b.context.fetch(FetchDescriptor<Paper>()).first)
        XCTAssertEqual(remotePaper.id, paper.id); XCTAssertEqual(remotePaper.title, paper.title)
        XCTAssertFalse(remotePaper.localDirectoryPath.contains(a.root.lastPathComponent))
        let remoteAttachment = try XCTUnwrap(b.context.fetch(FetchDescriptor<PaperAttachment>()).first)
        XCTAssertEqual(remoteAttachment.id, attachment.id)
        XCTAssertEqual(try Data(contentsOf: remoteAttachment.resolvedFileURL(fileStore: .init(applicationSupportDirectory: b.root))), Data("%PDF-1.7\nOffline fixture".utf8))
        XCTAssertEqual(try b.context.fetch(FetchDescriptor<PaperFolder>()).first?.name, "Research")
        XCTAssertEqual(try b.context.fetch(FetchDescriptor<PaperFolderMembership>()).first?.folderID, folder.id)
        XCTAssertEqual(try b.context.fetch(FetchDescriptor<PaperItemTypeAssignment>()).first?.itemType, .journalArticle)
        XCTAssertEqual(try b.context.fetch(FetchDescriptor<Note>()).first?.body, "note")
        let position = try XCTUnwrap(b.context.fetch(FetchDescriptor<ReadingState>()).first)
        XCTAssertEqual(position.pageIndex, 4); XCTAssertEqual(position.zoomScale, 1, "Zoom is a device preference")
        XCTAssertEqual(try b.context.fetch(FetchDescriptor<TranslationSegment>()).first?.translatedText, "译文")
        let annotationsB = PDFAnnotationStore(fileStore: .init(applicationSupportDirectory: b.root))
        XCTAssertEqual(try annotationsA.load(paperID: paper.id, attachmentID: attachment.id), try annotationsB.load(paperID: paper.id, attachmentID: attachment.id))
        let writingsB = WritingStore(fileStore: .init(applicationSupportDirectory: b.root))
        XCTAssertEqual(try writingsA.loadMarkdown(for: writing.id), try writingsB.loadMarkdown(for: writing.id))
        XCTAssertEqual(try Data(contentsOf: writingsB.directory(for: writing.id).appendingPathComponent("assets/image.png")), Data([1, 2, 3, 4]))
        let pushes = await server.pushCount()
        await sync(a); await sync(b)
        let unchangedPushes = await server.pushCount()
        XCTAssertEqual(pushes, unchangedPushes, "Applying remote data must not generate an endless echo")
    }

    func testOfflineChangesAreDurableAndFavoriteDoesNotReorderPaper() async throws {
        let server = SyncTestServer(), a = try await device(server: server), b = try await device(server: server)
        let (paper, _) = try addPaper(a)
        await sync(a); await sync(b)
        let modified = paper.modifiedAt
        await server.setOffline(true)
        paper.isFavorite = true; try a.context.save()
        await a.controller.syncNow()
        XCTAssertNotNil(a.controller.errorMessage)
        let configuration = try XCTUnwrap(a.controller.configuration)
        let state = try LibrarySyncStateStore(root: a.root).load(configuration)
        XCTAssertTrue(state.outbox.contains { $0.kind == "paper" })
        await server.setOffline(false)
        await sync(a); await sync(b)
        XCTAssertEqual(try b.context.fetch(FetchDescriptor<Paper>()).first?.isFavorite, true)
        XCTAssertEqual(Int64(modified.timeIntervalSince1970 * 1000), Int64(paper.modifiedAt.timeIntervalSince1970 * 1000))
    }

    func testLostCommitResponseReplaysExactRequestAfterClientRestart() async throws {
        let server = SyncTestServer(), a = try await device(server: server)
        try addPaper(a)
        await server.loseResponse()
        await a.controller.syncNow()
        XCTAssertNotNil(a.controller.errorMessage)
        let configuration = try XCTUnwrap(a.controller.configuration)
        let pending = try LibrarySyncStateStore(root: a.root).load(configuration).inFlight
        XCTAssertNotNil(pending)
        let count = await server.recordCount()
        let id = configuration.deviceID
        let restarted = LibrarySyncController(root: a.root, vault: a.vault) { _, _ in SyncTestTransport(server: server, deviceID: id) }
        restarted.start(modelContainer: a.container, automatically: false)
        await restarted.syncNow()
        XCTAssertNil(restarted.errorMessage)
        let after = await server.recordCount()
        XCTAssertEqual(count, after)
        XCTAssertNil(try LibrarySyncStateStore(root: a.root).load(configuration).inFlight)
    }

    func testConcurrentPaperEditsMergeDifferentFieldsAndPreserveSameFieldConflicts() async throws {
        let server = SyncTestServer(), a = try await device(server: server), b = try await device(server: server)
        let (paperA, _) = try addPaper(a)
        await sync(a); await sync(b)
        let paperB = try XCTUnwrap(b.context.fetch(FetchDescriptor<Paper>()).first)
        paperA.isFavorite = true
        paperB.title = "New title"
        try a.context.save(); try b.context.save()
        await sync(a); await sync(b); await sync(a)
        XCTAssertTrue(paperB.isFavorite); XCTAssertEqual(paperA.title, "New title")
        XCTAssertTrue(b.controller.conflicts.isEmpty)
        paperA.title = "Title A"; paperB.title = "Title B"
        try a.context.save(); try b.context.save()
        await sync(a); await sync(b)
        XCTAssertEqual(paperB.title, "Title B")
        XCTAssertEqual(b.controller.conflicts.count, 1)
        let conflict = try XCTUnwrap(b.controller.conflicts.first)
        await b.controller.resolve(conflict.id, choice: .thisDevice)
        XCTAssertNil(b.controller.errorMessage)
        await sync(a)
        XCTAssertEqual(paperA.title, "Title B")
    }

    func testDeletingPaperAndAnnotationsPropagatesWithoutDeletingWritings() async throws {
        let server = SyncTestServer(), a = try await device(server: server), b = try await device(server: server)
        let (paper, attachment) = try addPaper(a)
        let store = PDFAnnotationStore(fileStore: .init(applicationSupportDirectory: a.root))
        let record = PDFAnnotationRecord(pageIndex: 0, kind: .highlight, bounds: CGRect(x: 1, y: 1, width: 10, height: 10), color: PDFAnnotationColorPreset.yellow.color(for: .highlight))
        try store.save([record], paperID: paper.id, attachmentID: attachment.id)
        let writings = WritingStore(fileStore: .init(applicationSupportDirectory: a.root))
        let writing = try writings.create(markdown: "# Keep this writing")
        await sync(a); await sync(b)
        try store.save([], paperID: paper.id, attachmentID: attachment.id)
        await sync(a); await sync(b)
        XCTAssertTrue(try PDFAnnotationStore(fileStore: .init(applicationSupportDirectory: b.root)).load(paperID: paper.id, attachmentID: attachment.id).isEmpty)
        try PaperDeletionService(fileStore: .init(applicationSupportDirectory: a.root)).delete(paper, modelContext: a.context)
        await sync(a); await sync(b)
        XCTAssertTrue(try b.context.fetch(FetchDescriptor<Paper>()).isEmpty)
        XCTAssertTrue(try b.context.fetch(FetchDescriptor<PaperAttachment>()).isEmpty)
        XCTAssertEqual(try WritingStore(fileStore: .init(applicationSupportDirectory: b.root)).loadMarkdown(for: writing.id), "# Keep this writing")
    }

    func testWritingConflictCanKeepBothWithAssets() async throws {
        let server = SyncTestServer(), a = try await device(server: server), b = try await device(server: server)
        let storeA = WritingStore(fileStore: .init(applicationSupportDirectory: a.root))
        let writing = try storeA.create(markdown: "# Original")
        await sync(a); await sync(b)
        let storeB = WritingStore(fileStore: .init(applicationSupportDirectory: b.root))
        _ = try storeA.save(markdown: "# From A", for: writing.id, createdAt: writing.createdAt)
        _ = try storeB.save(markdown: "# From B", for: writing.id, createdAt: writing.createdAt)
        await sync(a); await sync(b)
        let conflict = try XCTUnwrap(b.controller.conflicts.first)
        await b.controller.resolve(conflict.id, choice: .keepBoth)
        XCTAssertNil(b.controller.errorMessage)
        let all = try storeB.loadAll()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(try storeB.loadMarkdown(for: writing.id), "# From A")
        XCTAssertTrue(all.contains { $0.title.contains("From B") })
        await sync(a)
        XCTAssertEqual(try storeA.loadAll().count, 2)
    }

    func testChangedServerHistoryStopsBeforeUploadingAndKeepsLocalLibrary() async throws {
        let server = SyncTestServer(), a = try await device(server: server)
        try addPaper(a)
        await sync(a)
        await server.replaceHistory()
        await a.controller.syncNow()
        XCTAssertTrue(a.controller.needsHistoryReview)
        XCTAssertNotNil(a.controller.errorMessage)
        XCTAssertEqual(try a.context.fetch(FetchDescriptor<Paper>()).count, 1)
        let count = await server.recordCount()
        XCTAssertEqual(count, 0)
        a.controller.reviewChangedHistory()
        await sync(a)
        let restoredCount = await server.recordCount()
        XCTAssertEqual(restoredCount, 2)
    }

    func testUnsafePathsAndSymlinkEscapesAreRejected() throws {
        let root = try temporaryDirectory(), id = UUID(), scope = LibrarySyncScope(paperID: id)
        for path in ["../outside", "/tmp/file", "Resources/../../outside", "a//b", "a\\b", "a/./b"] {
            XCTAssertThrowsError(try LibrarySyncPaths.file(root: root, scope: scope, path: path), path)
        }
        let directory = try LibrarySyncPaths.directory(root: root, scope: scope)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("escape"), withDestinationURL: root.deletingLastPathComponent())
        XCTAssertThrowsError(try LibrarySyncPaths.file(root: root, scope: scope, path: "escape/private"))
        XCTAssertThrowsError(try LibrarySyncClient.validatedBaseURL(URL(string: "http://sync.example/")!))
        XCTAssertThrowsError(try LibrarySyncClient.validatedBaseURL(URL(string: "https://user:secret@sync.example/")!))
        XCTAssertThrowsError(try LibrarySyncClient.validatedBaseURL(URL(string: "https://sync.example/?token=secret")!))
    }

    func testSyncMessagesUseTheSelectedLanguage() {
        let original = LanguageManager.shared.languageOverride
        defer { LanguageManager.shared.setLanguage(original) }
        LanguageManager.shared.setLanguage("zh-Hans")
        XCTAssertEqual(AppLocalization.localized("Library Sync"), "论文库同步")
        XCTAssertEqual(AppLocalization.localized("Keep Both Writings"), "保留两篇写作稿")
        XCTAssertEqual(LibrarySyncError.message("The synced file path is not safe.").localizedDescription, "同步文件路径不安全。")
        LanguageManager.shared.setLanguage("en")
        XCTAssertEqual(AppLocalization.localized("Library Sync"), "Library Sync")
    }

    func testRemotePaperDeletionKeepsUnsyncedNoteAndAttachmentUntilResolved() async throws {
        let server = SyncTestServer(), a = try await device(server: server), b = try await device(server: server)
        let (paper, _) = try addPaper(a)
        await sync(a); await sync(b)
        let note = Note(paperID: paper.id, body: "Not uploaded yet")
        b.context.insert(note); try b.context.save()
        try PaperDeletionService(fileStore: .init(applicationSupportDirectory: a.root)).delete(paper, modelContext: a.context)
        await sync(a); await sync(b)
        XCTAssertEqual(try b.context.fetch(FetchDescriptor<Paper>()).count, 1)
        XCTAssertEqual(try b.context.fetch(FetchDescriptor<PaperAttachment>()).count, 1)
        XCTAssertEqual(try b.context.fetch(FetchDescriptor<Note>()).first?.body, note.body)
        let conflict = try XCTUnwrap(b.controller.conflicts.first { $0.remote.kind == "paper" })
        await b.controller.resolve(conflict.id, choice: .thisDevice)
        XCTAssertNil(b.controller.errorMessage)
        await sync(a)
        XCTAssertEqual(try a.context.fetch(FetchDescriptor<Paper>()).count, 1)
        XCTAssertEqual(try a.context.fetch(FetchDescriptor<PaperAttachment>()).count, 1)
        XCTAssertEqual(try a.context.fetch(FetchDescriptor<Note>()).first?.body, "Not uploaded yet")
    }

    func testOldWritingDoesNotEchoBecauseOfDownloadTimestamp() async throws {
        let server = SyncTestServer(), a = try await device(server: server), b = try await device(server: server)
        let old = Date(timeIntervalSince1970: 1_600_000_000)
        let store = WritingStore(fileStore: .init(applicationSupportDirectory: a.root))
        let metadata = try store.create(markdown: "# Older writing", now: old)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: store.markdownURL(for: metadata.id).path)
        await sync(a)
        let before = await server.pushCount()
        await sync(b); await sync(a); await sync(b)
        let after = await server.pushCount()
        XCTAssertEqual(before, after)
        let remote = try XCTUnwrap(WritingStore(fileStore: .init(applicationSupportDirectory: b.root)).loadAll().first)
        XCTAssertEqual(remote.modifiedAt, old)
    }

    func testPartialPDFSyncPreservesOriginalReadingPageBeyondTranslatedPages() async throws {
        let server = SyncTestServer(), a = try await device(server: server), b = try await device(server: server)
        let (paper, original) = try addPaper(a)
        func pdf(pages: Int) throws -> Data {
            let data = NSMutableData()
            var box = CGRect(x: 0, y: 0, width: 612, height: 792)
            let consumer = try XCTUnwrap(CGDataConsumer(data: data))
            let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
            for _ in 0..<pages { context.beginPDFPage(nil); context.endPDFPage() }
            context.closePDF()
            return data as Data
        }
        try pdf(pages: 12).write(to: original.resolvedFileURL(fileStore: .init(applicationSupportDirectory: a.root)))
        let translated = try PaperFileStore(applicationSupportDirectory: a.root).write(pdf(pages: 3), named: "partial.pdf", for: paper.id)
        a.context.insert(PaperAttachment(paperID: paper.id, kind: .translatedPDF, source: .babeldoc, filename: "partial.pdf", filePath: translated.path, translatedLastPage: 3))
        a.context.insert(ReadingState(paperID: paper.id, attachmentID: original.id, readerMode: .bilingualPDF, pageIndex: 9))
        try a.context.save()
        await sync(a); await sync(b)
        let attachments = try b.context.fetch(FetchDescriptor<PaperAttachment>())
        let remoteOriginal = try XCTUnwrap(attachments.first { $0.kind == .pdf })
        let remotePartial = try XCTUnwrap(attachments.first { $0.kind == .translatedPDF })
        XCTAssertEqual(remotePartial.translatedLastPage, 3)
        XCTAssertEqual(PDFDocument(url: remoteOriginal.resolvedFileURL(fileStore: .init(applicationSupportDirectory: b.root)))?.pageCount, 12)
        XCTAssertEqual(PDFDocument(url: remotePartial.resolvedFileURL(fileStore: .init(applicationSupportDirectory: b.root)))?.pageCount, 3)
        let reading = try XCTUnwrap(ReadingStateStore().state(for: paper.id, in: b.context))
        XCTAssertEqual(reading.pageIndex, 9)
        XCTAssertEqual(DualPDFPageIndexSync.translatedPageIndex(forOriginalPageIndex: reading.pageIndex, translatedPageCount: 3), 2)
        XCTAssertEqual(reading.pageIndex, 9, "Clamping the translated pane must not clamp the original position")
    }

    func testTranslationWorkKeepsDeferringRemoteChangesAfterReaderCloses() async throws {
        let server = SyncTestServer(), a = try await device(server: server), b = try await device(server: server, notifyOpenDocuments: true)
        let (paper, _) = try addPaper(a)
        await sync(a); await sync(b)
        let local = try XCTUnwrap(b.context.fetch(FetchDescriptor<Paper>()).first)
        let work = LibrarySyncActivity.shared.beginWork(paperID: paper.id)
        defer { LibrarySyncActivity.shared.endWork(work) }
        let reader = UUID()
        LibrarySyncActivity.shared.update(reader, activity: .init(paperID: paper.id, isBusy: true))
        LibrarySyncActivity.shared.remove(reader)
        paper.title = "Changed on the other device"; try a.context.save()
        await sync(a); await sync(b)
        XCTAssertEqual(local.title, "A paper")
        LibrarySyncActivity.shared.endWork(work)
        await sync(b)
        XCTAssertEqual(local.title, "Changed on the other device")
    }

    func testWritingSyncKeepsOriginalUTF8BytesAndLineEndings() async throws {
        let server = SyncTestServer(), a = try await device(server: server), b = try await device(server: server)
        let storeA = WritingStore(fileStore: .init(applicationSupportDirectory: a.root))
        let writing = try storeA.create(markdown: "# Bytes\r\n\r\n正文\r\n")
        let bytes = Data([0xEF, 0xBB, 0xBF]) + Data("# Bytes\r\n\r\n正文\r\n".utf8)
        try bytes.write(to: storeA.markdownURL(for: writing.id), options: .atomic)
        await sync(a); await sync(b)
        let storeB = WritingStore(fileStore: .init(applicationSupportDirectory: b.root))
        XCTAssertEqual(try Data(contentsOf: storeB.markdownURL(for: writing.id)), bytes)
        let before = await server.pushCount()
        await sync(a); await sync(b)
        let after = await server.pushCount()
        XCTAssertEqual(before, after)
    }

    func testEditingMarginNoteDefersHTMLReplacement() async throws {
        let server = SyncTestServer(), a = try await device(server: server), b = try await device(server: server, notifyOpenDocuments: true)
        let (paper, _) = try addPaper(a)
        let store = PaperFileStore(applicationSupportDirectory: a.root)
        let html = try store.write(Data("<meta charset=\"UTF-8\"><p>Original</p>".utf8), named: "paper.html", for: paper.id)
        a.context.insert(PaperAttachment(paperID: paper.id, kind: .html, source: .webPage, filename: "paper.html", filePath: html.path))
        let note = Note(paperID: paper.id, body: "note")
        a.context.insert(note); try a.context.save()
        await sync(a); await sync(b)
        let owner = UUID()
        LibrarySyncActivity.shared.noteEditing(note.id, owner: owner, active: true, paperID: paper.id)
        defer { LibrarySyncActivity.shared.removeNoteEditor(owner) }
        let replacement = Data("<meta charset=\"UTF-8\"><p>Updated</p>".utf8)
        try replacement.write(to: html, options: .atomic)
        // Only the other device's activity is protected in this process.
        LibrarySyncActivity.shared.removeNoteEditor(owner)
        await sync(a)
        LibrarySyncActivity.shared.noteEditing(note.id, owner: owner, active: true, paperID: paper.id)
        await sync(b)
        let remoteHTML = try XCTUnwrap(b.context.fetch(FetchDescriptor<PaperAttachment>()).first { $0.kind == .html })
        let destination = remoteHTML.resolvedFileURL(fileStore: .init(applicationSupportDirectory: b.root))
        XCTAssertNotEqual(try Data(contentsOf: destination), replacement)
        LibrarySyncActivity.shared.removeNoteEditor(owner)
        await sync(b)
        XCTAssertEqual(try Data(contentsOf: destination), replacement)
    }

    func testTranslationsKeepTheirRouteIdentity() async throws {
        let server = SyncTestServer(), a = try await device(server: server), b = try await device(server: server)
        let (paper, _) = try addPaper(a)
        let modelA = UUID(), modelB = UUID(), provider = UUID()
        for (model, text) in [(modelA, "译文 A"), (modelB, "译文 B")] {
            a.context.insert(TranslationSegment(paperID: paper.id, sourceType: "html", targetLanguage: "zh-CN", sourceHash: "same", sourceText: "source", translatedText: text, providerProfileID: provider, modelProfileID: model, modelName: "model"))
        }
        try a.context.save()
        await sync(a); await sync(b)
        func text(_ device: Device, model: UUID) throws -> [String] {
            try device.context.fetch(FetchDescriptor<TranslationSegment>()).filter { $0.modelProfileID == model && $0.providerProfileID == provider }.map(\.translatedText)
        }
        XCTAssertEqual(try text(b, model: modelA), ["译文 A"])
        XCTAssertEqual(try text(b, model: modelB), ["译文 B"])
        let rowB = try XCTUnwrap(a.context.fetch(FetchDescriptor<TranslationSegment>()).first { $0.modelProfileID == modelB })
        rowB.translatedText = "译文 B2"; rowB.modifiedAt = Date(); try a.context.save()
        await sync(a); await sync(b)
        XCTAssertEqual(try text(b, model: modelA), ["译文 A"], "Another route's update must not overwrite this row")
        XCTAssertEqual(try text(b, model: modelB), ["译文 B2"])
        let ids = try b.context.fetch(FetchDescriptor<TranslationSegment>()).map(\.id)
        XCTAssertEqual(Set(ids).count, 2)
        XCTAssertEqual(Set(ids), Set(try a.context.fetch(FetchDescriptor<TranslationSegment>()).map(\.id)))
    }

    func testMissingAttachmentFileDoesNotBlockSyncOrDeleteRemoteAttachment() async throws {
        let server = SyncTestServer(), a = try await device(server: server), b = try await device(server: server)
        let (paper, attachment) = try addPaper(a)
        let outside = try temporaryDirectory().appendingPathComponent("outside.pdf")
        try Data("%PDF-1.7".utf8).write(to: outside)
        a.context.insert(PaperAttachment(paperID: paper.id, kind: .resource, source: .generated, filename: "outside.pdf", filePath: outside.path))
        try a.context.save()
        await sync(a); await sync(b)
        XCTAssertEqual(try b.context.fetch(FetchDescriptor<PaperAttachment>()).count, 1, "A file outside the library is not uploaded")
        XCTAssertEqual(a.controller.unavailableAttachments.map(\.reason), [.outsideLibrary])
        XCTAssertEqual(a.controller.unavailableAttachments.first?.paperTitle, "A paper")
        try FileManager.default.removeItem(at: attachment.resolvedFileURL(fileStore: .init(applicationSupportDirectory: a.root)))
        paper.title = "Still syncing"; try a.context.save()
        await sync(a); await sync(b)
        XCTAssertEqual(try b.context.fetch(FetchDescriptor<Paper>()).first?.title, "Still syncing")
        let remote = try XCTUnwrap(b.context.fetch(FetchDescriptor<PaperAttachment>()).first)
        XCTAssertEqual(remote.id, attachment.id, "A missing local file is not a deletion")
        XCTAssertEqual(Set(a.controller.unavailableAttachments.map(\.reason)), [.outsideLibrary, .missing])
        XCTAssertEqual(a.controller.unavailableAttachments.first { $0.reason == .missing }?.id, attachment.id)
        // A remote version restores the missing file.
        try Data("%PDF-1.7\nUpdated".utf8).write(to: remote.resolvedFileURL(fileStore: .init(applicationSupportDirectory: b.root)))
        await sync(b); await sync(a)
        XCTAssertEqual(try Data(contentsOf: attachment.resolvedFileURL(fileStore: .init(applicationSupportDirectory: a.root))), Data("%PDF-1.7\nUpdated".utf8))
        await sync(a)
        XCTAssertEqual(a.controller.unavailableAttachments.map(\.reason), [.outsideLibrary], "A restored file leaves the list")
    }

    func testTranslatedLaTeXFolderStaysOnThisDevice() async throws {
        let server = SyncTestServer(), a = try await device(server: server), b = try await device(server: server)
        let (paper, _) = try addPaper(a)
        let store = PaperFileStore(applicationSupportDirectory: a.root)
        let project = try store.directory(for: paper.id).appendingPathComponent("translations/latex/zh-CN/hash/translated/2512.14805v2-zh-Hans")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("\\documentclass{article}".utf8).write(to: project.appendingPathComponent("main.tex"))
        let pdf = try store.write(Data("%PDF-1.7\nTranslated".utf8), named: "main.pdf", for: paper.id)
        a.context.insert(PaperAttachment(paperID: paper.id, kind: .resource, source: .latexTrans, filename: project.lastPathComponent, filePath: project.path))
        a.context.insert(PaperAttachment(paperID: paper.id, kind: .translatedPDF, source: .latexTrans, filename: "main.pdf", filePath: pdf.path))
        // Any other folder attachment is skipped the same way rather than failing sync.
        let folder = try store.directory(for: paper.id).appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        a.context.insert(PaperAttachment(paperID: paper.id, kind: .resource, source: .generated, filename: "Exports", filePath: folder.path))
        try a.context.save()
        await sync(a); await sync(b)
        XCTAssertTrue(a.controller.unavailableAttachments.isEmpty)
        let remote = try b.context.fetch(FetchDescriptor<PaperAttachment>())
        XCTAssertEqual(Set(remote.map(\.kind)), [.pdf, .translatedPDF])
        XCTAssertEqual(try a.context.fetch(FetchDescriptor<PaperAttachment>()).count, 4, "Skipped attachments are never deleted")
    }

    func testUnsavedEditIsSavedAndUploadedBySync() async throws {
        let server = SyncTestServer(), a = try await device(server: server), b = try await device(server: server)
        let (paper, _) = try addPaper(a)
        await sync(a); await sync(b)
        a.context.autosaveEnabled = false
        paper.isFavorite = true
        XCTAssertTrue(a.context.hasChanges)
        await sync(a)
        XCTAssertFalse(a.context.hasChanges, "Without autosave, sync saves the edit itself")
        await sync(b)
        XCTAssertEqual(try b.context.fetch(FetchDescriptor<Paper>()).first?.isFavorite, true)
    }

    func testRemoteDeletionWaitsUntilThePaperIsClosed() async throws {
        let server = SyncTestServer(), a = try await device(server: server), b = try await device(server: server, notifyOpenDocuments: true)
        let (paper, _) = try addPaper(a)
        await sync(a); await sync(b)
        let reader = UUID()
        LibrarySyncActivity.shared.update(reader, activity: .init(paperID: paper.id, isBusy: false))
        defer { LibrarySyncActivity.shared.remove(reader) }
        try PaperDeletionService(fileStore: .init(applicationSupportDirectory: a.root)).delete(paper, modelContext: a.context)
        await sync(a); await sync(b)
        XCTAssertEqual(try b.context.fetch(FetchDescriptor<Paper>()).count, 1)
        XCTAssertEqual(try b.context.fetch(FetchDescriptor<PaperAttachment>()).count, 1)
        XCTAssertEqual(b.controller.statusKey, "Waiting for open documents…")
        LibrarySyncActivity.shared.remove(reader)
        await sync(b)
        XCTAssertTrue(try b.context.fetch(FetchDescriptor<Paper>()).isEmpty)
        XCTAssertTrue(try b.context.fetch(FetchDescriptor<PaperAttachment>()).isEmpty)
        XCTAssertEqual(b.controller.pendingCount, 0)
    }

    func testRemoteDeletionRemovesEveryReadingStateRow() async throws {
        let server = SyncTestServer(), a = try await device(server: server), b = try await device(server: server)
        let (paper, _) = try addPaper(a)
        await sync(a); await sync(b)
        b.context.insert(ReadingState(paperID: paper.id, readerMode: .pdf, pageIndex: 1))
        b.context.insert(ReadingState(paperID: paper.id, readerMode: .pdf, pageIndex: 2))
        try b.context.save()
        try PaperDeletionService(fileStore: .init(applicationSupportDirectory: a.root)).delete(paper, modelContext: a.context)
        await sync(a); await sync(b)
        XCTAssertTrue(try b.context.fetch(FetchDescriptor<Paper>()).isEmpty)
        XCTAssertTrue(try b.context.fetch(FetchDescriptor<ReadingState>()).isEmpty)
    }

    func testChildOfLocallyDeletedPaperBecomesAConflict() async throws {
        let server = SyncTestServer(), a = try await device(server: server), b = try await device(server: server)
        let (paper, _) = try addPaper(a)
        await sync(a); await sync(b)
        try PaperDeletionService(fileStore: .init(applicationSupportDirectory: a.root)).delete(paper, modelContext: a.context)
        b.context.insert(Note(paperID: paper.id, body: "Added before the deletion arrived"))
        try b.context.save()
        await sync(b); await sync(a)
        let conflict = try XCTUnwrap(a.controller.conflicts.first { $0.remote.kind == "note" })
        XCTAssertNil(conflict.local)
        XCTAssertEqual(a.controller.statusKey, "Some changes need review.")
        XCTAssertTrue(try a.context.fetch(FetchDescriptor<Note>()).isEmpty, "A note for a missing paper is never inserted")
        await a.controller.resolve(conflict.id, choice: .server)
        XCTAssertNotNil(a.controller.errorMessage)
        await a.controller.resolve(conflict.id, choice: .thisDevice)
        XCTAssertNil(a.controller.errorMessage)
        XCTAssertTrue(a.controller.conflicts.isEmpty)
        XCTAssertEqual(a.controller.pendingCount, 0)
        let live = await server.liveRecords()
        XCTAssertFalse(live.contains { $0.kind == "note" })
    }

    func testRejectedRequestIsNotReplayedForever() async throws {
        let server = SyncTestServer(), a = try await device(server: server)
        try addPaper(a)
        await server.rejectPush()
        await a.controller.syncNow()
        XCTAssertNotNil(a.controller.errorMessage)
        let configuration = try XCTUnwrap(a.controller.configuration)
        XCTAssertNotNil(try LibrarySyncStateStore(root: a.root).load(configuration).inFlight)
        await sync(a)
        let count = await server.recordCount()
        XCTAssertEqual(count, 2)
        XCTAssertNil(try LibrarySyncStateStore(root: a.root).load(configuration).inFlight)
    }

    func testRevisionConflictDuringUploadIsReconciledInTheSameSync() async throws {
        let server = SyncTestServer(), a = try await device(server: server), b = try await device(server: server)
        let (paperA, _) = try addPaper(a)
        await sync(a); await sync(b)
        let paperB = try XCTUnwrap(b.context.fetch(FetchDescriptor<Paper>()).first)
        paperB.title = "Title from B"; try b.context.save()
        paperA.isFavorite = true; try a.context.save()
        let otherDevice = b.controller
        // B uploads between A's fetch and A's push, so A's first push conflicts.
        await server.setBeforeNextPush { await otherDevice.syncNow() }
        await sync(a)
        XCTAssertNotEqual(a.controller.statusKey, "Some changes will upload on the next sync.")
        XCTAssertNotNil(a.controller.lastSuccess)
        XCTAssertEqual(a.controller.pendingCount, 0)
        XCTAssertEqual(paperA.title, "Title from B")
        await sync(b)
        XCTAssertTrue(paperB.isFavorite)
    }

    func testManyIncomingRecordsApplyAcrossBatchesWithoutEcho() async throws {
        let server = SyncTestServer(), a = try await device(server: server), b = try await device(server: server)
        let (paper, attachment) = try addPaper(a)
        for index in 0..<120 { a.context.insert(Note(paperID: paper.id, attachmentID: attachment.id, body: "note \(index)")) }
        try a.context.save()
        let store = PDFAnnotationStore(fileStore: .init(applicationSupportDirectory: a.root))
        try store.save((0..<60).map { _ in PDFAnnotationRecord(pageIndex: 0, kind: .highlight, bounds: CGRect(x: 1, y: 1, width: 10, height: 10), color: PDFAnnotationColorPreset.yellow.color(for: .highlight)) }, paperID: paper.id, attachmentID: attachment.id)
        await sync(a); await sync(b)
        XCTAssertEqual(try b.context.fetch(FetchDescriptor<Note>()).count, 120)
        XCTAssertEqual(try PDFAnnotationStore(fileStore: .init(applicationSupportDirectory: b.root)).load(paperID: paper.id, attachmentID: attachment.id).count, 60)
        XCTAssertEqual(b.controller.pendingCount, 0)
        let pushes = await server.pushCount()
        await sync(b); await sync(a)
        let after = await server.pushCount()
        XCTAssertEqual(pushes, after)
    }

    func testProgressSpansEveryBatchInsteadOfRestarting() async throws {
        let server = SyncTestServer(), a = try await device(server: server), b = try await device(server: server)
        let store = PaperFileStore(applicationSupportDirectory: a.root)
        // More than one upload request (100 mutations) and one download batch (50 records),
        // each paper with its own file.
        for index in 0..<70 {
            let paper = Paper(title: "Paper \(index)", authors: [], isFavorite: false)
            let file = try store.write(Data("%PDF-1.7\nfixture \(index)".utf8), named: "paper.pdf", for: paper.id)
            paper.localDirectoryPath = file.deletingLastPathComponent().path
            a.context.insert(paper)
            a.context.insert(PaperAttachment(paperID: paper.id, kind: .pdf, source: .localImport, filename: "paper.pdf", filePath: file.path))
        }
        try a.context.save()

        final class Samples: @unchecked Sendable { var values: [(Int, Int)] = [] }
        for device in [a, b] {
            let samples = Samples(), controller = device.controller
            await server.setOnTransfer {
                let value = await MainActor.run { (controller.progressCompleted, controller.progressTotal) }
                samples.values.append(value)
            }
            await sync(device)
            await server.setOnTransfer(nil)
            XCTAssertGreaterThan(samples.values.count, 1)
            let totals = Set(samples.values.map(\.1))
            XCTAssertEqual(totals.count, 1, "total changed between batches: \(totals)")
            XCTAssertGreaterThanOrEqual(totals.first ?? 0, 70)
            let completed = samples.values.map(\.0)
            XCTAssertEqual(completed, completed.sorted(), "progress went backwards")
        }
        let pushes = await server.pushCount()
        XCTAssertGreaterThan(pushes, 1)
        XCTAssertEqual(try b.context.fetch(FetchDescriptor<Paper>()).count, 70)
    }

    /// Explicit opt-in only. Credentials must belong to an isolated test library.
    func testLiveHTTPSRoundTripWhenCredentialsAreProvided() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let pathA = environment["READPAPER_SYNC_TEST_CREDENTIAL_A"],
              let pathB = environment["READPAPER_SYNC_TEST_CREDENTIAL_B"] else {
            throw XCTSkip("Live sync integration requires explicit isolated-library credentials")
        }
        func liveDevice(_ path: String) async throws -> Device {
            let root = try temporaryDirectory(), vault = SyncTestVault()
            let schema = ReadPaperModelStore.schema
            let container = try ModelContainer(for: schema, configurations: [.init(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
            let controller = LibrarySyncController(root: root, vault: vault)
            controller.start(modelContainer: container, automatically: false)
            await controller.connect(credentialData: try Data(contentsOf: URL(fileURLWithPath: path)))
            XCTAssertNil(controller.errorMessage)
            return .init(root: root, container: container, vault: vault, controller: controller)
        }
        let a = try await liveDevice(pathA), b = try await liveDevice(pathB)
        XCTAssertEqual(a.controller.configuration?.libraryID, b.controller.configuration?.libraryID)
        let (paper, attachment) = try addPaper(a, title: "Native HTTPS integration")
        let pdf = Data("%PDF-1.7\n".utf8) + Data(repeating: 65, count: 8 * 1024 * 1024)
        try pdf.write(to: attachment.fileURL, options: .atomic)
        a.context.insert(Note(paperID: paper.id, body: "原生客户端端到端校验"))
        try a.context.save()
        await sync(a); await sync(b)
        let remote = try XCTUnwrap(b.context.fetch(FetchDescriptor<PaperAttachment>()).first)
        XCTAssertEqual(try Data(contentsOf: remote.resolvedFileURL(fileStore: .init(applicationSupportDirectory: b.root))), pdf)
        XCTAssertEqual(try b.context.fetch(FetchDescriptor<Note>()).first?.body, "原生客户端端到端校验")
        paper.isFavorite = true; try a.context.save()
        await sync(a); await sync(b)
        XCTAssertEqual(try b.context.fetch(FetchDescriptor<Paper>()).first?.isFavorite, true)
        try PaperDeletionService(fileStore: .init(applicationSupportDirectory: a.root)).delete(paper, modelContext: a.context)
        await sync(a); await sync(b)
        XCTAssertTrue(try b.context.fetch(FetchDescriptor<Paper>()).isEmpty)
    }
}
