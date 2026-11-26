import Foundation

struct PDFTranslationCoverage {
    static func isPartial(
        translatedLastPage: Int?,
        originalPageCount: Int
    ) -> Bool {
        guard let translatedLastPage, originalPageCount > 0 else { return false }
        return translatedLastPage < originalPageCount
    }
}

struct DualPDFPageIndexSync {
    /// A count of 0 means the translated document's page count is not known yet, such as right
    /// after a continued translation replaced the file. The page is then left unclamped (the
    /// reader clamps it to the document it loads): clamping to 0 would send the translated
    /// pane to the first page, and its page report could pull the original back there too.
    static func translatedPageIndex(
        forOriginalPageIndex originalPageIndex: Int,
        translatedPageCount: Int
    ) -> Int {
        guard translatedPageCount > 0 else { return max(0, originalPageIndex) }
        return min(max(0, originalPageIndex), maxTranslatedPage(translatedPageCount))
    }

    static func originalPageIndex(
        forTranslatedPageIndex translatedPageIndex: Int,
        translatedPageCount: Int
    ) -> Int? {
        guard translatedPageCount > 0 else { return nil }
        guard translatedPageIndex <= maxTranslatedPage(translatedPageCount) else {
            return nil
        }

        return max(0, translatedPageIndex)
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

        pendingProgrammaticTargets.removeAll()
        return originalPageIndex(
            forTranslatedPageIndex: translatedPageIndex,
            translatedPageCount: translatedPageCount
        )
    }

    private static func maxTranslatedPage(_ translatedPageCount: Int) -> Int {
        max(translatedPageCount - 1, 0)
    }
}
