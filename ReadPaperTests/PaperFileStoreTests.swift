import XCTest
@testable import ReadPaper

final class PaperFileStoreTests: XCTestCase {
    func testCreatesPaperDirectoryLayout() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = PaperFileStore(applicationSupportDirectory: root)
        let paperID = UUID()
        let directory = try store.directory(for: paperID)

        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Resources").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("translations").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("notes").path))
    }

    func testCreatesStableManagedLaTeXTranslationDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PaperFileStore(applicationSupportDirectory: root)
        let paperID = UUID()

        let first = try store.latexTranslationDirectory(
            for: paperID,
            targetLanguage: "zh-CN/../../unsafe",
            cacheIdentity: "route-without-api-key"
        )
        let second = try store.latexTranslationDirectory(
            for: paperID,
            targetLanguage: "zh-CN/../../unsafe",
            cacheIdentity: "route-without-api-key"
        )

        XCTAssertEqual(first, second)
        XCTAssertTrue(first.path.hasPrefix(
            root.appendingPathComponent("Library/\(paperID.uuidString)/translations/latex").path + "/"
        ))
        XCTAssertFalse(first.path.contains(".."))
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
    }

    func testRemoveDirectoryDeletesPaperFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = PaperFileStore(applicationSupportDirectory: root)
        let paperID = UUID()
        let directory = try store.directory(for: paperID)

        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))

        try store.removeDirectory(for: paperID)

        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testModelStoreURLUsesReadPaperApplicationSupportDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let storeURL = try ReadPaperModelStore.storeURL(applicationSupportDirectory: root)

        XCTAssertEqual(storeURL, root.appendingPathComponent("ReadPaper.store"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
    }

    func testResolvesAttachmentPathFromPreviousAppContainer() throws {
        let currentRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: currentRoot) }

        let paperID = UUID()
        let previousPath = URL(fileURLWithPath: "/private/var/mobile/Containers/Data/Application/OLD-CONTAINER")
            .appendingPathComponent("Library/Application Support/ReadPaper/Library")
            .appendingPathComponent(paperID.uuidString)
            .appendingPathComponent("translations/translated.pdf")
            .path
        let store = PaperFileStore(applicationSupportDirectory: currentRoot)

        let resolved = store.resolvedManagedURL(
            forPersistedPath: previousPath,
            paperID: paperID
        )

        XCTAssertEqual(
            resolved,
            currentRoot
                .appendingPathComponent("Library")
                .appendingPathComponent(paperID.uuidString)
                .appendingPathComponent("translations/translated.pdf")
        )
    }

    func testDoesNotRebaseExternalAttachmentPath() {
        let currentRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let paperID = UUID()
        let externalURL = URL(fileURLWithPath: "/tmp/imported.pdf")
        let store = PaperFileStore(applicationSupportDirectory: currentRoot)

        let resolved = store.resolvedManagedURL(
            forPersistedPath: externalURL.path,
            paperID: paperID
        )

        XCTAssertEqual(resolved, externalURL)
    }

    func testPaperAndAttachmentResolveAgainstInjectedCurrentContainer() {
        let currentRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let paperID = UUID()
        let oldPaperDirectory = URL(fileURLWithPath: "/old/container/Library/Application Support/ReadPaper/Library")
            .appendingPathComponent(paperID.uuidString, isDirectory: true)
        let store = PaperFileStore(applicationSupportDirectory: currentRoot)
        let paper = Paper(
            id: paperID,
            title: "Container migration",
            localDirectoryPath: oldPaperDirectory.path
        )
        let attachment = PaperAttachment(
            paperID: paperID,
            kind: .pdf,
            source: .localImport,
            filename: "paper.pdf",
            filePath: oldPaperDirectory.appendingPathComponent("paper.pdf").path
        )

        XCTAssertEqual(
            paper.resolvedLocalDirectoryURL(fileStore: store),
            currentRoot.appendingPathComponent("Library/\(paperID.uuidString)", isDirectory: true)
        )
        XCTAssertEqual(
            attachment.resolvedFileURL(fileStore: store),
            currentRoot.appendingPathComponent("Library/\(paperID.uuidString)/paper.pdf")
        )
    }
}
