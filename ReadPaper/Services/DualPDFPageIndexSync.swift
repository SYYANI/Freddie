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
    static func translatedPageIndex(
        forOriginalPageIndex originalPageIndex: Int,
        translatedPageCount: Int
    ) -> Int {
        min(max(0, originalPageIndex), maxTranslatedPage(translatedPageCount))
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

    private static func maxTranslatedPage(_ translatedPageCount: Int) -> Int {
        max(translatedPageCount - 1, 0)
    }
}
