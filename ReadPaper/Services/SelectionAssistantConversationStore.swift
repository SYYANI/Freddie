import Foundation

@MainActor
struct SelectionAssistantConversationStore {
    private struct Archive: Codable {
        var version: Int
        var conversations: [SelectionAssistantConversationSnapshot]
    }

    private let fileStore: PaperFileStore

    init(fileStore: PaperFileStore = PaperFileStore()) {
        self.fileStore = fileStore
    }

    func conversation(
        paperID: UUID,
        selectionIdentity: String
    ) throws -> SelectionAssistantConversationSnapshot? {
        try loadArchive(paperID: paperID).conversations.first {
            $0.selectionIdentity == selectionIdentity
        }
    }

    func save(
        _ snapshot: SelectionAssistantConversationSnapshot,
        paperID: UUID
    ) throws {
        var archive = try loadArchive(paperID: paperID)
        let normalized = Self.normalized(snapshot)
        archive.conversations.removeAll { $0.selectionIdentity == normalized.selectionIdentity }
        archive.conversations.append(normalized)
        archive.conversations.sort { $0.modifiedAt > $1.modifiedAt }
        archive.conversations = Array(archive.conversations.prefix(50))
        let data = try JSONEncoder().encode(archive)
        try data.write(to: archiveURL(paperID: paperID), options: .atomic)
    }

    func historyAnchors(
        paperID: UUID,
        attachmentID: UUID? = nil
    ) throws -> [SelectionAssistantHistoryAnchor] {
        try loadArchive(paperID: paperID).conversations.compactMap { snapshot in
            let legacyAnchor = Self.legacyAnchor(from: snapshot.selectionIdentity)
            let quote = (snapshot.quote ?? legacyAnchor?.quote)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let quote, quote.isEmpty == false,
                  attachmentID == nil || (snapshot.attachmentID ?? legacyAnchor?.attachmentID) == attachmentID,
                  snapshot.pageIndex != nil || legacyAnchor?.pageIndex != nil ||
                    snapshot.htmlSelector?.isEmpty == false || legacyAnchor?.htmlSelector?.isEmpty == false else {
                return nil
            }
            return SelectionAssistantHistoryAnchor(
                selectionIdentity: snapshot.selectionIdentity,
                attachmentID: snapshot.attachmentID ?? legacyAnchor?.attachmentID,
                quote: quote,
                pageIndex: snapshot.pageIndex ?? legacyAnchor?.pageIndex,
                htmlSelector: snapshot.htmlSelector ?? legacyAnchor?.htmlSelector
            )
        }
    }

    private func loadArchive(paperID: UUID) throws -> Archive {
        let url = try archiveURL(paperID: paperID)
        guard fileStore.fileManager.fileExists(atPath: url.path) else {
            return Archive(version: 1, conversations: [])
        }
        let archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: url))
        guard archive.version == 1 else {
            return Archive(version: 1, conversations: [])
        }
        return archive
    }

    private func archiveURL(paperID: UUID) throws -> URL {
        try fileStore.notesDirectory(for: paperID)
            .appendingPathComponent("assistant-conversations-v1.json")
    }

    private static func normalized(
        _ snapshot: SelectionAssistantConversationSnapshot
    ) -> SelectionAssistantConversationSnapshot {
        let turns = snapshot.turns.suffix(12).map { turn in
            SelectionAssistantConversationTurn(
                question: String(turn.question.prefix(1_000)),
                result: SelectionAssistantResult(
                    answer: String(turn.answer.prefix(8_000)),
                    sources: turn.result.sources.prefix(16).map { source in
                        AssistantSource(
                            id: source.id,
                            kind: source.kind,
                            title: source.title,
                            excerpt: String(source.excerpt.prefix(1_500)),
                            sectionPath: source.sectionPath,
                            attachmentID: source.attachmentID,
                            pageIndex: source.pageIndex,
                            htmlSelector: source.htmlSelector,
                            urlString: source.urlString,
                            isLowConfidence: source.isLowConfidence
                        )
                    },
                    scope: turn.result.scope,
                    warnings: Array(turn.result.warnings.prefix(4))
                )
            )
        }
        return SelectionAssistantConversationSnapshot(
            selectionIdentity: snapshot.selectionIdentity,
            attachmentID: snapshot.attachmentID,
            quote: snapshot.quote,
            pageIndex: snapshot.pageIndex,
            htmlSelector: snapshot.htmlSelector,
            action: snapshot.action,
            scope: snapshot.scope,
            turns: turns,
            modifiedAt: snapshot.modifiedAt
        )
    }

    private static func legacyAnchor(from selectionIdentity: String) -> SelectionAssistantHistoryAnchor? {
        let fields = selectionIdentity.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false)
        guard fields.count == 4 else { return nil }
        let attachmentID = fields[0].isEmpty ? nil : UUID(uuidString: String(fields[0]))
        let pageIndex = Int(fields[1])
        let htmlSelector = fields[2].isEmpty ? nil : String(fields[2])
        let quote = String(fields[3])
        guard quote.isEmpty == false, pageIndex != nil || htmlSelector != nil else { return nil }
        return SelectionAssistantHistoryAnchor(
            selectionIdentity: selectionIdentity,
            attachmentID: attachmentID,
            quote: quote,
            pageIndex: pageIndex,
            htmlSelector: htmlSelector
        )
    }
}
