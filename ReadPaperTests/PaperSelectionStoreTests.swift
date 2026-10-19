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

    func testSavedSelectionFallsBackToTheSettingsFieldUntilOneIsSaved() throws {
        let suiteName = "ReadPaperTests.PaperSelection.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsPaperID = UUID()

        XCTAssertEqual(PaperSelectionStore.savedPaperID(in: defaults, settingsPaperID: settingsPaperID), settingsPaperID)

        let selectedPaperID = UUID()
        PaperSelectionStore.saveSelection(selectedPaperID, in: defaults)
        XCTAssertEqual(PaperSelectionStore.savedPaperID(in: defaults, settingsPaperID: settingsPaperID), selectedPaperID)

        PaperSelectionStore.saveSelection(nil, in: defaults)
        XCTAssertNil(PaperSelectionStore.savedPaperID(in: defaults, settingsPaperID: settingsPaperID))
    }

    /// Any write to the standard defaults updates every `@AppStorage` property in the
    /// window, so the selection, saved on every switch, has to go elsewhere.
    func testSelectionIsNotSavedInTheStandardDefaults() {
        XCTAssertFalse(PaperSelectionStore.windowStateDefaults === UserDefaults.standard)
    }
}
