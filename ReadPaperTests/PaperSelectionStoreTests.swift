import XCTest
@testable import ReadPaper

final class PaperSelectionStoreTests: XCTestCase {
    func testResolvedSelectionPrefersCurrentSelectionWhenStillAvailable() {
        let currentPaperID = UUID()
        let savedPaperID = UUID()
        let fallbackPaperID = UUID()

        let selection = PaperSelectionStore.resolvedSelection(
            currentPaperID: currentPaperID,
            savedPaperID: savedPaperID,
            availablePaperIDs: [fallbackPaperID, currentPaperID, savedPaperID]
        )

        XCTAssertEqual(selection, currentPaperID)
    }

    func testResolvedSelectionRestoresSavedPaperWhenCurrentSelectionIsMissing() {
        let savedPaperID = UUID()
        let fallbackPaperID = UUID()

        let selection = PaperSelectionStore.resolvedSelection(
            currentPaperID: nil,
            savedPaperID: savedPaperID,
            availablePaperIDs: [fallbackPaperID, savedPaperID]
        )

        XCTAssertEqual(selection, savedPaperID)
    }

    func testResolvedSelectionFallsBackToFirstAvailablePaperWhenNeeded() {
        let fallbackPaperID = UUID()

        let selection = PaperSelectionStore.resolvedSelection(
            currentPaperID: UUID(),
            savedPaperID: UUID(),
            availablePaperIDs: [fallbackPaperID]
        )

        XCTAssertEqual(selection, fallbackPaperID)
    }

    func testResolvedSelectionReturnsNilWhenNoPapersExist() {
        let selection = PaperSelectionStore.resolvedSelection(
            currentPaperID: UUID(),
            savedPaperID: UUID(),
            availablePaperIDs: []
        )

        XCTAssertNil(selection)
    }
}
