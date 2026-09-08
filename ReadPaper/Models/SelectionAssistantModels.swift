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
    var id: String
    var kind: AssistantSourceKind
    var title: String
    var excerpt: String
    var sectionPath: [String]
    var attachmentID: UUID?
    var pageIndex: Int?
    var htmlSelector: String?
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
        self.urlString = urlString?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.isLowConfidence = isLowConfidence
    }

    var navigationRequest: NoteNavigationRequest? {
        guard pageIndex != nil || htmlSelector?.isEmpty == false else { return nil }
        return NoteNavigationRequest(
            attachmentID: attachmentID,
            pageIndex: pageIndex,
            htmlSelector: htmlSelector,
            quote: excerpt
        )
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
}

struct SelectionAssistantConversationSnapshot: Codable, Equatable, Sendable {
    var selectionIdentity: String
    var action: SelectionAssistantAction
    var scope: AssistantScope
    var turns: [SelectionAssistantConversationTurn]
    var modifiedAt: Date

    init(
        selectionIdentity: String,
        action: SelectionAssistantAction,
        scope: AssistantScope,
        turns: [SelectionAssistantConversationTurn],
        modifiedAt: Date = Date()
    ) {
        self.selectionIdentity = selectionIdentity
        self.action = action
        self.scope = scope
        self.turns = turns
        self.modifiedAt = modifiedAt
    }
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
