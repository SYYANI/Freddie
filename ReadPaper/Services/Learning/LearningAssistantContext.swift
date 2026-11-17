import Foundation

/// Gives the reading assistant what the reader already learned about the terms in a
/// passage: concept entries from the organized learning records of every paper, matched
/// by name. Nothing is sent that the reader did not produce or approve into a record.
struct LearningAssistantContext: Sendable {
    static let sourceIDPrefix = "learning-"

    var load: @Sendable () async -> (records: [PaperLearningRecord], events: [LearningEvent])

    /// Reads the library's records. Unit tests run inside the app and must not depend on
    /// the reader's own records, so there it finds nothing.
    static let standard = LearningAssistantContext {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return ([], []) }
        return (await LearningRecordStore.shared.allRecords(), await LearningEventLog.shared.allEvents())
    }

    static let none = LearningAssistantContext { ([], []) }

    func sources(
        mentionedIn text: String,
        paperTitles: [UUID: String],
        limit: Int = 3
    ) async -> [AssistantSource] {
        let (records, events) = await load()
        guard records.isEmpty == false else { return [] }
        let eventsByID = Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let concepts = LearningLibrary.concepts(
            mentionedIn: text,
            among: LearningLibrary.concepts(records: records, eventsByID: eventsByID),
            limit: limit
        )
        return concepts.map { concept in
            var lines: [String] = []
            for entry in concept.entries.prefix(3) {
                var line = entry.item.detail ?? entry.item.title
                if let title = paperTitles[entry.paperID] {
                    line += " " + AppLocalization.format("(from the reader's record for “%@”)", title)
                }
                lines.append(line)
            }
            // Reuses the note kind: conversations are stored with their sources, and an
            // older version of the app could not decode a kind it does not know.
            return AssistantSource(
                id: Self.sourceIDPrefix + concept.id,
                kind: .userNote,
                title: AppLocalization.format("Learning record: %@", concept.name),
                excerpt: lines.joined(separator: "\n")
            )
        }
    }
}

/// What the reader already knows about the terms in a passage they just selected, shown
/// in the reader before any model is asked.
struct LearningRecall: Equatable, Sendable {
    /// Longer selections are passages, not terms: nothing is recalled for them.
    static let selectionLimit = 240

    var concepts: [LearningConcept] = []
    /// The events behind the concepts' entries, to jump back to where they came from.
    var eventsByID: [String: LearningEvent] = [:]

    var isEmpty: Bool { concepts.isEmpty }

    /// The passage an entry came from, or just its paper when no event has a position.
    func citation(for entry: LearningConcept.Entry) -> (citation: PaperCitation, quote: String?) {
        let sources = entry.item.evidence.compactMap { eventsByID[$0] }
        if let target = sources.first(where: \.hasAnchor) ?? sources.first {
            return (target.citation, target.quote)
        }
        return (PaperCitation(paperID: entry.paperID), nil)
    }
}

/// The library's concepts, derived once and kept until a record or a log changes, so
/// selecting text does not read every paper's files each time.
@MainActor
final class LearningConceptIndex {
    static let shared = LearningConceptIndex()

    private struct Revision: Equatable {
        var recorder: Int
        var organizer: Int
    }

    private let context: LearningAssistantContext
    private let recorder: LearningRecorder
    private let organizer: LearningOrganizer
    private var cached: (revision: Revision, recall: LearningRecall)?

    init(
        context: LearningAssistantContext = .standard,
        recorder: LearningRecorder = .shared,
        organizer: LearningOrganizer = .shared
    ) {
        self.context = context
        self.recorder = recorder
        self.organizer = organizer
    }

    /// Concepts named in the selection, the ones with the most history first.
    func recall(mentionedIn text: String, limit: Int = 3) async -> LearningRecall {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty == false, text.count <= LearningRecall.selectionLimit else { return LearningRecall() }
        let all = await library()
        let concepts = LearningLibrary.concepts(mentionedIn: text, among: all.concepts, limit: limit)
        let evidence = Set(concepts.flatMap(\.entries).flatMap(\.item.evidence))
        return LearningRecall(concepts: concepts, eventsByID: all.eventsByID.filter { evidence.contains($0.key) })
    }

    private func library() async -> LearningRecall {
        let revision = Revision(recorder: recorder.revision, organizer: organizer.revision)
        if let cached, cached.revision == revision {
            return cached.recall
        }
        let (records, events) = await context.load()
        let eventsByID = Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let recall = LearningRecall(
            concepts: LearningLibrary.concepts(records: records, eventsByID: eventsByID),
            eventsByID: eventsByID
        )
        cached = (revision, recall)
        return recall
    }
}

/// The questions a paper's record still has open, offered in the reader when the paper
/// is opened again after a while.
struct LearningOpenQuestionNotice: Equatable, Sendable {
    struct Question: Equatable, Identifiable, Sendable {
        var item: LearningRecordItem
        /// Where the question was asked; nil when no event behind it has a position.
        var target: LearningEvent?

        var id: String { item.id }
    }

    /// Seconds the notice stays when the reader does nothing with it.
    static let displayDuration: Double = 10
    /// A paper opened again within this many seconds is still the same reading.
    static let quietInterval: TimeInterval = 6 * 3600
    static let questionLimit = 6

    var questions: [Question]

    /// Most recently updated first.
    init?(record: PaperLearningRecord, events: [LearningEvent]) {
        let eventsByID = Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        questions = record.items(of: .question)
            .filter { $0.isResolved == false }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(Self.questionLimit)
            .map { item in
                let sources = item.evidence.compactMap { eventsByID[$0] }
                return Question(item: item, target: sources.first(where: \.hasAnchor) ?? sources.first)
            }
        if questions.isEmpty { return nil }
    }

    @MainActor private static var lastOpenedAt: [UUID: Date] = [:]

    /// Notes that the paper was opened. True when it had not been opened in this run of
    /// the app, or not for a while: coming back to it then counts as reading it again.
    @MainActor
    static func noteOpened(paperID: UUID, now: Date = Date()) -> Bool {
        defer { lastOpenedAt[paperID] = now }
        guard let last = lastOpenedAt[paperID] else { return true }
        return now.timeIntervalSince(last) >= quietInterval
    }

    /// The notice for a paper being opened, nil when it has no open questions, was open
    /// recently, or the app is under test.
    @MainActor
    static func load(
        paperID: UUID,
        store: LearningRecordStore = .shared,
        log: LearningEventLog = .shared
    ) async -> LearningOpenQuestionNotice? {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              noteOpened(paperID: paperID),
              let record = try? await store.record(paperID: paperID),
              record.items.contains(where: { $0.kind == .question && $0.isResolved == false }) else { return nil }
        return LearningOpenQuestionNotice(record: record, events: await log.events(paperID: paperID))
    }
}
