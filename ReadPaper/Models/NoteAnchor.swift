import Foundation

struct NoteSelectionContext: Equatable {
    var attachmentID: UUID?
    var quote: String
    var pageIndex: Int?
    var htmlSelector: String?
    var localContext: String?

    init(
        attachmentID: UUID? = nil,
        quote: String,
        pageIndex: Int? = nil,
        htmlSelector: String? = nil,
        localContext: String? = nil
    ) {
        self.attachmentID = attachmentID
        self.quote = Self.normalizedText(quote)
        self.pageIndex = pageIndex.map { max(0, $0) }
        self.htmlSelector = Self.normalizedOptionalText(htmlSelector)
        self.localContext = Self.normalizedOptionalText(localContext)
    }

    var hasAnchor: Bool {
        pageIndex != nil || htmlSelector != nil
    }

    var trimmedQuote: String? {
        Self.normalizedOptionalText(quote)
    }

    var selectionAssistantIdentity: String {
        [
            attachmentID?.uuidString ?? "",
            pageIndex.map(String.init) ?? "",
            htmlSelector ?? "",
            quote,
        ].joined(separator: "|")
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
    var quote: String?

    init(
        id: UUID = UUID(),
        attachmentID: UUID? = nil,
        pageIndex: Int? = nil,
        htmlSelector: String? = nil,
        quote: String? = nil
    ) {
        self.id = id
        self.attachmentID = attachmentID
        self.pageIndex = pageIndex.map { max(0, $0) }
        self.htmlSelector = htmlSelector?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.quote = Self.normalizedText(quote ?? "")
    }
}

extension Note {
    static func selectionAssistantNote(
        paperID: UUID,
        selection: NoteSelectionContext,
        result: String
    ) -> Note {
        Note(
            paperID: paperID,
            attachmentID: selection.attachmentID,
            quote: selection.trimmedQuote ?? "",
            body: result,
            pageIndex: selection.pageIndex,
            htmlSelector: selection.htmlSelector
        )
    }

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
            htmlSelector: normalizedHTMLSelector,
            quote: trimmedQuote
        )
    }
}

private extension NoteNavigationRequest {
    static func normalizedText(_ value: String) -> String? {
        let normalized = value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return normalized.isEmpty ? nil : normalized
    }
}
