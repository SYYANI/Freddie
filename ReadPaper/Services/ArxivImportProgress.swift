import Foundation

struct ArxivImportProgress: Equatable {
    enum Stage: Int, CaseIterable {
        case resolvingInput
        case fetchingMetadata
        case creatingLibraryEntry
        case downloadingPDF
        case importingHTML
        case finalizing

        var stepNumber: Int {
            rawValue + 1
        }
    }

    enum HTMLSource: String, Equatable {
        case arxiv
        case ar5iv

        var displayName: String {
            switch self {
            case .arxiv:
                AppLocalization.localized("arXiv HTML")
            case .ar5iv:
                "ar5iv"
            }
        }
    }

    let stage: Stage
    let fractionCompleted: Double
    let title: String
    let detail: String?

    var totalSteps: Int {
        Stage.allCases.count
    }

    var stepLabel: String {
        AppLocalization.format("Step %d of %d", stage.stepNumber, totalSteps)
    }

    static func resolvingInput(identifier: String? = nil) -> Self {
        Self(
            stage: .resolvingInput,
            fractionCompleted: 0.08,
            title: AppLocalization.localized("Checking arXiv identifier"),
            detail: identifier.map {
                AppLocalization.format("Normalized to %@ and checking whether it already exists in your library.", $0)
            }
                ?? AppLocalization.localized("Normalizing the input and checking whether it already exists in your library.")
        )
    }

    static func fetchingMetadata(for identifier: String) -> Self {
        Self(
            stage: .fetchingMetadata,
            fractionCompleted: 0.22,
            title: AppLocalization.localized("Fetching metadata"),
            detail: AppLocalization.format("Loading title, authors, abstract, and links for %@.", identifier)
        )
    }

    static func creatingLibraryEntry(title: String) -> Self {
        Self(
            stage: .creatingLibraryEntry,
            fractionCompleted: 0.38,
            title: AppLocalization.localized("Creating library entry"),
            detail: AppLocalization.format("Preparing local storage for \"%@\".", title)
        )
    }

    static func downloadingPDF(for identifier: String) -> Self {
        Self(
            stage: .downloadingPDF,
            fractionCompleted: 0.56,
            title: AppLocalization.localized("Downloading PDF"),
            detail: AppLocalization.format("Saving the source PDF for %@ to your local library.", identifier)
        )
    }

    static func importingHTML(from source: HTMLSource, isFallback: Bool) -> Self {
        Self(
            stage: .importingHTML,
            fractionCompleted: isFallback ? 0.8 : 0.72,
            title: isFallback ? AppLocalization.localized("Trying backup HTML source") : AppLocalization.localized("Fetching reader HTML"),
            detail: isFallback
                ? AppLocalization.format("The primary HTML source was unavailable, so ReadPaper is trying %@.", source.displayName)
                : AppLocalization.format("Localizing the paper body from %@ for reading and translation.", source.displayName)
        )
    }

    static func finalizing(htmlImported: Bool) -> Self {
        Self(
            stage: .finalizing,
            fractionCompleted: 0.92,
            title: AppLocalization.localized("Finalizing import"),
            detail: htmlImported
                ? AppLocalization.localized("Saving the paper, PDF, and localized HTML to your library.")
                : AppLocalization.localized("Saving the paper and PDF. HTML was unavailable, so the import will finish with PDF only.")
        )
    }
}

struct WebPageImportProgress: Equatable {
    enum Stage: Int, CaseIterable {
        case validatingURL
        case fetchingHTML
        case creatingLibraryEntry
        case finalizing

        var stepNumber: Int {
            rawValue + 1
        }
    }

    let stage: Stage
    let fractionCompleted: Double
    let title: String
    let detail: String?

    var totalSteps: Int {
        Stage.allCases.count
    }

    var stepLabel: String {
        AppLocalization.format("Step %d of %d", stage.stepNumber, totalSteps)
    }

    static func validatingURL(urlString: String? = nil) -> Self {
        Self(
            stage: .validatingURL,
            fractionCompleted: 0.1,
            title: AppLocalization.localized("Checking web page URL"),
            detail: urlString.map {
                AppLocalization.format("Normalized to %@ and checking whether it already exists in your library.", $0)
            }
                ?? AppLocalization.localized("Normalizing the URL and checking whether it already exists in your library.")
        )
    }

    static func fetchingHTML(from url: URL) -> Self {
        Self(
            stage: .fetchingHTML,
            fractionCompleted: 0.35,
            title: AppLocalization.localized("Fetching web page"),
            detail: AppLocalization.format("Downloading %@, extracting the readable article body, and localizing linked resources.", url.host ?? url.absoluteString)
        )
    }

    static func creatingLibraryEntry(title: String) -> Self {
        Self(
            stage: .creatingLibraryEntry,
            fractionCompleted: 0.78,
            title: AppLocalization.localized("Creating library entry"),
            detail: AppLocalization.format("Preparing local storage for \"%@\".", title)
        )
    }

    static func downloadingPDF(from url: URL) -> Self {
        Self(
            stage: .fetchingHTML,
            fractionCompleted: 0.35,
            title: AppLocalization.localized("Downloading PDF"),
            detail: AppLocalization.format("Saving the source PDF for %@ to your local library.", url.host ?? url.absoluteString)
        )
    }

    static func finalizing() -> Self {
        Self(
            stage: .finalizing,
            fractionCompleted: 0.92,
            title: AppLocalization.localized("Finalizing import"),
            detail: AppLocalization.localized("Saving the paper and localized HTML to your library.")
        )
    }
}
