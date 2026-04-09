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
                "arXiv HTML"
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
        "Step \(stage.stepNumber) of \(totalSteps)"
    }

    static func resolvingInput(identifier: String? = nil) -> Self {
        Self(
            stage: .resolvingInput,
            fractionCompleted: 0.08,
            title: "Checking arXiv identifier",
            detail: identifier.map { "Normalized to \($0) and checking whether it already exists in your library." }
                ?? "Normalizing the input and checking whether it already exists in your library."
        )
    }

    static func fetchingMetadata(for identifier: String) -> Self {
        Self(
            stage: .fetchingMetadata,
            fractionCompleted: 0.22,
            title: "Fetching metadata",
            detail: "Loading title, authors, abstract, and links for \(identifier)."
        )
    }

    static func creatingLibraryEntry(title: String) -> Self {
        Self(
            stage: .creatingLibraryEntry,
            fractionCompleted: 0.38,
            title: "Creating library entry",
            detail: "Preparing local storage for \"\(title)\"."
        )
    }

    static func downloadingPDF(for identifier: String) -> Self {
        Self(
            stage: .downloadingPDF,
            fractionCompleted: 0.56,
            title: "Downloading PDF",
            detail: "Saving the source PDF for \(identifier) to your local library."
        )
    }

    static func importingHTML(from source: HTMLSource, isFallback: Bool) -> Self {
        Self(
            stage: .importingHTML,
            fractionCompleted: isFallback ? 0.8 : 0.72,
            title: isFallback ? "Trying backup HTML source" : "Fetching reader HTML",
            detail: isFallback
                ? "The primary HTML source was unavailable, so ReadPaper is trying \(source.displayName)."
                : "Localizing the paper body from \(source.displayName) for reading and translation."
        )
    }

    static func finalizing(htmlImported: Bool) -> Self {
        Self(
            stage: .finalizing,
            fractionCompleted: 0.92,
            title: "Finalizing import",
            detail: htmlImported
                ? "Saving the paper, PDF, and localized HTML to your library."
                : "Saving the paper and PDF. HTML was unavailable, so the import will finish with PDF only."
        )
    }
}
