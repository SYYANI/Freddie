import Foundation

struct PaperSelectionStore {
    /// The paper the main window reopens at launch, saved on every selection change. Neither
    /// the SwiftData store nor the standard defaults are cheap to write that often: saving the
    /// store makes all of SwiftData's queries refetch and the whole window redraw a moment
    /// later, and any write to the standard defaults updates every `@AppStorage` property and
    /// the views reading them. `AppSettings.lastOpenedPaperID` is only read until a selection
    /// has been saved here, and is brought up to date when the app quits.
    static let lastOpenedPaperIDKey = "ReadPaper.Library.LastOpenedPaperID"

    /// A suite of its own, for the reason above. UserDefaults is thread-safe.
    nonisolated(unsafe) static let windowStateDefaults = UserDefaults(
        suiteName: "\(Bundle.main.bundleIdentifier ?? "com.yiyan.ReadPaper").window-state"
    ) ?? .standard

    static func savedPaperID(in defaults: UserDefaults = windowStateDefaults, settingsPaperID: UUID?) -> UUID? {
        guard let value = defaults.string(forKey: lastOpenedPaperIDKey) else {
            return settingsPaperID
        }
        return UUID(uuidString: value)
    }

    static func saveSelection(_ paperID: UUID?, in defaults: UserDefaults = windowStateDefaults) {
        defaults.set(paperID?.uuidString ?? "", forKey: lastOpenedPaperIDKey)
    }

    static func resolvedSelection(
        currentPaperID: UUID?,
        savedPaperID: UUID?,
        availablePaperIDs: [UUID]
    ) -> UUID? {
        let availablePaperIDs = Array(availablePaperIDs)
        let availablePaperIDSet = Set(availablePaperIDs)

        if let currentPaperID, availablePaperIDSet.contains(currentPaperID) {
            return currentPaperID
        }

        if let savedPaperID, availablePaperIDSet.contains(savedPaperID) {
            return savedPaperID
        }

        return availablePaperIDs.first
    }
}
