import XCTest
@testable import ReadPaper

final class LearningEventTests: XCTestCase {
    private var root: URL!
    private let paperID = UUID()
    private let attachmentID = UUID()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LearningEventTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func note(
        id: UUID = UUID(),
        quote: String = "attention is all you need",
        body: String = "",
        at date: Date = Date(timeIntervalSince1970: 1_000)
    ) -> LearningEventSources.NoteValue {
        .init(
            id: id,
            attachmentID: attachmentID,
            quote: quote,
            body: body,
            pageIndex: 2,
            htmlSelector: nil,
            createdAt: date,
            modifiedAt: date
        )
    }

    private func conversation(
        action: SelectionAssistantAction,
        turns: [(String, String)],
        identity: String = "selection"
    ) -> SelectionAssistantConversationSnapshot {
        .init(
            selectionIdentity: identity,
            attachmentID: attachmentID,
            quote: "scaled dot-product attention",
            pageIndex: 3,
            action: action,
            scope: .nearby,
            turns: turns.map { SelectionAssistantConversationTurn(question: $0.0, answer: $0.1) },
            modifiedAt: Date(timeIntervalSince1970: 2_000)
        )
    }

    func testCollectorClassifiesEachSource() {
        let highlight = PDFAnnotationRecord(pageIndex: 1, kind: .highlight, bounds: .zero, color: .init(red: 1, green: 1, blue: 0, alpha: 1), quote: "marked text")
        let ink = PDFAnnotationRecord(pageIndex: 1, kind: .ink, bounds: .zero, color: .init(red: 1, green: 1, blue: 0, alpha: 1))
        let unquoted = PDFAnnotationRecord(pageIndex: 1, kind: .underline, bounds: .zero, color: .init(red: 1, green: 1, blue: 0, alpha: 1))
        let sticky = PDFAnnotationRecord(pageIndex: 4, kind: .text, bounds: .zero, color: .init(red: 1, green: 1, blue: 0, alpha: 1), contents: "check this")
        let sources = LearningEventSources(
            notes: [note(), note(body: "my thought"), note(quote: " ", body: " ")],
            conversations: [
                conversation(action: .explain, turns: [("", "It means…"), ("Why scaled?", "Because…"), ("And then?", "")]),
            ],
            annotations: [highlight, ink, unquoted, sticky].map { .init(attachmentID: attachmentID, record: $0) }
        )

        let events = LearningEventCollector.events(paperID: paperID, sources: sources)

        XCTAssertEqual(
            events.map(\.kind),
            [.highlight, .note, .highlight, .note, .explanation, .question]
        )
        XCTAssertEqual(events[1].text, "my thought")
        XCTAssertEqual(events[2].quote, "marked text")
        XCTAssertEqual(events[3].text, "check this")
        XCTAssertEqual(events[5].text, "Why scaled?")
        XCTAssertEqual(events[5].response, "Because…")
        XCTAssertEqual(events[5].pageIndex, 3)
        XCTAssertEqual(Set(events.map(\.id)).count, events.count)
    }

    func testHighlightOverSeveralLinesIsOneEventAndReplacesItsPerLineEvents() async throws {
        let color = PDFAnnotationColorValue(red: 1, green: 1, blue: 0, alpha: 1)
        let start = Date(timeIntervalSince1970: 10_000)
        func line(_ quote: String, at offset: TimeInterval, kind: PDFAnnotationKind = .highlight) -> PDFAnnotationRecord {
            PDFAnnotationRecord(
                pageIndex: 1, kind: kind, bounds: .zero, color: color, quote: quote,
                createdAt: start.addingTimeInterval(offset), modifiedAt: start.addingTimeInterval(offset)
            )
        }
        let records = [
            line("我们选择在预训练期间不使用任何由语言模", at: 0),
            line("型生成的合成数据，并努力避免和移除所收集", at: 0),
            line("数据源中的 AI 生成内容。", at: 1),
            line("a later highlight that ends with a hy-", at: 60),
            line("phen and wraps onto", at: 60),
            line("a third line", at: 60),
            line("underlined at the same moment", at: 60, kind: .underline),
        ]
        let annotations = records.map { LearningEventSources.Annotation(attachmentID: attachmentID, record: $0) }

        let events = LearningEventCollector.events(paperID: paperID, sources: .init(annotations: annotations))

        XCTAssertEqual(events.map(\.quote), [
            "我们选择在预训练期间不使用任何由语言模型生成的合成数据，并努力避免和移除所收集数据源中的 AI 生成内容。",
            "a later highlight that ends with a hy-phen and wraps onto a third line",
            "underlined at the same moment",
        ])
        XCTAssertEqual(events[0].subject, "annotation/\(records[0].id.uuidString)")
        XCTAssertEqual(events[0].replaces, [records[1], records[2]].map { "annotation/\($0.id.uuidString)" })
        XCTAssertNil(events[2].replaces)

        // A log written before lines were joined has one event per line.
        let log = LearningEventLog(rootDirectory: root)
        let perLine = records.prefix(3).map { record in
            LearningEvent(
                id: "annotation/\(record.id.uuidString)/old", subject: "annotation/\(record.id.uuidString)",
                paperID: paperID, kind: .highlight, occurredAt: record.createdAt, isBackfilled: false,
                attachmentID: attachmentID, pageIndex: 1, quote: record.quote
            )
        }
        let url = root.appendingPathComponent("Learning/events/\(paperID.uuidString).jsonl")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try perLine.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
            .joined(separator: "\n").appending("\n")
            .write(to: url, atomically: true, encoding: .utf8)

        _ = try await log.record(paperID: paperID, sources: .init(annotations: Array(annotations.prefix(3))))
        let shown = LearningEvent.latestRevisions(of: await log.events(paperID: paperID))

        XCTAssertEqual(shown.map(\.quote), [events[0].quote])

        // Once the joined highlight is organized, its old per-line events are not pending.
        var record = PaperLearningRecord(paperID: paperID)
        let stored = await log.events(paperID: paperID)
        XCTAssertEqual(record.pendingEvents(in: stored).map(\.id), [events[0].id])
        record.processedEventIDs = [events[0].id]
        XCTAssertTrue(record.pendingEvents(in: stored).isEmpty)
    }

    func testCitationIdentityIgnoresPositionInWriting() {
        let writingID = UUID()
        let record = WritingCitationRecord(
            citation: PaperCitation(paperID: paperID, pageIndex: 1, quotePrefix: "a quoted passage"),
            passage: "a quoted passage that goes on"
        )
        let other = WritingCitationRecord(citation: PaperCitation(paperID: UUID(), pageIndex: 1), passage: nil)
        func events(index: Int) -> [LearningEvent] {
            LearningEventCollector.events(
                paperID: paperID,
                sources: .init(citations: [
                    .init(writingID: writingID, index: index, record: record),
                    .init(writingID: writingID, index: index + 1, record: other),
                ])
            )
        }

        XCTAssertEqual(events(index: 0).map(\.id), events(index: 5).map(\.id))
        XCTAssertEqual(events(index: 0).count, 1)
        XCTAssertEqual(events(index: 0).first?.quote, "a quoted passage that goes on")
        XCTAssertEqual(events(index: 0).first?.writingID, writingID)
    }

    func testLogAppendsOnlyNewEventsAndMarksTheFirstCollectionAsBackfilled() async throws {
        let log = LearningEventLog(rootDirectory: root)
        let noteID = UUID()

        let first = try await log.record(paperID: paperID, sources: .init(notes: [note(id: noteID)]))
        XCTAssertEqual(first.map(\.isBackfilled), [true])

        let repeated = try await log.record(paperID: paperID, sources: .init(notes: [note(id: noteID)]))
        XCTAssertTrue(repeated.isEmpty)

        let edited = note(id: noteID, body: "now with a thought", at: Date(timeIntervalSince1970: 3_000))
        let second = try await log.record(paperID: paperID, sources: .init(notes: [edited, note()]))
        XCTAssertEqual(second.map(\.isBackfilled), [false, false])

        // The note is gone from the store; the log keeps both of its revisions.
        _ = try await log.record(paperID: paperID, sources: .init())
        let stored = await log.events(paperID: paperID)
        XCTAssertEqual(stored.count, 3)

        let latest = LearningEvent.latestRevisions(of: stored)
        XCTAssertEqual(latest.count, 2)
        XCTAssertEqual(latest.first { $0.subject == "note/\(noteID.uuidString)" }?.text, "now with a thought")
    }

    func testEmptyFirstCollectionStillEndsTheBackfill() async throws {
        let log = LearningEventLog(rootDirectory: root)
        _ = try await log.record(paperID: paperID, sources: .init())
        let events = try await log.record(paperID: paperID, sources: .init(notes: [note()]))
        XCTAssertEqual(events.map(\.isBackfilled), [false])
    }

    func testLogReadsConversationsAndAnnotationsFromTheNotesDirectory() async throws {
        let fileStore = PaperFileStore(applicationSupportDirectory: root)
        let notesDirectory = try fileStore.notesDirectory(for: paperID)
        let archive: [String: Any] = [
            "version": 1,
            "conversations": [try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(conversation(action: .ask, turns: [("What is d_k?", "The key dimension.")]))
            )],
        ]
        try JSONSerialization.data(withJSONObject: archive).write(
            to: notesDirectory.appendingPathComponent(SelectionAssistantConversationStore.archiveFileName)
        )
        try PDFAnnotationStore(fileStore: fileStore).save(
            [PDFAnnotationRecord(pageIndex: 0, kind: .highlight, bounds: .zero, color: .init(red: 1, green: 1, blue: 0, alpha: 1), quote: "marked")],
            paperID: paperID,
            attachmentID: attachmentID
        )

        let log = LearningEventLog(rootDirectory: root)
        let events = try await log.record(paperID: paperID, sources: .init(), notesDirectory: notesDirectory)

        XCTAssertEqual(Set(events.map(\.kind)), [.question, .highlight])
        XCTAssertEqual(events.first { $0.kind == .question }?.text, "What is d_k?")
        XCTAssertEqual(events.first { $0.kind == .highlight }?.attachmentID, attachmentID)
    }

    func testUnreadableLinesAreSkippedAndKept() async throws {
        let log = LearningEventLog(rootDirectory: root)
        _ = try await log.record(paperID: paperID, sources: .init(notes: [note()]))
        let url = root.appendingPathComponent("Learning/events/\(paperID.uuidString).jsonl")
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"kind\":\"fromTheFuture\"}\n".utf8))
        try handle.close()

        _ = try await log.record(
            paperID: paperID,
            sources: .init(notes: [note(body: "later", at: Date(timeIntervalSince1970: 5_000))])
        )

        let stored = await log.events(paperID: paperID)
        XCTAssertEqual(stored.count, 2)
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("fromTheFuture"))
        let all = await log.allEvents()
        XCTAssertEqual(all, stored.sorted { $0.occurredAt < $1.occurredAt })
    }

    func testPaneGroupsByKindAndByDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let events = LearningEventCollector.events(
            paperID: paperID,
            sources: .init(
                notes: [
                    note(at: Date(timeIntervalSince1970: 100)),
                    note(body: "thought", at: Date(timeIntervalSince1970: 90_000)),
                ],
                conversations: [conversation(action: .translate, turns: [("", "译文"), ("Why?", "Because.")])]
            )
        )

        let sections = LearningPaneView.sections(of: events)
        XCTAssertEqual(sections.map(\.group), [.questions, .lookups, .marks])
        XCTAssertEqual(sections.last?.events.map(\.kind), [.note, .highlight])

        let days = LearningPaneView.days(of: events, calendar: calendar)
        XCTAssertEqual(days.map(\.events.count), [1, 3])
        XCTAssertGreaterThan(days[0].day, days[1].day)
    }
}
