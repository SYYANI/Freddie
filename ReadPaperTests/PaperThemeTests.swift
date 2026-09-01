import CoreGraphics
import XCTest
@testable import ReadPaper

final class PaperThemeTests: XCTestCase {
    func testSystemRenderingRemainsTheDefaultReaderAppearance() {
        XCTAssertEqual(PDFDisplayAppearance.defaultValue, .defaultMode)
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
