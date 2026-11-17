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
        var knownIDs = Set(Self.readEvents(at: url).map(\.id))
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
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        }
        return newEvents
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

    /// Lines that do not decode (written by a newer version, or cut short by a crash) are
    /// skipped and stay in the file. Two app instances can append the same event, so
    /// repeated IDs are dropped.
    private static func readEvents(at url: URL) -> [LearningEvent] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = Self.decoder
        var seen = Set<String>()
        return data.split(separator: 0x0A).compactMap { line in
            guard let event = try? decoder.decode(LearningEvent.self, from: line),
                  seen.insert(event.id).inserted else { return nil }
            return event
        }
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
}
