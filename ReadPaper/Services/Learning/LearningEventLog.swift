import Foundation

/// The append-only learning log: one JSON Lines file per paper in
/// `Application Support/ReadPaper/Learning/events/`. Kept out of SwiftData (an older
/// version of the app drops tables it does not know) and out of the paper's own folder
/// (records built from the events outlive a deleted paper). All file work happens on
/// this actor, away from the main thread.
actor LearningEventLog {
    static let shared = LearningEventLog()

    private let rootOverride: URL?
    private let fileManager = FileManager()

    /// `rootDirectory` is the `ReadPaper` application support directory.
    init(rootDirectory: URL? = nil) {
        rootOverride = rootDirectory
    }

    /// Appends the events the sources describe and the log does not have yet. Returns
    /// them. `notesDirectory` is the paper's `notes` folder, read for assistant
    /// conversations and PDF annotations.
    @discardableResult
    func record(
        paperID: UUID,
        sources: LearningEventSources,
        notesDirectory: URL? = nil,
        now: Date = Date()
    ) throws -> [LearningEvent] {
        var sources = sources
        if let notesDirectory {
            sources.conversations += Self.conversations(in: notesDirectory)
            sources.annotations += Self.annotations(in: notesDirectory, fileManager: fileManager)
        }

        let url = try fileURL(paperID: paperID)
        let isFirstCollection = fileManager.fileExists(atPath: url.path) == false
        // Deleted events stay known, so the sources they came from do not add them back.
        var knownIDs = Set(Self.readLines(at: url).compactMap { line -> String? in
            if case let .event(event) = line { return event.id }
            return nil
        })
        var newEvents: [LearningEvent] = []
        for var event in LearningEventCollector.events(paperID: paperID, sources: sources, now: now)
        where knownIDs.insert(event.id).inserted {
            event.isBackfilled = isFirstCollection
            newEvents.append(event)
        }
        newEvents.sort { $0.occurredAt < $1.occurredAt }

        // The file is created even when empty: its existence is what marks later events
        // as observed rather than backfilled.
        guard newEvents.isEmpty == false || isFirstCollection else { return [] }
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data()
        let encoder = Self.encoder
        for event in newEvents {
            data.append(try encoder.encode(event))
            data.append(0x0A)
        }
        if isFirstCollection {
            try data.write(to: url, options: .atomic)
        } else {
            try append(data, to: url)
        }
        return newEvents
    }

    /// Hides an event the reader deleted, together with the earlier revisions of its
    /// subject and the per-line highlight events it absorbed. The log stays append-only:
    /// a deletion line is added, so collecting the same sources again adds nothing, while
    /// a later revision (an edited note, a new answer) shows up again.
    func delete(_ event: LearningEvent, now: Date = Date()) throws {
        let url = try fileURL(paperID: event.paperID)
        guard fileManager.fileExists(atPath: url.path) else { return }
        let deletion = Deletion(
            deletedSubjects: [event.subject] + (event.replaces ?? []).filter { $0 != event.subject },
            deletedAt: now
        )
        var data = try Self.encoder.encode(deletion)
        data.append(0x0A)
        try append(data, to: url)
    }

    private func append(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    /// The paper's events in the order they were appended.
    func events(paperID: UUID) -> [LearningEvent] {
        guard let url = try? fileURL(paperID: paperID) else { return [] }
        return Self.readEvents(at: url)
    }

    /// The events of every paper, including papers no longer in the library, oldest first.
    func allEvents() -> [LearningEvent] {
        guard let directory = try? eventsDirectory(),
              let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        return files
            .filter { $0.pathExtension == "jsonl" }
            .flatMap(Self.readEvents(at:))
            .sorted { $0.occurredAt < $1.occurredAt }
    }

    private func eventsDirectory() throws -> URL {
        let root = try rootOverride ?? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("ReadPaper", isDirectory: true)
        return root
            .appendingPathComponent("Learning", isDirectory: true)
            .appendingPathComponent("events", isDirectory: true)
    }

    private func fileURL(paperID: UUID) throws -> URL {
        try eventsDirectory().appendingPathComponent("\(paperID.uuidString).jsonl")
    }

    /// A line the reader's deletion appended. Versions before deletions skip it like any
    /// line they cannot read, and so still show the event.
    private struct Deletion: Codable {
        var deletedSubjects: [String]
        var deletedAt: Date
    }

    private enum Line {
        case event(LearningEvent)
        case deletion(Deletion)
    }

    /// Lines that do not decode (written by a newer version, or cut short by a crash) are
    /// skipped and stay in the file. Two app instances can append the same event, so
    /// repeated IDs are dropped.
    private static func readLines(at url: URL) -> [Line] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = Self.decoder
        var seen = Set<String>()
        return data.split(separator: 0x0A).compactMap { line in
            if let event = try? decoder.decode(LearningEvent.self, from: line) {
                return seen.insert(event.id).inserted ? .event(event) : nil
            }
            return (try? decoder.decode(Deletion.self, from: line)).map(Line.deletion)
        }
    }

    /// The events left once deletions apply: each removes the events of its subjects
    /// appended before it.
    private static func readEvents(at url: URL) -> [LearningEvent] {
        var events: [LearningEvent] = []
        for line in readLines(at: url) {
            switch line {
            case let .event(event):
                events.append(event.withoutInstruction)
            case let .deletion(deletion):
                let subjects = Set(deletion.deletedSubjects)
                events.removeAll { subjects.contains($0.subject) }
            }
        }
        return events
    }

    private static func conversations(in notesDirectory: URL) -> [SelectionAssistantConversationSnapshot] {
        SelectionAssistantConversationStore.snapshots(
            at: notesDirectory.appendingPathComponent(SelectionAssistantConversationStore.archiveFileName)
        )
    }

    private static func annotations(
        in notesDirectory: URL,
        fileManager: FileManager
    ) -> [LearningEventSources.Annotation] {
        let files = (try? fileManager.contentsOfDirectory(at: notesDirectory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix("pdf-annotations-") && $0.pathExtension == "json" }
            .flatMap { url -> [LearningEventSources.Annotation] in
                guard let sidecar = PDFAnnotationStore.sidecar(at: url) else { return [] }
                return sidecar.annotations.map {
                    LearningEventSources.Annotation(attachmentID: sidecar.attachmentID, record: $0)
                }
            }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Collects a paper's learning events at natural pauses: leaving the paper, the app
/// losing focus, opening the Learning tab. It never saves SwiftData or writes
/// UserDefaults, so collecting does not redraw the window.
@MainActor
@Observable
final class LearningRecorder {
    static let shared = LearningRecorder()

    /// Bumped when a collection appended events, so an open Learning tab reloads.
    private(set) var revision = 0

    @ObservationIgnored private let log: LearningEventLog
    @ObservationIgnored private let fileStore: PaperFileStore
    @ObservationIgnored private let writingLibrary: WritingLibrary

    init(
        log: LearningEventLog = .shared,
        fileStore: PaperFileStore = PaperFileStore(),
        writingLibrary: WritingLibrary = .shared
    ) {
        self.log = log
        self.fileStore = fileStore
        self.writingLibrary = writingLibrary
    }

    @discardableResult
    func collect(paperID: UUID, notes: [LearningEventSources.NoteValue]) async -> [LearningEvent] {
        let sources = LearningEventSources(notes: notes, citations: writingLibrary.citationMarks(for: paperID))
        // Built by hand: `PaperFileStore.notesDirectory` would recreate the folder of a
        // paper that was just deleted.
        let notesDirectory = try? fileStore.libraryDirectory
            .appendingPathComponent(paperID.uuidString, isDirectory: true)
            .appendingPathComponent("notes", isDirectory: true)
        let appended = (try? await log.record(
            paperID: paperID,
            sources: sources,
            notesDirectory: notesDirectory
        )) ?? []
        if appended.isEmpty == false {
            revision &+= 1
        }
        return appended
    }

    /// Removes a record from the Learning tab, from future organizing and from the
    /// concept library. Records the organizer already built from it stay.
    func delete(_ event: LearningEvent) async {
        do {
            try await log.delete(event)
            revision &+= 1
        } catch {
            // The file is gone or unwritable; the next load shows the log as it is.
        }
    }
}
