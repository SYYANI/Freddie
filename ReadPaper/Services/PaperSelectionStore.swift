import Foundation

struct PaperSelectionStore {
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
