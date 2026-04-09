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
    case missingAPIConfiguration
    case noTranslatedPDFProduced

    var errorDescription: String? {
        switch self {
        case .invalidArxivIdentifier(let rawValue):
            "Invalid arXiv identifier: \(rawValue)"
        case .missingPDF:
            "No PDF attachment is available for this paper."
        case .missingHTML:
            "No HTML attachment is available for this paper."
        case .unsupportedFile(let url):
            "Unsupported file: \(url.lastPathComponent)"
        case .missingAPIConfiguration:
            "Configure an OpenAI-compatible base URL, model, and API key first."
        case .noTranslatedPDFProduced:
            "BabelDOC finished without producing a translated PDF."
        }
    }
}
