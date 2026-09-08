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
                    sources: turn.result.sources.prefix(8).map { source in
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
            action: snapshot.action,
            scope: snapshot.scope,
            turns: turns,
            modifiedAt: snapshot.modifiedAt
        )
    }
}
