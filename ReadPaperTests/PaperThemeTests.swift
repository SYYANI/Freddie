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

    @MainActor
    func testReaderGlassShowsWindowBackgroundOnlyWhileWindowIsInactive() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("The reader glass surface only exists on macOS 26 and later")
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }

        var isActive = false
        let surface = ReaderGlassSurfaceView(frame: window.contentLayoutRect)
        surface.isWindowActive = { _ in isActive }
        XCTAssertFalse(surface.inactiveFillView.isHidden, "A surface outside any window must stay opaque")

        window.contentView = surface
        XCTAssertFalse(surface.inactiveFillView.isHidden)
        XCTAssertTrue(surface.subviews.firstIndex(of: surface.inactiveFillView)! < surface.subviews.firstIndex(of: surface.glassView)!)

        isActive = true
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        XCTAssertTrue(surface.inactiveFillView.isHidden, "An active window keeps the translucent glass")

        isActive = false
        NotificationCenter.default.post(name: NSWindow.didResignMainNotification, object: window)
        XCTAssertFalse(surface.inactiveFillView.isHidden, "An inactive window falls back to the window background")

        isActive = true
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        XCTAssertTrue(surface.inactiveFillView.isHidden)

        window.contentView = NSView()
        XCTAssertFalse(surface.inactiveFillView.isHidden, "A detached surface must stay opaque")
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
