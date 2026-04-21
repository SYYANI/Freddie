import Foundation

struct NoteSelectionContext: Equatable {
    var attachmentID: UUID?
    var quote: String
    var pageIndex: Int?
    var htmlSelector: String?

    init(
        attachmentID: UUID? = nil,
        quote: String,
        pageIndex: Int? = nil,
        htmlSelector: String? = nil
    ) {
        self.attachmentID = attachmentID
        self.quote = Self.normalizedText(quote)
        self.pageIndex = pageIndex.map { max(0, $0) }
        self.htmlSelector = Self.normalizedOptionalText(htmlSelector)
    }

    var hasAnchor: Bool {
        pageIndex != nil || htmlSelector != nil
    }

    var trimmedQuote: String? {
        Self.normalizedOptionalText(quote)
    }

    private static func normalizedText(_ value: String) -> String {
        value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func normalizedOptionalText(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct NoteNavigationRequest: Equatable, Identifiable {
    let id: UUID
    var attachmentID: UUID?
    var pageIndex: Int?
    var htmlSelector: String?

    init(
        id: UUID = UUID(),
        attachmentID: UUID? = nil,
        pageIndex: Int? = nil,
        htmlSelector: String? = nil
    ) {
        self.id = id
        self.attachmentID = attachmentID
        self.pageIndex = pageIndex.map { max(0, $0) }
        self.htmlSelector = htmlSelector?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension Note {
    var trimmedQuote: String? {
        let normalized = quote
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return normalized.isEmpty ? nil : normalized
    }

    var normalizedHTMLSelector: String? {
        let trimmed = htmlSelector?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, trimmed.isEmpty == false else { return nil }
        return trimmed
    }

    var hasAnchor: Bool {
        pageIndex != nil || normalizedHTMLSelector != nil
    }

    var navigationRequest: NoteNavigationRequest? {
        guard hasAnchor else { return nil }
        return NoteNavigationRequest(
            attachmentID: attachmentID,
            pageIndex: pageIndex,
            htmlSelector: normalizedHTMLSelector
        )
    }
}
