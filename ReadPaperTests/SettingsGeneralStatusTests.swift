import XCTest
@testable import ReadPaper

final class SettingsGeneralStatusTests: XCTestCase {
    func testPDFTranslationBatchPreferenceKeepsDefaultAtTenPages() {
        XCTAssertEqual(PDFTranslationBatchPreference.defaultValue, 10)
        XCTAssertEqual(PDFTranslationBatchPreference.normalized(PDFTranslationBatchPreference.defaultValue), 10)
    }

    func testPDFTranslationBatchPreferenceClampsStoredValues() {
        XCTAssertEqual(PDFTranslationBatchPreference.normalized(-3), PDFTranslationBatchPreference.allowedRange.lowerBound)
        XCTAssertEqual(PDFTranslationBatchPreference.normalized(100), PDFTranslationBatchPreference.allowedRange.upperBound)
    }

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
