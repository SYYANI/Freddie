import Foundation

/// One thing the reader did to understand a paper: a highlight, a note, a question to the
/// assistant, a passage quoted in a writing. Events are appended to a per-paper log and
/// never rewritten, so the log keeps what the live stores drop (the assistant keeps 50
/// conversations per paper, a note only its latest text).
struct LearningEvent: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case highlight
        case note
        case translation
        case explanation
        case question
        case citation
    }

    /// Derived from the source record and its content, so collecting the same state twice
    /// yields the same ID and nothing is appended the second time.
    var id: String
    /// What this event is a revision of: a note, one turn of a conversation, a citation.
    /// A later event with the same subject replaces the earlier one when displayed.
    var subject: String
    var paperID: UUID
    var kind: Kind
    var occurredAt: Date
    /// Collected from records that existed before the log did, so `occurredAt` is the
    /// record's own timestamp rather than the time the reader acted.
    var isBackfilled: Bool
    var attachmentID: UUID?
    /// Zero-based, like `Note.pageIndex`.
    var pageIndex: Int?
    var htmlSelector: String?
    var quote: String?
    /// The reader's own words: a note's body or a question.
    var text: String?
    /// The assistant's answer.
    var response: String?
    var writingID: UUID?
    /// Subjects this event absorbs: a highlight over several lines is stored as one
    /// annotation per line, and logs written before the lines were joined hold one event
    /// for each. Those are no longer shown.
    var replaces: [String]?

    var citation: PaperCitation {
        PaperCitation(
            paperID: paperID,
            attachmentID: attachmentID,
            pageIndex: pageIndex,
            htmlSelector: htmlSelector,
            quotePrefix: quote
        )
    }

    var hasAnchor: Bool {
        pageIndex != nil || htmlSelector?.isEmpty == false
    }

    /// Translations and explanations are started by a quick action, so the question sent
    /// with them is the app's instruction, not the reader's words: it is not shown or
    /// handed to the organizer. Logs written before this rule still hold it, so reading
    /// the log applies it too. The ID keeps the question's digest so collecting the same
    /// turn again appends nothing.
    var withoutInstruction: LearningEvent {
        guard kind == .translation || kind == .explanation else { return self }
        var event = self
        event.text = nil
        return event
    }

    /// The latest revision of each subject that no other event replaces, oldest first.
    static func latestRevisions(of events: [LearningEvent]) -> [LearningEvent] {
        var replaced = Set<String>()
        for event in events {
            replaced.formUnion((event.replaces ?? []).filter { $0 != event.subject })
        }
        var latest: [String: LearningEvent] = [:]
        var order: [String] = []
        for event in events where replaced.contains(event.subject) == false {
            if latest[event.subject] == nil {
                order.append(event.subject)
            }
            latest[event.subject] = event
        }
        return order.compactMap { latest[$0] }.sorted { $0.occurredAt < $1.occurredAt }
    }
}

/// The current state of everything a paper's events are collected from.
struct LearningEventSources: Sendable {
    struct NoteValue: Equatable, Sendable {
        var id: UUID
        var attachmentID: UUID?
        var quote: String
        var body: String
        var pageIndex: Int?
        var htmlSelector: String?
        var createdAt: Date
        var modifiedAt: Date
    }

    struct Annotation: Equatable, Sendable {
        var attachmentID: UUID
        var record: PDFAnnotationRecord
    }

    var notes: [NoteValue] = []
    var conversations: [SelectionAssistantConversationSnapshot] = []
    var annotations: [Annotation] = []
    var citations: [WritingCitationMark] = []
}

extension LearningEventSources.NoteValue {
    init(_ note: Note) {
        self.init(
            id: note.id,
            attachmentID: note.attachmentID,
            quote: note.quote,
            body: note.body,
            pageIndex: note.pageIndex,
            htmlSelector: note.htmlSelector,
            createdAt: note.createdAt,
            modifiedAt: note.modifiedAt
        )
    }
}

enum LearningEventCollector {
    /// Every event the sources currently describe. The log appends the ones it does not
    /// have yet.
    static func events(
        paperID: UUID,
        sources: LearningEventSources,
        now: Date = Date()
    ) -> [LearningEvent] {
        var events: [LearningEvent] = []
        events += sources.notes.compactMap { noteEvent($0, paperID: paperID) }
        events += annotationEvents(sources.annotations, paperID: paperID)
        events += sources.conversations.flatMap { conversationEvents($0, paperID: paperID) }
        events += sources.citations.compactMap { citationEvent($0, paperID: paperID, now: now) }
        return events
    }

    private static func noteEvent(
        _ note: LearningEventSources.NoteValue,
        paperID: UUID
    ) -> LearningEvent? {
        let quote = normalized(note.quote)
        let body = normalized(note.body, collapsingWhitespace: false)
        guard quote != nil || body != nil else { return nil }
        let subject = "note/\(note.id.uuidString)"
        return LearningEvent(
            id: "\(subject)/\(digest(quote, body))",
            subject: subject,
            paperID: paperID,
            kind: body == nil ? .highlight : .note,
            occurredAt: body == nil ? note.createdAt : note.modifiedAt,
            isBackfilled: false,
            attachmentID: note.attachmentID,
            pageIndex: note.pageIndex,
            htmlSelector: normalized(note.htmlSelector),
            quote: quote,
            text: body
        )
    }

    /// Seconds between the first and last record of one markup gesture. The records are
    /// created together, but the sidecar keeps whole seconds.
    static let markupGroupInterval: TimeInterval = 1

    /// One event per text note and per markup gesture. PDFKit marks a selection up line by
    /// line, so a highlighted sentence that wraps is several records, each with one line of
    /// text; consecutive records of the same kind and color created together are one
    /// highlight to the reader.
    private static func annotationEvents(
        _ annotations: [LearningEventSources.Annotation],
        paperID: UUID
    ) -> [LearningEvent] {
        var events: [LearningEvent] = []
        var group: [LearningEventSources.Annotation] = []
        func flush() {
            if let event = markupEvent(group, paperID: paperID) {
                events.append(event)
            }
            group = []
        }
        for annotation in annotations {
            let record = annotation.record
            switch record.kind {
            case .ink:
                continue
            case .text:
                flush()
                guard let contents = normalized(record.contents, collapsingWhitespace: false) else { continue }
                let subject = "annotation/\(record.id.uuidString)"
                events.append(LearningEvent(
                    id: "\(subject)/\(digest(nil, contents))",
                    subject: subject,
                    paperID: paperID,
                    kind: .note,
                    occurredAt: record.modifiedAt,
                    isBackfilled: false,
                    attachmentID: annotation.attachmentID,
                    pageIndex: record.pageIndex,
                    text: contents
                ))
            case .highlight, .underline, .strikeOut:
                if let first = group.first,
                   first.attachmentID != annotation.attachmentID
                    || first.record.kind != record.kind
                    || first.record.color != record.color
                    || abs(record.createdAt.timeIntervalSince(first.record.createdAt)) > markupGroupInterval {
                    flush()
                }
                group.append(annotation)
            }
        }
        flush()
        return events
    }

    private static func markupEvent(
        _ group: [LearningEventSources.Annotation],
        paperID: UUID
    ) -> LearningEvent? {
        // Without the marked text there is nothing to learn from.
        let lines = group.filter { normalized($0.record.quote) != nil }
        guard let first = lines.first else { return nil }
        let quote = lines.compactMap { normalized($0.record.quote) }.reduce(into: "") { joined, line in
            joined = joinedLines(joined, line)
        }
        let subject = "annotation/\(first.record.id.uuidString)"
        let absorbed = lines.dropFirst().map { "annotation/\($0.record.id.uuidString)" }
        return LearningEvent(
            id: "\(subject)/\(digest(quote, nil))",
            subject: subject,
            paperID: paperID,
            kind: .highlight,
            occurredAt: first.record.createdAt,
            isBackfilled: false,
            attachmentID: first.attachmentID,
            pageIndex: first.record.pageIndex,
            quote: quote,
            replaces: absorbed.isEmpty ? nil : absorbed
        )
    }

    /// Joins two lines of a passage: no space inside CJK text or after a line-end hyphen,
    /// one space otherwise.
    static func joinedLines(_ first: String, _ second: String) -> String {
        guard let last = first.last, let next = second.first else { return first + second }
        if last == "-" || isCJK(last) || isCJK(next) {
            return first + second
        }
        return first + " " + second
    }

    private static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x2E80...0x9FFF, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFFEF, 0x20000...0x2FA1F: true
            default: false
            }
        }
    }

    private static func conversationEvents(
        _ conversation: SelectionAssistantConversationSnapshot,
        paperID: UUID
    ) -> [LearningEvent] {
        let thread = "assistant/\(digest(conversation.selectionIdentity))"
        return conversation.turns.enumerated().compactMap { index, turn in
            // An empty answer is still streaming or failed; it is collected once it exists.
            guard let answer = normalized(turn.answer, collapsingWhitespace: false) else { return nil }
            let question = normalized(turn.question, collapsingWhitespace: false)
            let kind: LearningEvent.Kind
            if index > 0 {
                kind = .question
            } else {
                switch conversation.action {
                case .translate: kind = .translation
                case .explain: kind = .explanation
                case .ask: kind = .question
                }
            }
            let subject = "\(thread)/\(index)"
            return LearningEvent(
                id: "\(subject)/\(digest(question))",
                subject: subject,
                paperID: paperID,
                kind: kind,
                occurredAt: conversation.modifiedAt,
                isBackfilled: false,
                attachmentID: conversation.attachmentID,
                pageIndex: conversation.pageIndex,
                htmlSelector: normalized(conversation.htmlSelector),
                quote: normalized(conversation.quote),
                text: question,
                response: answer
            ).withoutInstruction
        }
    }

    private static func citationEvent(
        _ mark: WritingCitationMark,
        paperID: UUID,
        now: Date
    ) -> LearningEvent? {
        let record = mark.record
        guard record.paperID == paperID else { return nil }
        let quote = normalized(record.passage) ?? normalized(record.quotePrefix)
        // Not keyed by the citation's position, so reordering a writing adds nothing.
        let id = "citation/\(mark.writingID.uuidString)/" + digest(
            record.attachmentID?.uuidString,
            record.pageIndex.map(String.init),
            record.htmlSelector,
            quote
        )
        return LearningEvent(
            id: id,
            subject: id,
            paperID: paperID,
            kind: .citation,
            // A writing only records when it was last saved, not when each citation was added.
            occurredAt: now,
            isBackfilled: false,
            attachmentID: record.attachmentID,
            pageIndex: record.pageIndex,
            htmlSelector: normalized(record.htmlSelector),
            quote: quote,
            writingID: mark.writingID
        )
    }

    private static func normalized(_ value: String?, collapsingWhitespace: Bool = true) -> String? {
        guard let value else { return nil }
        let text = collapsingWhitespace
            ? value.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
            : value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func digest(_ parts: String?...) -> String {
        String(Hashing.sha256Hex(parts.map { $0 ?? "" }.joined(separator: "\u{1F}")).prefix(16))
    }
}
