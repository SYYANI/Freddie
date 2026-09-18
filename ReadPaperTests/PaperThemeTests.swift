import AppKit
import CoreGraphics
import XCTest
@testable import ReadPaper

final class PaperThemeTests: XCTestCase {
    func testSystemRenderingRemainsTheDefaultReaderAppearance() {
        XCTAssertEqual(PDFDisplayAppearance.defaultValue, .defaultMode)
    }

    func testReaderAppearanceFollowsSystemAppearance() {
        XCTAssertEqual(
            PDFDisplayAppearance.synchronized(isSystemDarkMode: false),
            .defaultMode
        )
        XCTAssertEqual(
            PDFDisplayAppearance.synchronized(isSystemDarkMode: true),
            .paper
        )
        XCTAssertEqual(PDFDisplayAppearance.allCases, [.defaultMode, .paper])
    }

    func testManualPreferenceOverridesUntilSystemAppearanceChangesAgain() throws {
        let suiteName = "PaperThemeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(PDFDisplayAppearance.defaultMode.rawValue, forKey: PDFDisplayAppearance.userDefaultsKey)
        PDFDisplayAppearance.synchronizeStoredPreference(in: defaults, isSystemDarkMode: true)
        XCTAssertEqual(defaults.string(forKey: PDFDisplayAppearance.userDefaultsKey), "paper")

        defaults.set(PDFDisplayAppearance.defaultMode.rawValue, forKey: PDFDisplayAppearance.userDefaultsKey)
        PDFDisplayAppearance.synchronizeStoredPreference(in: defaults, isSystemDarkMode: true)
        XCTAssertEqual(defaults.string(forKey: PDFDisplayAppearance.userDefaultsKey), "default")

        PDFDisplayAppearance.synchronizeStoredPreference(in: defaults, isSystemDarkMode: false)
        XCTAssertEqual(defaults.string(forKey: PDFDisplayAppearance.userDefaultsKey), "default")

        defaults.set(PDFDisplayAppearance.paper.rawValue, forKey: PDFDisplayAppearance.userDefaultsKey)
        PDFDisplayAppearance.synchronizeStoredPreference(in: defaults, isSystemDarkMode: false)
        XCTAssertEqual(defaults.string(forKey: PDFDisplayAppearance.userDefaultsKey), "paper")
    }

    func testRemovedDarkPreferenceFallsBackToDefaultBehavior() {
        XCTAssertEqual(PDFDisplayAppearance.resolve(rawValue: "dark"), .defaultMode)
    }

    @MainActor
    func testSystemAppearanceMonitorMapsAquaToDefaultAndDarkAquaToPaper() {
        XCTAssertEqual(
            SystemAppearanceMonitor.readerAppearance(for: NSAppearance(named: .aqua)!),
            .defaultMode
        )
        XCTAssertEqual(
            SystemAppearanceMonitor.readerAppearance(for: NSAppearance(named: .darkAqua)!),
            .paper
        )
    }

    func testTextureDotCountIsBoundedAndScalesWithArea() {
        XCTAssertEqual(PaperTextureMetrics.dotCount(for: CGSize(width: 20, height: 20)), 90)
        XCTAssertEqual(PaperTextureMetrics.dotCount(for: CGSize(width: 800, height: 1_000)), 400)
        XCTAssertEqual(PaperTextureMetrics.dotCount(for: CGSize(width: 4_000, height: 4_000)), 720)
    }

    func testTextureFiberCountIsBoundedAndScalesWithHeight() {
        XCTAssertEqual(PaperTextureMetrics.fiberCount(for: 100), 8)
        XCTAssertEqual(PaperTextureMetrics.fiberCount(for: 700), 10)
        XCTAssertEqual(PaperTextureMetrics.fiberCount(for: 4_000), 24)
    }

    func testDeterministicUnitValueStaysNormalized() {
        let first = PaperTextureMetrics.unit(432, modulus: 997)
        XCTAssertEqual(first, PaperTextureMetrics.unit(432, modulus: 997))
        XCTAssertGreaterThanOrEqual(first, 0)
        XCTAssertLessThan(first, 1)
    }
}
