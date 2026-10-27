import Foundation

/// Reader metadata only; never part of the SwiftData schema or the PDF itself.
enum DocumentOutlineSource: String, Codable, CaseIterable, Sendable, Identifiable {
    case pdf, repairedPDF, latex, scan, automatic, ai, html
    var id: String { rawValue }
    var title: String {
        switch self {
        case .pdf: AppLocalization.localized("Embedded PDF")
        case .repairedPDF: AppLocalization.localized("Embedded PDF (repaired)")
        case .latex: AppLocalization.localized("From LaTeX source")
        case .scan: AppLocalization.localized("From scan reconstruction")
        case .automatic: AppLocalization.localized("Automatically generated")
        case .ai: AppLocalization.localized("Organized with AI")
        case .html: AppLocalization.localized("HTML headings")
        }
    }
}

struct DocumentOutlineEntry: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var title: String
    var level: Int
    var pageIndex: Int? = nil
    /// Fraction from the top of the original page, used to follow sections on the same page.
    var fraction: Double? = nil
    var anchor: String? = nil
    var translation: String? = nil

    func isUntranslated(lastPage: Int?) -> Bool {
        guard let lastPage, let pageIndex else { return false }
        return pageIndex >= lastPage
    }
}

struct DocumentOutlineVariant: Codable, Equatable, Sendable, Identifiable {
    var source: DocumentOutlineSource
    var entries: [DocumentOutlineEntry]
    var id: DocumentOutlineSource { source }
}

struct DocumentOutlineCache: Codable, Sendable {
    static let algorithmVersion = 2
    var algorithmVersion = Self.algorithmVersion
    var fingerprint: String
    var selectedSource: DocumentOutlineSource?
    var userSelectedSource: DocumentOutlineSource? = nil
    var variants: [DocumentOutlineVariant]
    /// Retained even when too few to present, for the explicit AI cleanup action.
    var candidates: [DocumentOutlineEntry] = []
    /// True when a good native outline skipped the heuristic pass; it runs on demand.
    var deferredCandidates: Bool? = nil
    var canGenerateAutomatic: Bool { deferredCandidates == true }
    var canOrganize: Bool { deferredCandidates == true || candidates.count >= 3 }
}

struct DocumentOutlineRequest: Hashable, Sendable {
    var paperID: UUID
    var pdfURL: URL
    var arxivID: String?
    /// Refresh when translation produces new semantic or scan artifacts.
    var revision = 0
}

extension DocumentOutlineEntry {
    static func current(in entries: [Self], page: Int, fraction: Double = 1) -> String? {
        entries.last {
            guard let target = $0.pageIndex else { return false }
            return target < page || (target == page && ($0.fraction ?? 0) <= fraction + 0.025)
        }?.id
    }
}

/// Outline destinations always use original PDF coordinates, including partial translations.
enum DocumentOutlineNavigation {
    static func pdfDestination(entry: DocumentOutlineEntry, translatedOnly: Bool, translatedLastPage: Int?)
        -> (pageIndex: Int?, opensOriginal: Bool) {
        (entry.pageIndex, translatedOnly && entry.isUntranslated(lastPage: translatedLastPage))
    }
}
