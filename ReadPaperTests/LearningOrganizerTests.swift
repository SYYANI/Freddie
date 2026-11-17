import SwiftData
import XCTest
@testable import ReadPaper

@MainActor
final class LearningOrganizerTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var defaultsName: String!
    private let paperID = UUID()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LearningOrganizerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defaultsName = "LearningOrganizerTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsName)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: defaultsName)
    }

    private func note(_ body: String, id: UUID = UUID(), at seconds: TimeInterval = 1_000) -> LearningEventSources.NoteValue {
        .init(
            id: id,
            attachmentID: nil,
            quote: "passage about \(body)",
            body: body,
            pageIndex: 1,
            htmlSelector: nil,
            createdAt: Date(timeIntervalSince1970: seconds),
            modifiedAt: Date(timeIntervalSince1970: seconds)
        )
    }

    private func makeContext() throws -> ModelContext {
        let schema = Schema([Paper.self, AppSettings.self, LLMProviderProfile.self, LLMModelProfile.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        context.insert(AppSettings())
        try context.save()
        return context
    }

    private var route: LLMModelRouteSnapshot {
        LLMModelRouteSnapshot(
            providerProfileID: UUID(), providerName: "Test provider", modelProfileID: UUID(),
            modelProfileName: "Test model", baseURL: "https://example.com/v1", apiKeyRef: "test-ref", modelName: "test-model"
        )
    }

    private var paper: LearningOrganizer.PaperContext {
        .init(id: paperID, title: "A Paper", abstract: "An abstract.")
    }

    // MARK: Patch

    func testPatchIsReadFromFencedOrChattyOutput() {
        let patch = LearningRecordPatch(modelOutput: """
        Here is the record:
        ```json
        {"items":[{"ref":null,"kind":"concept","title":"Attention","detail":"d","resolved":false,"evidence":["e1", 2]}, "junk"]}
        ```
        """)
        XCTAssertEqual(patch?.entries, [
            .init(ref: nil, kind: "concept", title: "Attention", detail: "d", resolved: false, evidence: ["e1"]),
        ])
        XCTAssertNil(LearningRecordPatch(modelOutput: "I could not find anything."))
        XCTAssertNil(LearningRecordPatch(modelOutput: "{\"entries\": []}"))
    }

    func testApplyKeepsOnlyEntriesBackedByKnownEvents() {
        var record = PaperLearningRecord(paperID: paperID)
        let aliases = ["e1": "event-1", "e2": "event-2"]
        let applied = record.apply(
            LearningRecordPatch(entries: [
                .init(ref: nil, kind: "question", title: "Why scale?", detail: nil, resolved: true, evidence: ["e1", "e9", "e1"]),
                .init(ref: nil, kind: "concept", title: "Invented", detail: nil, resolved: nil, evidence: ["e7"]),
                .init(ref: nil, kind: "takeaway", title: "No evidence", detail: nil, resolved: nil, evidence: []),
                .init(ref: nil, kind: "mystery", title: "Unknown kind", detail: nil, resolved: nil, evidence: ["e2"]),
                .init(ref: "i42", kind: "concept", title: "Dangling reference", detail: nil, resolved: nil, evidence: ["e2"]),
                .init(ref: nil, kind: "takeaway", title: String(repeating: "长", count: 400), detail: nil, resolved: nil, evidence: ["e2"]),
            ]),
            eventIDsByAlias: aliases
        )

        XCTAssertEqual(applied, 2)
        XCTAssertEqual(record.items.map(\.id), ["i1", "i2"])
        XCTAssertEqual(record.items[0].evidence, ["event-1"])
        XCTAssertTrue(record.items[0].isResolved)
        XCTAssertEqual(record.items[1].title.count, LearningRecordItem.titleLimit)
        XCTAssertEqual(record.nextItemNumber, 3)
    }

    func testUpdateMergesEvidenceAndRespectsTheReadersOwnStatus() {
        var record = PaperLearningRecord(paperID: paperID)
        record.apply(
            LearningRecordPatch(entries: [
                .init(ref: nil, kind: "question", title: "Q", detail: nil, resolved: false, evidence: ["e1"]),
                .init(ref: nil, kind: "question", title: "Q2", detail: nil, resolved: false, evidence: ["e1"]),
            ]),
            eventIDsByAlias: ["e1": "event-1"]
        )
        record.items[1].isResolved = false
        record.items[1].isResolvedByUser = true

        record.apply(
            LearningRecordPatch(entries: [
                .init(ref: "i1", kind: nil, title: nil, detail: "now answered", resolved: true, evidence: ["e1", "e2"]),
                .init(ref: "i2", kind: nil, title: "Q2 reworded", detail: nil, resolved: true, evidence: ["e2"]),
            ]),
            eventIDsByAlias: ["e1": "event-1", "e2": "event-2"]
        )

        XCTAssertEqual(record.items[0].title, "Q")
        XCTAssertEqual(record.items[0].detail, "now answered")
        XCTAssertTrue(record.items[0].isResolved)
        XCTAssertEqual(record.items[0].evidence, ["event-1", "event-2"])
        XCTAssertEqual(record.items[1].title, "Q2 reworded")
        XCTAssertFalse(record.items[1].isResolved, "The reader reopened it")
        XCTAssertEqual(record.items.count, 2)
    }

    // MARK: The reader's corrections

    private func recordWithTwoConcepts() -> PaperLearningRecord {
        var record = PaperLearningRecord(paperID: paperID)
        record.apply(
            LearningRecordPatch(entries: [
                .init(ref: nil, kind: "concept", title: "self attention", detail: "first", resolved: nil, evidence: ["e1"]),
                .init(ref: nil, kind: "concept", title: "BLEU", detail: "a metric", resolved: nil, evidence: ["e2"]),
            ]),
            eventIDsByAlias: ["e1": "event-1", "e2": "event-2"],
            now: Date(timeIntervalSince1970: 100)
        )
        return record
    }

    func testEditedEntryKeepsItsWordingButStillGathersEvidence() {
        var record = recordWithTwoConcepts()
        XCTAssertTrue(record.edit(itemID: "i1", title: "Self-Attention 自注意力", detail: "my words"))
        XCTAssertFalse(record.edit(itemID: "i1", title: "Self-Attention 自注意力", detail: "my words"), "Nothing changed")
        XCTAssertEqual(record.items[0].aliases, ["self attention"])

        record.apply(
            LearningRecordPatch(entries: [
                .init(ref: "i1", kind: nil, title: "Rewritten", detail: "rewritten", resolved: nil, evidence: ["e3"]),
                // The organizer meets the old name again: it is the renamed entry.
                .init(ref: nil, kind: "concept", title: "Self-attention", detail: "again", resolved: nil, evidence: ["e4"]),
            ]),
            eventIDsByAlias: ["e3": "event-3", "e4": "event-4"]
        )

        XCTAssertEqual(record.items.count, 2)
        XCTAssertEqual(record.items[0].title, "Self-Attention 自注意力")
        XCTAssertEqual(record.items[0].detail, "my words")
        XCTAssertEqual(record.items[0].evidence, ["event-1", "event-3", "event-4"])
    }

    func testNewEntryUnderAnExistingNameExtendsThatEntry() {
        var record = recordWithTwoConcepts()
        let applied = record.apply(
            LearningRecordPatch(entries: [
                .init(ref: nil, kind: "concept", title: "Self-Attention", detail: "second", resolved: nil, evidence: ["e3"]),
            ]),
            eventIDsByAlias: ["e3": "event-3"]
        )
        XCTAssertEqual(applied, 1)
        XCTAssertEqual(record.items.count, 2)
        XCTAssertEqual(record.items[0].title, "self attention")
        XCTAssertEqual(record.items[0].detail, "second")
        XCTAssertEqual(record.items[0].evidence, ["event-1", "event-3"])
    }

    func testRemovedEntryIsNotAddedAgainAndCanBeRestored() {
        var record = recordWithTwoConcepts()
        XCTAssertTrue(record.remove(itemID: "i2"))
        XCTAssertEqual(record.items.map(\.id), ["i1"])

        let applied = record.apply(
            LearningRecordPatch(entries: [
                .init(ref: nil, kind: "concept", title: "bleu", detail: "back", resolved: nil, evidence: ["e3"]),
                .init(ref: "i2", kind: nil, title: nil, detail: "back", resolved: nil, evidence: ["e3"]),
                // Another kind under the same words is another entry.
                .init(ref: nil, kind: "takeaway", title: "BLEU", detail: nil, resolved: nil, evidence: ["e3"]),
            ]),
            eventIDsByAlias: ["e3": "event-3"]
        )
        XCTAssertEqual(applied, 1)
        XCTAssertEqual(record.items.map(\.kind), [.concept, .takeaway])

        XCTAssertTrue(record.restore(itemID: "i2"))
        XCTAssertNil(record.removedItems)
        XCTAssertEqual(record.items.last?.detail, "a metric")
        XCTAssertFalse(record.restore(itemID: "i2"))
    }

    func testRenamingToAnotherEntrysNameMergesThem() {
        var record = recordWithTwoConcepts()
        XCTAssertTrue(record.edit(itemID: "i2", title: "Self Attention", detail: nil))
        XCTAssertEqual(record.items.count, 1)
        XCTAssertEqual(record.items[0].id, "i2")
        XCTAssertEqual(record.items[0].evidence, ["event-2", "event-1"])
        XCTAssertEqual(record.items[0].detail, "first", "The merged entry's detail fills the missing one")
        XCTAssertEqual(record.items[0].aliases, ["BLEU"])
    }

    func testChangingKindPinsTheEntry() {
        var record = recordWithTwoConcepts()
        XCTAssertTrue(record.setKind(.takeaway, itemID: "i2"))
        XCTAssertFalse(record.setKind(.takeaway, itemID: "i2"))
        XCTAssertEqual(record.items[1].kind, .takeaway)
        XCTAssertTrue(record.items[1].isPinned)
    }

    func testConceptRenamedInAnotherPaperTakesTheReadersName() {
        var other = recordWithTwoConcepts()
        other.edit(itemID: "i1", title: "Self-Attention", detail: "first")
        other.edit(itemID: "i2", title: "BLEU score", detail: nil)
        var elsewhere = PaperLearningRecord(paperID: UUID())
        elsewhere.apply(
            LearningRecordPatch(entries: [
                .init(ref: nil, kind: "concept", title: "BLEU", detail: nil, resolved: nil, evidence: ["e1"]),
            ]),
            eventIDsByAlias: ["e1": "event-9"]
        )
        // "self attention" and "Self-Attention" are the same name, and "BLEU" is still
        // what another paper calls its concept: neither is a replaced name.
        XCTAssertEqual(LearningLibrary.conceptRenames(records: [other, elsewhere]), [:])
        let renames = LearningLibrary.conceptRenames(records: [other])
        XCTAssertEqual(renames, ["bleu": "BLEU score"])

        var record = PaperLearningRecord(paperID: UUID())
        record.apply(
            LearningRecordPatch(entries: [
                .init(ref: nil, kind: "concept", title: "Bleu", detail: nil, resolved: nil, evidence: ["e1"]),
                .init(ref: nil, kind: "takeaway", title: "Bleu", detail: nil, resolved: nil, evidence: ["e1"]),
            ]),
            eventIDsByAlias: ["e1": "event-5"],
            conceptRenames: renames
        )
        XCTAssertEqual(record.items.map(\.title), ["BLEU score", "Bleu"])
    }

    func testPromptMarksEditedAndRemovedEntries() {
        var record = recordWithTwoConcepts()
        record.edit(itemID: "i1", title: "Self-Attention", detail: "mine")
        record.remove(itemID: "i2")
        let batch = LearningOrganizerPrompt.batches(of: LearningEventCollector.events(
            paperID: paperID, sources: .init(notes: [note("one")])
        ))[0]
        let user = LearningOrganizerPrompt.messages(
            title: "T", abstract: "", record: record, batch: batch, languageName: "English"
        )[1].content
        XCTAssertTrue(user.contains("[i1] concept (edited by the reader): Self-Attention | mine"))
        XCTAssertTrue(user.contains("Removed by the reader:\n- concept: BLEU"))
        XCTAssertFalse(user.contains("[i2]"))
    }

    func testEntriesChangedAfterTheLastVisitAreUnseenButTheReadersEditsAreNot() async throws {
        let store = LearningRecordStore(rootDirectory: root)
        let organizer = LearningOrganizer(log: LearningEventLog(rootDirectory: root), store: store, defaults: defaults)
        let never = await organizer.markSeen(paperID: paperID, now: Date(timeIntervalSince1970: 50))
        XCTAssertNil(never)
        let untouched = try await store.record(paperID: paperID)
        XCTAssertNil(untouched.lastSeenAt, "Looking at a paper without a record writes nothing")

        let base = recordWithTwoConcepts()
        try await store.update(paperID: paperID) { record in
            record = base
            record.organizedAt = Date(timeIntervalSince1970: 100)
        }
        let first = await organizer.markSeen(paperID: paperID, now: Date(timeIntervalSince1970: 150))
        XCTAssertNil(first)
        await organizer.editItem("i1", title: "Renamed", detail: nil, paperID: paperID)
        try await store.update(paperID: paperID) { record in
            _ = record.apply(
                LearningRecordPatch(entries: [
                    .init(ref: "i2", kind: nil, title: nil, detail: "more", resolved: nil, evidence: ["e1"]),
                ]),
                eventIDsByAlias: ["e1": "event-7"],
                now: Date(timeIntervalSince1970: 200)
            )
        }
        let second = await organizer.markSeen(paperID: paperID, now: Date(timeIntervalSince1970: 250))
        XCTAssertEqual(second, Date(timeIntervalSince1970: 150))
        let record = try await store.record(paperID: paperID)
        XCTAssertEqual(record.unseenItemIDs(since: second), ["i2"])
        XCTAssertEqual(record.unseenItemIDs(since: nil), [])
        XCTAssertEqual(record.items.first { $0.id == "i1" }?.title, "Renamed")
    }

    func testItemLimitPerKind() {
        var record = PaperLearningRecord(paperID: paperID)
        let entries = (0..<(PaperLearningRecord.itemLimitPerKind + 5)).map {
            LearningRecordPatch.Entry(ref: nil, kind: "takeaway", title: "T\($0)", detail: nil, resolved: nil, evidence: ["e1"])
        }
        record.apply(LearningRecordPatch(entries: entries), eventIDsByAlias: ["e1": "event-1"])
        XCTAssertEqual(record.items.count, PaperLearningRecord.itemLimitPerKind)
    }

    // MARK: Prompt

    func testBatchesRestartAliasesAndPromptCarriesRecordAndLanguage() {
        let events = LearningEventCollector.events(
            paperID: paperID,
            sources: .init(notes: (0..<(LearningOrganizerPrompt.batchEventLimit + 2)).map { note("thought \($0)") })
        )
        let batches = LearningOrganizerPrompt.batches(of: events)

        XCTAssertEqual(batches.map(\.events.count), [LearningOrganizerPrompt.batchEventLimit, 2])
        XCTAssertEqual(batches[1].eventIDsByAlias["e1"], events[LearningOrganizerPrompt.batchEventLimit].id)
        XCTAssertTrue(batches[1].eventText.hasPrefix("[e1] note"))
        XCTAssertFalse(batches[0].eventText.contains(events[0].id), "Event IDs stay out of the prompt")

        var record = PaperLearningRecord(paperID: paperID)
        record.apply(
            LearningRecordPatch(entries: [.init(ref: nil, kind: "question", title: "Why?", detail: nil, resolved: false, evidence: ["e1"])]),
            eventIDsByAlias: batches[0].eventIDsByAlias
        )
        let messages = LearningOrganizerPrompt.messages(
            title: "A Paper", abstract: "An abstract.", record: record, batch: batches[1], languageName: "中文（简体）"
        )
        XCTAssertTrue(messages[0].content.contains("中文（简体）"))
        XCTAssertTrue(messages[1].content.contains("[i1] question (open): Why?"))
        XCTAssertTrue(messages[1].content.contains("reader's note: thought \(LearningOrganizerPrompt.batchEventLimit)"))
    }

    // MARK: Organizer

    private func makeOrganizer(
        log: LearningEventLog,
        store: LearningRecordStore,
        respond: @escaping (LLMCompletionRequest) throws -> String
    ) -> LearningOrganizer {
        let route = route
        return LearningOrganizer(
            log: log,
            store: store,
            defaults: defaults,
            resolveRoute: { _, _ in route },
            loadAPIKey: { _ in "test-key" },
            complete: { LLMCompletionResponse(text: try respond($0), resolvedEndpoint: nil) }
        )
    }

    func testOrganizesPendingEventsOnceAndMarksEarlierRevisionsProcessed() async throws {
        let log = LearningEventLog(rootDirectory: root)
        let store = LearningRecordStore(rootDirectory: root)
        let context = try makeContext()
        let noteID = UUID()
        _ = try await log.record(paperID: paperID, sources: .init(notes: [note("first draft", id: noteID)]))
        _ = try await log.record(paperID: paperID, sources: .init(notes: [note("final thought", id: noteID, at: 2_000), note("b"), note("c")]))

        var requests: [LLMCompletionRequest] = []
        let organizer = makeOrganizer(log: log, store: store) { request in
            requests.append(request)
            return #"{"items":[{"ref":null,"kind":"takeaway","title":"A point","evidence":["e1","e2"]}]}"#
        }

        let applied = await organizer.organize(paper, trigger: .automatic, modelContext: context)

        XCTAssertEqual(applied, 1)
        XCTAssertEqual(requests.count, 1)
        XCTAssertFalse(requests[0].messages[1].content.contains("first draft"), "Only the latest revision is sent")
        XCTAssertTrue(requests[0].messages[1].content.contains("final thought"))
        let record = try await store.record(paperID: paperID)
        XCTAssertEqual(record.items.first?.evidence.count, 2)
        XCTAssertEqual(record.processedEventIDs.count, 4, "Both revisions of the edited note are covered")
        XCTAssertEqual(record.modelName, "test-model")
        XCTAssertNotNil(record.organizedAt)

        let again = await organizer.organize(paper, trigger: .manual, modelContext: context)
        XCTAssertEqual(again, 0)
        XCTAssertEqual(requests.count, 1)
    }

    func testAutomaticRunsWaitForEnoughEventsAndThePreference() async throws {
        let log = LearningEventLog(rootDirectory: root)
        let store = LearningRecordStore(rootDirectory: root)
        let context = try makeContext()
        _ = try await log.record(paperID: paperID, sources: .init(notes: [note("a"), note("b")]))
        var requestCount = 0
        let organizer = makeOrganizer(log: log, store: store) { _ in
            requestCount += 1
            return #"{"items":[]}"#
        }

        await organizer.organize(paper, trigger: .automatic, modelContext: context)
        XCTAssertEqual(requestCount, 0, "Two events are below the threshold")

        _ = try await log.record(paperID: paperID, sources: .init(notes: [note("c")]))
        defaults.set(false, forKey: LearningPreferences.automaticOrganizingKey)
        await organizer.organize(paper, trigger: .automatic, modelContext: context)
        XCTAssertEqual(requestCount, 0, "Turned off")

        await organizer.organize(paper, trigger: .manual, modelContext: context)
        XCTAssertEqual(requestCount, 1)
        let record = try await store.record(paperID: paperID)
        XCTAssertEqual(record.processedEventIDs.count, 3, "An empty answer still covers the events")
    }

    func testUnreadableAnswerIsRetriedOnceThenReportedWithoutRetryingAutomatically() async throws {
        let log = LearningEventLog(rootDirectory: root)
        let store = LearningRecordStore(rootDirectory: root)
        let context = try makeContext()
        _ = try await log.record(paperID: paperID, sources: .init(notes: [note("a"), note("b"), note("c")]))
        var requestCount = 0
        var answer = "Sorry, I cannot do that."
        let organizer = makeOrganizer(log: log, store: store) { _ in
            requestCount += 1
            return answer
        }

        await organizer.organize(paper, trigger: .automatic, modelContext: context)
        XCTAssertEqual(requestCount, 2)
        XCTAssertNotNil(organizer.failures[paperID])
        let failed = try await store.record(paperID: paperID)
        XCTAssertTrue(failed.processedEventIDs.isEmpty)

        await organizer.organize(paper, trigger: .automatic, modelContext: context)
        XCTAssertEqual(requestCount, 2, "The same events are not retried by themselves")

        answer = #"{"items":[{"kind":"concept","title":"C","evidence":["e3"]}]}"#
        await organizer.organize(paper, trigger: .manual, modelContext: context)
        XCTAssertEqual(requestCount, 3)
        XCTAssertNil(organizer.failures[paperID])
        let record = try await store.record(paperID: paperID)
        XCTAssertEqual(record.items.map(\.title), ["C"])
    }

    func testReadersResolutionSurvivesTheNextRun() async throws {
        let log = LearningEventLog(rootDirectory: root)
        let store = LearningRecordStore(rootDirectory: root)
        let context = try makeContext()
        _ = try await log.record(paperID: paperID, sources: .init(notes: [note("why?")]))
        var answer = #"{"items":[{"kind":"question","title":"Why?","resolved":false,"evidence":["e1"]}]}"#
        let organizer = makeOrganizer(log: log, store: store) { _ in answer }

        await organizer.organize(paper, trigger: .manual, modelContext: context)
        await organizer.setResolved(true, itemID: "i1", paperID: paperID)
        _ = try await log.record(paperID: paperID, sources: .init(notes: [note("still unsure")]))
        answer = #"{"items":[{"ref":"i1","resolved":false,"detail":"asked again","evidence":["e1"]}]}"#
        await organizer.organize(paper, trigger: .manual, modelContext: context)

        let record = try await store.record(paperID: paperID)
        let item = record.items[0]
        XCTAssertTrue(item.isResolved)
        XCTAssertEqual(item.detail, "asked again")
        XCTAssertEqual(item.evidence.count, 2)
        XCTAssertEqual(LearningPaneView.recordSections(of: record).map(\.group), [.resolvedQuestions])
    }

    func testNewerRecordIsNeitherReadNorOverwritten() async throws {
        let log = LearningEventLog(rootDirectory: root)
        let store = LearningRecordStore(rootDirectory: root)
        let context = try makeContext()
        _ = try await log.record(paperID: paperID, sources: .init(notes: [note("a")]))
        let url = root.appendingPathComponent("Learning/papers/\(paperID.uuidString).json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let newer = Data(#"{"version":99,"paperID":"\#(paperID.uuidString)","future":true}"#.utf8)
        try newer.write(to: url)
        let organizer = makeOrganizer(log: log, store: store) { _ in
            XCTFail("A record from a newer version must not be organized")
            return ""
        }

        await organizer.organize(paper, trigger: .manual, modelContext: context)

        XCTAssertNotNil(organizer.failures[paperID])
        XCTAssertEqual(try Data(contentsOf: url), newer)
    }

    func testLearningRouteReportsTheFirstChoiceWhenNothingResolves() throws {
        let schema = Schema([AppSettings.self, LLMProviderProfile.self, LLMModelProfile.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let settings = AppSettings()
        context.insert(settings)
        let resolver = LLMRouteResolver(userDefaults: defaults)

        XCTAssertThrowsError(try resolver.resolveLearningRoute(settings: settings, modelContext: context)) {
            XCTAssertEqual($0 as? LLMRouteError, .assistantModelNotSelected)
        }
        defaults.set(UUID().uuidString, forKey: LearningPreferences.modelProfileIDKey)
        XCTAssertThrowsError(try resolver.resolveLearningRoute(settings: settings, modelContext: context)) {
            XCTAssertEqual($0 as? LLMRouteError, .modelNotFound)
        }
    }
}
