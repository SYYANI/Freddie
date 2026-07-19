import Foundation

struct DualPDFPageIndexSync {
    static func translatedPageIndex(
        forOriginalPageIndex originalPageIndex: Int,
        translatedPageCount: Int
    ) -> Int {
        min(max(0, originalPageIndex), maxTranslatedPage(translatedPageCount))
    }

    static func originalPageIndex(
        forTranslatedPageIndex translatedPageIndex: Int,
        translatedPageCount: Int,
        pendingProgrammaticTargets: inout Set<Int>
    ) -> Int? {
        guard translatedPageCount > 0 else {
            pendingProgrammaticTargets.removeAll()
            return nil
        }

        if pendingProgrammaticTargets.remove(translatedPageIndex) != nil {
            return nil
        }

        if !pendingProgrammaticTargets.isEmpty {
            pendingProgrammaticTargets.removeAll()
        }

        guard translatedPageIndex <= maxTranslatedPage(translatedPageCount) else {
            return nil
        }

        return max(0, translatedPageIndex)
    }

    private static func maxTranslatedPage(_ translatedPageCount: Int) -> Int {
        max(translatedPageCount - 1, 0)
    }
}
