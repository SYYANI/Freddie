import Foundation

enum AssistantScope: String, Codable, CaseIterable, Equatable, Sendable, Identifiable {
    case automatic
    case nearby
    case fullPaper
    case external

    var id: String { rawValue }
}

enum AssistantSourceKind: String, Codable, Equatable, Sendable {
    case currentSelection
    case paperHTML
    case paperPDF
    case userNote
    case paperMetadata
    case external
}

struct AssistantSource: Codable, Equatable, Hashable, Sendable, Identifiable {
    static let liveWebSearchID = "live-web-search"
    static let liveWebSearchResultIDPrefix = "live-web-search-result-"

    var id: String
    var kind: AssistantSourceKind
    var title: String
    var excerpt: String
    var sectionPath: [String]
    var attachmentID: UUID?
    var pageIndex: Int?
    var htmlSelector: String?
    /// Exact source text used to locate a transient reader highlight.
    /// `excerpt` may include neighboring context and is reserved for the model/UI.
    var navigationQuote: String?
    var urlString: String?
    var isLowConfidence: Bool

    init(
        id: String,
        kind: AssistantSourceKind,
        title: String,
        excerpt: String,
        sectionPath: [String] = [],
        attachmentID: UUID? = nil,
        pageIndex: Int? = nil,
        htmlSelector: String? = nil,
        navigationQuote: String? = nil,
        urlString: String? = nil,
        isLowConfidence: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.excerpt = String(excerpt.trimmingCharacters(in: .whitespacesAndNewlines).prefix(8_000))
        self.sectionPath = sectionPath
        self.attachmentID = attachmentID
        self.pageIndex = pageIndex.map { max(0, $0) }
        self.htmlSelector = htmlSelector?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.navigationQuote = Self.normalizedOptionalText(navigationQuote)
        self.urlString = urlString?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.isLowConfidence = isLowConfidence
    }

    var navigationRequest: NoteNavigationRequest? {
        guard pageIndex != nil || htmlSelector?.isEmpty == false else { return nil }
        return NoteNavigationRequest(
            attachmentID: attachmentID,
            pageIndex: pageIndex,
            htmlSelector: htmlSelector,
            quote: navigationQuote ?? excerpt
        )
    }

    var isLiveWebSearchResult: Bool {
        id.hasPrefix(Self.liveWebSearchResultIDPrefix)
    }

    private static func normalizedOptionalText(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return normalized.isEmpty ? nil : normalized
    }
}

struct SelectionAssistantResult: Codable, Equatable, Sendable {
    var answer: String
    var sources: [AssistantSource]
    var scope: AssistantScope
    var warnings: [String]

    init(
        answer: String,
        sources: [AssistantSource] = [],
        scope: AssistantScope = .nearby,
        warnings: [String] = []
    ) {
        self.answer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sources = sources
        self.scope = scope
        self.warnings = warnings
    }

    /// Sources that participate in the citation namespace shown to the user.
    /// Once concrete web results are available, the provisional live-search
    /// placeholder is hidden and each URL receives its own sequential label.
    var citationSources: [AssistantSource] {
        let hasConcreteWebResults = sources.contains(where: \.isLiveWebSearchResult)
        guard hasConcreteWebResults else { return sources }
        return sources.filter { $0.id != AssistantSource.liveWebSearchID }
    }
}

struct SelectionAssistantConversationSnapshot: Codable, Equatable, Sendable {
    var selectionIdentity: String
    var attachmentID: UUID?
    var quote: String?
    var pageIndex: Int?
    var htmlSelector: String?
    var action: SelectionAssistantAction
    var scope: AssistantScope
    var turns: [SelectionAssistantConversationTurn]
    var modifiedAt: Date

    init(
        selectionIdentity: String,
        attachmentID: UUID? = nil,
        quote: String? = nil,
        pageIndex: Int? = nil,
        htmlSelector: String? = nil,
        action: SelectionAssistantAction,
        scope: AssistantScope,
        turns: [SelectionAssistantConversationTurn],
        modifiedAt: Date = Date()
    ) {
        self.selectionIdentity = selectionIdentity
        self.attachmentID = attachmentID
        self.quote = quote
        self.pageIndex = pageIndex
        self.htmlSelector = htmlSelector
        self.action = action
        self.scope = scope
        self.turns = turns
        self.modifiedAt = modifiedAt
    }
}

struct SelectionAssistantHistoryAnchor: Codable, Equatable, Hashable, Sendable, Identifiable {
    var id: String { selectionIdentity }
    var selectionIdentity: String
    var attachmentID: UUID?
    var quote: String
    var pageIndex: Int?
    var htmlSelector: String?
}

enum SelectionAssistantProgress: Equatable, Sendable {
    case collectingPaperContext
    case searchingFullText
    case foundPaperSources(Int)
    case searchingExternalSources
    case generatingAnswer
}

enum SelectionAssistantPreferences {
    static let selectedModelProfileIDKey = "ReadPaper.SelectionAssistant.SelectedModelProfileID"
    static let externalSearchEnabledKey = "ReadPaper.SelectionAssistant.ExternalSearchEnabled"
}
