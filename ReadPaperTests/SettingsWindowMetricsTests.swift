import XCTest
@testable import ReadPaper

final class SettingsWindowMetricsTests: XCTestCase {
    /// Title bar chrome for a full size content view window.
    private let chromeSize = CGSize(width: 0, height: 28)

    func testDefaultContentSizeIsKeptOnDisplaysThatFitIt() {
        let fittedSize = SettingsWindowMetrics.contentSizeFittedToScreen(
            SettingsWindowMetrics.defaultContentSize,
            visibleFrame: CGSize(width: 1512, height: 930),
            chromeSize: chromeSize
        )

        XCTAssertEqual(fittedSize, SettingsWindowMetrics.defaultContentSize)
    }

    func testDefaultContentSizeShrinksForSmallDisplayWithMenuBarAndDock() {
        // 1280x800 display with both the menu bar and the Dock visible.
        let visibleFrame = CGSize(width: 1280, height: 705)

        let fittedSize = SettingsWindowMetrics.contentSizeFittedToScreen(
            SettingsWindowMetrics.defaultContentSize,
            visibleFrame: visibleFrame,
            chromeSize: chromeSize
        )

        XCTAssertEqual(fittedSize.width, SettingsWindowMetrics.defaultWidth)
        XCTAssertLessThan(fittedSize.height, SettingsWindowMetrics.defaultHeight)
        XCTAssertLessThanOrEqual(
            fittedSize.height + chromeSize.height + SettingsWindowMetrics.screenMargin * 2,
            visibleFrame.height
        )
    }

    func testFittingNeverGrowsAContentSizeBeyondItsRequestedSize() {
        let requestedSize = CGSize(width: 600, height: 420)

        let fittedSize = SettingsWindowMetrics.contentSizeFittedToScreen(
            requestedSize,
            visibleFrame: CGSize(width: 2560, height: 1400),
            chromeSize: chromeSize
        )

        XCTAssertEqual(fittedSize, requestedSize)
    }

    func testMinimumContentSizeFitsTheSmallestDisplayTheAppTargets() {
        // 1280x800 with menu bar and Dock is the smallest display in scope.
        let maximumSize = SettingsWindowMetrics.maximumContentSize(
            fitting: CGSize(width: 1280, height: 705),
            chromeSize: chromeSize
        )

        XCTAssertGreaterThanOrEqual(maximumSize.width, SettingsWindowMetrics.minWidth)
        XCTAssertGreaterThanOrEqual(maximumSize.height, SettingsWindowMetrics.minHeight)
    }

    func testResizabilityMetricsKeepRoomForTheTallestTabContent() {
        XCTAssertGreaterThan(SettingsWindowMetrics.minHeight, 0)
        XCTAssertLessThan(SettingsWindowMetrics.minWidth, SettingsWindowMetrics.defaultWidth)
        XCTAssertLessThan(SettingsWindowMetrics.minHeight, SettingsWindowMetrics.defaultHeight)
    }
}
