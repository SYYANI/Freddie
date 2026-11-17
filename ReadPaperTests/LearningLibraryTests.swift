import XCTest
@testable import ReadPaper

@MainActor
final class LearningLibraryTests: XCTestCase {
    private let paperA = UUID()
    private let paperB = UUID()

    private func event(
        _ id: String,
        _ kind: LearningEvent.Kind,
        paper: UUID,
        at seconds: TimeInterval,
        text: String? = nil,
        backfilled: Bool = false
    ) -> LearningEvent {
        LearningEvent(
            id: id, subject: id, paperID: paper, kind: kind,
            occurredAt: Date(timeIntervalSince1970: seconds), isBackfilled: backfilled,
            pageIndex: 1, quote: "passage", text: text
        )
    }

    private func item(
        _ id: String,
        _ kind: LearningRecordItem.Kind,
        _ title: String,
        evidence: [String],
        at seconds: TimeInterval,
        resolved: Bool = false
    ) -> LearningRecordItem {
        LearningRecordItem(
            id: id, kind: kind, title: title, detail: "about \(title)", isResolved: resolved,
            isResolvedByUser: false, evidence: evidence,
            createdAt: Date(timeIntervalSince1970: seconds), updatedAt: Date(timeIntervalSince1970: seconds)
        )
    }

    private func record(_ paperID: UUID, _ items: [LearningRecordItem]) -> PaperLearningRecord {
        var record = PaperLearningRecord(paperID: paperID)
        record.items = items
        return record
    }

    func testConceptsGroupAcrossPapersByNormalizedNameAndDeriveStageByRule() {
        let events = [
            event("a1", .explanation, paper: paperA, at: 10),
            event("a2", .highlight, paper: paperA, at: 20),
            event("b1", .question, paper: paperB, at: 30),
            event("c1", .translation, paper: paperA, at: 40),
            event("d1", .note, paper: paperB, at: 50, text: "in my own words"),
        ]
        let eventsByID = Dictionary(uniqueKeysWithValues: events.map { ($0.id, $0) })
        let records = [
            record(paperA, [
                item("i1", .concept, "Self-Attention", evidence: ["a1", "a2"], at: 100),
                item("i2", .concept, "Beam search", evidence: ["c1"], at: 110),
                item("i3", .takeaway, "self attention", evidence: ["a2"], at: 120),
            ]),
            record(paperB, [
                item("i1", .concept, "self  attention", evidence: ["b1"], at: 200),
                item("i2", .concept, "Label smoothing", evidence: ["d1", "missing"], at: 90),
            ]),
        ]

        let concepts = LearningLibrary.concepts(records: records, eventsByID: eventsByID)

        XCTAssertEqual(concepts.map(\.name), ["Self-Attention", "Beam search", "Label smoothing"])
        let attention = concepts[0]
        XCTAssertEqual(attention.paperIDs, [paperB, paperA])
        XCTAssertEqual(attention.lookupCount, 2)
        XCTAssertEqual(attention.stage, .recurring, "Met in two papers")
        XCTAssertEqual(concepts[1].stage, .new)
        XCTAssertEqual(concepts[2].stage, .writtenAbout, "The reader wrote a note about it")

        XCTAssertEqual(
            LearningLibrary.knownConceptNames(records: records, excluding: paperB),
            ["Beam search", "Self-Attention"]
        )
    }

    func testThreeLookupsInOnePaperMakeAConceptRecurring() {
        let events = (1...3).map { event("e\($0)", .explanation, paper: paperA, at: Double($0)) }
        let concepts = LearningLibrary.concepts(
            records: [record(paperA, [item("i1", .concept, "BLEU", evidence: events.map(\.id), at: 10)])],
            eventsByID: Dictionary(uniqueKeysWithValues: events.map { ($0.id, $0) })
        )
        XCTAssertEqual(concepts.first?.stage, .recurring)
    }

    func testMentionedConceptsMatchWholeLatinWordsAndCJKSubstrings() {
        func concept(_ name: String, lookups: Int = 1) -> LearningConcept {
            LearningConcept(
                id: LearningLibrary.normalizedName(name), name: name, entries: [],
                lookupCount: lookups, isWrittenAbout: false, updatedAt: .distantPast
            )
        }
        let concepts = [concept("RNN"), concept("Self-Attention", lookups: 4), concept("注意力"), concept("x"), concept("dropout")]

        XCTAssertEqual(
            LearningLibrary.concepts(mentionedIn: "Unlike an RNN, self attention (自注意力机制) is parallel; learnng", among: concepts).map(\.name),
            ["Self-Attention", "注意力", "RNN"]
        )
        XCTAssertTrue(LearningLibrary.concepts(mentionedIn: "learnng RNNs with xs", among: concepts).isEmpty)
        XCTAssertEqual(LearningLibrary.concepts(mentionedIn: "RNN dropout 注意力 self-attention", among: concepts, limit: 2).count, 2)
    }

    func testWeeksSummarizeActivityNewConceptsAndOpenQuestions() {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let week1 = Date(timeIntervalSince1970: 1_700_000_000) // Tue 14 Nov 2023
        let week2 = week1.addingTimeInterval(7 * 86_400)
        let events = [
            event("a1", .question, paper: paperA, at: week1.timeIntervalSince1970),
            event("a2", .highlight, paper: paperA, at: week1.timeIntervalSince1970 + 60),
            event("b1", .note, paper: paperB, at: week1.timeIntervalSince1970 + 120, text: "t"),
            event("b2", .citation, paper: paperB, at: week2.timeIntervalSince1970, backfilled: true),
            event("b3", .highlight, paper: paperB, at: week2.timeIntervalSince1970 + 60),
        ]
        let records = [
            record(paperA, [
                item("i1", .concept, "Attention", evidence: ["a1"], at: week1.timeIntervalSince1970),
                item("i2", .question, "Open?", evidence: ["a1"], at: week1.timeIntervalSince1970),
                item("i3", .question, "Settled?", evidence: ["a1"], at: week1.timeIntervalSince1970, resolved: true),
                item("i4", .takeaway, "A point", evidence: ["a2"], at: week1.timeIntervalSince1970),
            ]),
            // Met again in another paper a week later: not new that week.
            record(paperB, [item("i1", .concept, "attention", evidence: ["b3"], at: week2.timeIntervalSince1970)]),
        ]

        let weeks = LearningLibrary.weeks(events: events, records: records, calendar: calendar)

        XCTAssertEqual(weeks.count, 2)
        XCTAssertEqual(weeks[0].eventCount, 1, "A backfilled citation has no real date")
        XCTAssertEqual(weeks[0].papers.map(\.paperID), [paperB])
        XCTAssertTrue(weeks[0].newConcepts.isEmpty)
        XCTAssertEqual(weeks[1].eventCount, 3)
        XCTAssertEqual(weeks[1].papers.first, .init(paperID: paperA, eventCount: 2))
        XCTAssertEqual(weeks[1].newConcepts.map(\.item.title), ["Attention"])
        XCTAssertEqual(weeks[1].openQuestions.map(\.item.title), ["Open?"])
        XCTAssertEqual(calendar.dateComponents([.day], from: weeks[1].start, to: weeks[1].end).day, 6)
    }

    func testAssistantContextTurnsMentionedConceptsIntoNoteSources() async {
        let events = [event("a1", .explanation, paper: paperA, at: 10)]
        let records = [record(paperA, [item("i1", .concept, "Label smoothing", evidence: ["a1"], at: 100)])]
        let context = LearningAssistantContext { (records, events) }

        let sources = await context.sources(
            mentionedIn: "We use label smoothing of 0.1",
            paperTitles: [paperA: "Attention Is All You Need"]
        )

        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(sources[0].kind, .userNote)
        XCTAssertTrue(sources[0].title.contains("Label smoothing"))
        XCTAssertTrue(sources[0].excerpt.contains("about Label smoothing"))
        XCTAssertTrue(sources[0].excerpt.contains("Attention Is All You Need"))
        let none = await context.sources(mentionedIn: "nothing relevant", paperTitles: [:])
        XCTAssertTrue(none.isEmpty)
        let empty = await LearningAssistantContext.none.sources(mentionedIn: "label smoothing", paperTitles: [:])
        XCTAssertTrue(empty.isEmpty)
    }

    func testSelectionRecallFindsConceptsByNameOrEarlierNameAndSkipsPassages() async {
        let events = [
            event("a1", .explanation, paper: paperA, at: 10),
            event("b1", .question, paper: paperB, at: 20),
        ]
        var renamed = item("i1", .concept, "Self-Attention", evidence: ["b1"], at: 200)
        renamed.aliases = ["intra-attention"]
        let records = [
            record(paperA, [item("i1", .concept, "Label smoothing", evidence: ["a1"], at: 100)]),
            record(paperB, [renamed]),
        ]
        let index = LearningConceptIndex(
            context: LearningAssistantContext { (records, events) },
            recorder: LearningRecorder(log: LearningEventLog(rootDirectory: FileManager.default.temporaryDirectory)),
            organizer: LearningOrganizer(isAutomaticAllowed: false)
        )

        let byName = await index.recall(mentionedIn: " label smoothing ")
        XCTAssertEqual(byName.concepts.map(\.name), ["Label smoothing"])
        XCTAssertEqual(Array(byName.eventsByID.keys), ["a1"])
        let target = byName.citation(for: byName.concepts[0].entries[0])
        XCTAssertEqual(target.citation.paperID, paperA)
        XCTAssertEqual(target.quote, "passage")

        let byAlias = await index.recall(mentionedIn: "Intra attention")
        XCTAssertEqual(byAlias.concepts.map(\.name), ["Self-Attention"])
        let unrelated = await index.recall(mentionedIn: "gradient")
        XCTAssertTrue(unrelated.isEmpty)
        let passage = await index.recall(
            mentionedIn: String(repeating: "label smoothing ", count: LearningRecall.selectionLimit / 8)
        )
        XCTAssertTrue(passage.isEmpty, "A long selection is a passage, not a term")
    }

    func testWritingAboutAConceptQuotesAPassageTheReaderCanReturnTo() {
        var unanchored = event("a1", .explanation, paper: paperA, at: 10)
        unanchored.pageIndex = nil
        var anchored = event("b1", .question, paper: paperB, at: 20)
        anchored.quote = "the anchored passage"
        var bare = event("a2", .note, paper: paperA, at: 30)
        bare.quote = nil
        let eventsByID = ["a1": unanchored, "b1": anchored, "a2": bare]
        let concepts = LearningLibrary.concepts(
            records: [
                record(paperA, [item("i1", .concept, "Term", evidence: ["a2", "a1"], at: 300)]),
                record(paperB, [item("i1", .concept, "term", evidence: ["b1"], at: 100)]),
            ],
            eventsByID: eventsByID
        )
        let source = LearningPaneView.writingSource(for: concepts[0], eventsByID: eventsByID)
        XCTAssertEqual(source.citation.paperID, paperB)
        XCTAssertEqual(source.quote, "the anchored passage")

        // Once that passage is quoted in a writing, the concept counts as written about.
        XCTAssertEqual(concepts[0].stage, .recurring)
        var quotation = event("c1", .citation, paper: paperB, at: 40)
        quotation.quote = "the anchored\n passage"
        var all = eventsByID
        all["c1"] = quotation
        let afterWriting = LearningLibrary.concepts(
            records: [record(paperB, [item("i1", .concept, "term", evidence: ["b1"], at: 100)])],
            eventsByID: all
        )
        XCTAssertEqual(afterWriting[0].stage, .writtenAbout)

        let onlyBare = LearningPaneView.writingSource(for: concepts[0], eventsByID: ["a2": bare])
        XCTAssertEqual(onlyBare.citation.paperID, paperA)
        XCTAssertNil(onlyBare.quote)
        let nothing = LearningPaneView.writingSource(for: concepts[0], eventsByID: [:])
        XCTAssertEqual(nothing.citation.paperID, paperA)
        XCTAssertFalse(nothing.citation.hasDestination)
    }

    func testOpenQuestionNoticeListsOpenQuestionsNewestFirstAndOnlyOnReturning() {
        let events = [event("a1", .question, paper: paperA, at: 10)]
        var paperRecord = record(paperA, [
            item("i1", .question, "Older?", evidence: ["a1"], at: 100),
            item("i2", .question, "Settled?", evidence: ["a1"], at: 300, resolved: true),
            item("i3", .question, "Newer?", evidence: ["missing"], at: 200),
            item("i4", .concept, "Term", evidence: ["a1"], at: 400),
        ])
        let notice = LearningOpenQuestionNotice(record: paperRecord, events: events)
        XCTAssertEqual(notice?.questions.map(\.item.title), ["Newer?", "Older?"])
        XCTAssertNil(notice?.questions[0].target)
        XCTAssertEqual(notice?.questions[1].target?.id, "a1")
        paperRecord.items.removeAll { $0.isResolved == false && $0.kind == .question }
        XCTAssertNil(LearningOpenQuestionNotice(record: paperRecord, events: events))

        let paper = UUID()
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(LearningOpenQuestionNotice.noteOpened(paperID: paper, now: start))
        XCTAssertFalse(LearningOpenQuestionNotice.noteOpened(paperID: paper, now: start.addingTimeInterval(600)))
        XCTAssertFalse(
            LearningOpenQuestionNotice.noteOpened(
                paperID: paper,
                now: start.addingTimeInterval(600 + LearningOpenQuestionNotice.quietInterval - 1)
            ),
            "Each visit counts, so a paper kept at hand stays quiet"
        )
        XCTAssertTrue(
            LearningOpenQuestionNotice.noteOpened(
                paperID: paper,
                now: start.addingTimeInterval(1_200 + 2 * LearningOpenQuestionNotice.quietInterval)
            )
        )
    }

    func testKnownConceptsReachTheOrganizerPrompt() {
        let batch = LearningOrganizerPrompt.batches(of: [event("a1", .explanation, paper: paperA, at: 10)])[0]
        let messages = LearningOrganizerPrompt.messages(
            title: "T", abstract: "", record: PaperLearningRecord(paperID: paperA), batch: batch,
            languageName: "English", knownConcepts: ["Self-Attention", "BLEU"]
        )
        XCTAssertTrue(messages[1].content.contains("Self-Attention; BLEU"))
        let without = LearningOrganizerPrompt.messages(
            title: "T", abstract: "", record: PaperLearningRecord(paperID: paperA), batch: batch, languageName: "English"
        )
        XCTAssertFalse(without[1].content.contains("other papers"))
    }
}
