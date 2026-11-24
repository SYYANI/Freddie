import XCTest
@testable import ReadPaper

final class ExportFilenameTests: XCTestCase {
    func testUsesPaperTitle() {
        XCTAssertEqual(
            ExportFilename.pdf(title: "Attention Is All You Need"),
            "Attention Is All You Need.pdf"
        )
    }

    func testAppendsVariant() {
        XCTAssertEqual(
            ExportFilename.pdf(title: "Attention Is All You Need", variant: "译文"),
            "Attention Is All You Need (译文).pdf"
        )
    }

    func testReplacesPathSeparatorsAndCollapsesWhitespace() {
        XCTAssertEqual(
            ExportFilename.pdf(title: "  GPT-4: A Report\non  Models/Agents\t"),
            "GPT-4- A Report on Models-Agents.pdf"
        )
    }

    func testDropsLeadingDotsSoTheFileIsNotHidden() {
        XCTAssertEqual(ExportFilename.pdf(title: "...hidden"), "hidden.pdf")
    }

    func testFallsBackWhenTitleIsEmpty() {
        XCTAssertEqual(ExportFilename.pdf(title: " \n "), "paper.pdf")
        XCTAssertEqual(ExportFilename.pdf(title: "", variant: " "), "paper.pdf")
    }

    func testTruncatesLongTitles() {
        let name = ExportFilename.sanitizedTitle(String(repeating: "a", count: 300))
        XCTAssertEqual(name.count, ExportFilename.maxTitleLength)
    }
}
