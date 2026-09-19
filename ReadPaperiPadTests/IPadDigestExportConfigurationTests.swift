import Foundation
import XCTest
@testable import ReadPaperiPad

final class IPadDigestExportConfigurationTests: XCTestCase {
    func testDirectoryBookmarkRoundTripsWithoutMacOSSecurityScopeOptions() throws {
        let suiteName = "IPadDigestExportConfigurationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ipad-digest-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let configuration = PaperDigestExportConfiguration(
            userDefaults: defaults,
            fileManager: .default
        )
        try configuration.saveExportDirectory(directory)

        XCTAssertEqual(configuration.directoryDisplayPath, directory.path)
        XCTAssertEqual(
            try configuration.resolveExportDirectory().standardizedFileURL,
            directory.standardizedFileURL
        )
    }
}
