import Foundation

enum AttachmentKind: String, Codable, CaseIterable, Identifiable {
    case pdf
    case html
    case translatedPDF
    case resource

    var id: String { rawValue }
}

enum AttachmentSource: String, Codable, CaseIterable, Identifiable {
    case arxivPDF
    case arxivHTML
    case localImport
    case babeldoc
    case generated

    var id: String { rawValue }
}

enum ReaderMode: String, Codable, CaseIterable, Identifiable {
    case html
    case pdf
    case bilingualPDF
    case translatedPDF

    var id: String { rawValue }
}

enum TranslationDisplayMode: String, Codable, CaseIterable, Identifiable {
    case original
    case bilingual
    case translated

    var id: String { rawValue }
}

enum TranslationJobState: String, Codable, CaseIterable, Identifiable {
    case queued
    case running
    case paused
    case completed
    case failed

    var id: String { rawValue }
}

enum ToolInstallStatus: String, Codable, CaseIterable, Identifiable {
    case missing
    case installing
    case ready
    case failed

    var id: String { rawValue }
}

enum PaperImportError: Error, LocalizedError {
    case invalidArxivIdentifier(String)
    case missingPDF
    case missingHTML
    case unsupportedFile(URL)
    case noTranslatedPDFProduced

    var errorDescription: String? {
        switch self {
        case .invalidArxivIdentifier(let rawValue):
            AppLocalization.format("Invalid arXiv identifier: %@", rawValue)
        case .missingPDF:
            AppLocalization.localized("No PDF attachment is available for this paper.")
        case .missingHTML:
            AppLocalization.localized("No HTML attachment is available for this paper.")
        case .unsupportedFile(let url):
            AppLocalization.format("Unsupported file: %@", url.lastPathComponent)
        case .noTranslatedPDFProduced:
            AppLocalization.localized("BabelDOC finished without producing a translated PDF.")
        }
    }
}
