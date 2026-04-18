import XCTest
@testable import ReadPaper

final class SettingsGeneralStatusTests: XCTestCase {
    func testSyncInstalledBabelDocVersionClearsStaleReadyStatusWhenToolIsMissing() {
        var status = SettingsGeneralStatus(
            message: "BabelDOC is ready. Installed version: 0.6.1.",
            source: .babelDocReady
        )

        status.syncInstalledBabelDocVersion(nil, bundle: .main)

        XCTAssertNil(status.message)
        XCTAssertNil(status.source)
    }

    func testSyncInstalledBabelDocVersionKeepsGenericStatusWhenToolIsMissing() {
        var status = SettingsGeneralStatus(
            message: "Installing BabelDOC...",
            source: .generic
        )

        status.syncInstalledBabelDocVersion(nil, bundle: .main)

        XCTAssertEqual(status.message, "Installing BabelDOC...")
        XCTAssertEqual(status.source, .generic)
    }
}
