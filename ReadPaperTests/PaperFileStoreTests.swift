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
}
