import Foundation

/// One entry of a paper's organized learning record. Every entry points at the events it
/// was built from, so it can always be traced back to a passage of the paper.
struct LearningRecordItem: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case question
        case concept
        case takeaway
    }

    static let titleLimit = 200
    static let detailLimit = 600

    /// `i1`, `i2`, …: short enough for the model to refer back to.
    var id: String
    var kind: Kind
    var title: String
    var detail: String?
    /// Questions only: whether the events contain an answer that settles it.
    var isResolved: Bool
    /// The reader set `isResolved` by hand; the organizer no longer changes it.
    var isResolvedByUser: Bool
    /// IDs of the `LearningEvent`s behind this entry, in the order they were added.
    var evidence: [String]
    var createdAt: Date
    var updatedAt: Date
    /// The reader rewrote the entry or changed its kind. The organizer may add evidence
    /// to it, but no longer changes its wording.
    var isEditedByUser: Bool?
    /// Titles the entry had before the reader renamed it, or of entries merged into it.
    /// An entry the organizer would add under one of them is this entry.
    var aliases: [String]?

    var isPinned: Bool { isEditedByUser == true }

    /// Whether `name` is this entry's title or one of its earlier ones.
    func isNamed(_ normalizedName: String) -> Bool {
        LearningLibrary.normalizedName(title) == normalizedName
            || (aliases ?? []).contains { LearningLibrary.normalizedName($0) == normalizedName }
    }
}

/// What the organizer has made of a paper's learning events:
/// `Application Support/ReadPaper/Learning/papers/{paper UUID}.json`.
struct PaperLearningRecord: Codable, Equatable, Sendable {
    static let currentVersion = 1
    /// New entries beyond this many of a kind are dropped; the organizer is asked to
    /// update existing entries instead.
    static let itemLimitPerKind = 60
    /// The most recently removed entries are remembered.
    static let removedItemLimit = 200

    var version: Int = PaperLearningRecord.currentVersion
    var paperID: UUID
    var organizedAt: Date?
    /// The model that last organized the record.
    var modelName: String?
    /// Events the organizer has already been shown, sorted.
    var processedEventIDs: [String] = []
    var nextItemNumber = 1
    var items: [LearningRecordItem] = []
    /// Entries the reader removed, oldest first. The organizer does not add them again,
    /// and the reader can put the latest one back.
    var removedItems: [LearningRecordItem]?
    /// When the reader last looked at this record in the old Learning tab list. No longer
    /// written; kept so records saved by earlier versions decode and round-trip.
    var lastSeenAt: Date?

    func items(of kind: LearningRecordItem.Kind) -> [LearningRecordItem] {
        items.filter { $0.kind == kind }
    }

    /// The latest revision of each subject with events the organizer has not seen,
    /// oldest first.
    func pendingEvents(in events: [LearningEvent]) -> [LearningEvent] {
        // Revisions are resolved over the whole log first: an event absorbed by a later
        // one (a line of a highlight that is now one event) is not pending by itself.
        let processed = Set(processedEventIDs)
        return LearningEvent.latestRevisions(of: events).filter { processed.contains($0.id) == false }
    }
}

/// The organizer's answer for one batch of events, as the model wrote it.
struct LearningRecordPatch: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        /// The existing item to update, or nil for a new one.
        var ref: String?
        var kind: String?
        var title: String?
        var detail: String?
        var resolved: Bool?
        var evidence: [String]
    }

    var entries: [Entry]

    /// Reads the JSON object out of a model response, tolerating code fences and prose
    /// around it. Nil when there is no usable object.
    init?(modelOutput: String) {
        guard let start = modelOutput.firstIndex(of: "{"),
              let end = modelOutput.lastIndex(of: "}"),
              start < end,
              let object = try? JSONSerialization.jsonObject(with: Data(modelOutput[start...end].utf8)) as? [String: Any],
              let rawItems = object["items"] as? [Any] else {
            return nil
        }
        entries = rawItems.compactMap { raw in
            guard let item = raw as? [String: Any] else { return nil }
            return Entry(
                ref: item["ref"] as? String,
                kind: item["kind"] as? String,
                title: item["title"] as? String,
                detail: item["detail"] as? String,
                resolved: item["resolved"] as? Bool,
                evidence: (item["evidence"] as? [Any])?.compactMap { $0 as? String } ?? []
            )
        }
    }

    init(entries: [Entry]) {
        self.entries = entries
    }
}

extension PaperLearningRecord {
    /// Applies a patch for one batch. `eventIDsByAlias` maps the aliases the model was
    /// given (`e1`, …) to event IDs: evidence outside it is dropped, and an entry left
    /// without evidence is ignored, so nothing enters the record that cannot be traced to
    /// an event the reader produced. Returns how many entries were applied.
    @discardableResult
    mutating func apply(
        _ patch: LearningRecordPatch,
        eventIDsByAlias: [String: String],
        conceptRenames: [String: String] = [:],
        now: Date = Date()
    ) -> Int {
        var applied = 0
        for entry in patch.entries {
            var seen = Set<String>()
            let evidence = entry.evidence
                .compactMap { eventIDsByAlias[$0.trimmingCharacters(in: .whitespaces)] }
                .filter { seen.insert($0).inserted }
            guard evidence.isEmpty == false else { continue }
            let title = Self.clipped(entry.title, limit: LearningRecordItem.titleLimit)
            let detail = Self.clipped(entry.detail, limit: LearningRecordItem.detailLimit)

            if let ref = entry.ref?.trimmingCharacters(in: .whitespaces), ref.isEmpty == false {
                // A reference to an item that does not exist is not turned into a new
                // item: the model meant to change something else.
                guard let index = items.firstIndex(where: { $0.id == ref }) else { continue }
                if items[index].isPinned == false {
                    if let title { items[index].title = title }
                    if let detail { items[index].detail = detail }
                }
                if let resolved = entry.resolved,
                   items[index].kind == .question,
                   items[index].isResolvedByUser == false {
                    items[index].isResolved = resolved
                }
                items[index].evidence += evidence.filter { items[index].evidence.contains($0) == false }
                items[index].updatedAt = now
            } else {
                guard let kind = entry.kind.flatMap(LearningRecordItem.Kind.init(rawValue:)),
                      var title else { continue }
                // A concept under a name the reader replaced, here or in another paper,
                // takes the name they chose.
                if kind == .concept, let renamed = conceptRenames[LearningLibrary.normalizedName(title)] {
                    title = renamed
                }
                let name = LearningLibrary.normalizedName(title)
                // The reader removed this entry: it stays removed.
                if (removedItems ?? []).contains(where: { $0.kind == kind && $0.isNamed(name) }) { continue }
                // An entry under a name the record already has, or had before the reader
                // renamed it, is that entry.
                if let index = items.firstIndex(where: { $0.kind == kind && $0.isNamed(name) }) {
                    if items[index].isPinned == false, let detail { items[index].detail = detail }
                    items[index].evidence += evidence.filter { items[index].evidence.contains($0) == false }
                    items[index].updatedAt = now
                    applied += 1
                    continue
                }
                guard items(of: kind).count < Self.itemLimitPerKind else { continue }
                items.append(LearningRecordItem(
                    id: "i\(nextItemNumber)",
                    kind: kind,
                    title: title,
                    detail: detail,
                    isResolved: kind == .question && entry.resolved == true,
                    isResolvedByUser: false,
                    evidence: evidence,
                    createdAt: now,
                    updatedAt: now
                ))
                nextItemNumber += 1
            }
            applied += 1
        }
        return applied
    }

    /// The reader rewrote an entry. Renaming it to the name of another entry of its kind
    /// merges the two. Returns whether anything changed.
    @discardableResult
    mutating func edit(itemID: String, title: String, detail: String?) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == itemID }),
              let title = Self.clipped(title, limit: LearningRecordItem.titleLimit) else { return false }
        let original = items[index]
        var item = original
        let detail = Self.clipped(detail, limit: LearningRecordItem.detailLimit)
        let name = LearningLibrary.normalizedName(title)
        var aliases = item.aliases ?? []
        if LearningLibrary.normalizedName(item.title) != name {
            aliases.append(item.title)
        }
        item.title = title
        item.detail = detail
        for other in items where other.id != itemID && other.kind == item.kind
            && LearningLibrary.normalizedName(other.title) == name {
            item.evidence += other.evidence.filter { item.evidence.contains($0) == false }
            aliases += other.aliases ?? []
            item.createdAt = min(item.createdAt, other.createdAt)
            if item.detail == nil { item.detail = other.detail }
            if other.isResolved == false { item.isResolved = false }
        }
        var seen: Set<String> = [name]
        aliases = aliases.filter { seen.insert(LearningLibrary.normalizedName($0)).inserted }
        item.aliases = aliases.isEmpty ? nil : aliases
        guard item != original else { return false }
        item.isEditedByUser = true
        items.removeAll {
            $0.id != itemID && $0.kind == item.kind && LearningLibrary.normalizedName($0.title) == name
        }
        if let index = items.firstIndex(where: { $0.id == itemID }) {
            items[index] = item
        }
        return true
    }

    /// The reader filed an entry under another kind.
    @discardableResult
    mutating func setKind(_ kind: LearningRecordItem.Kind, itemID: String) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == itemID }), items[index].kind != kind else {
            return false
        }
        items[index].kind = kind
        items[index].isResolved = false
        items[index].isResolvedByUser = false
        items[index].isEditedByUser = true
        return true
    }

    /// The reader removed an entry. It is kept aside so the organizer does not add it again.
    @discardableResult
    mutating func remove(itemID: String) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return false }
        var removed = removedItems ?? []
        removed.append(items.remove(at: index))
        removedItems = Array(removed.suffix(Self.removedItemLimit))
        return true
    }

    /// Puts a removed entry back.
    @discardableResult
    mutating func restore(itemID: String) -> Bool {
        guard var removed = removedItems, let index = removed.firstIndex(where: { $0.id == itemID }) else {
            return false
        }
        items.append(removed.remove(at: index))
        removedItems = removed.isEmpty ? nil : removed
        return true
    }

    private static func clipped(_ value: String?, limit: Int) -> String? {
        guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), text.isEmpty == false else {
            return nil
        }
        return text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }
}

/// Reads and writes organized records. Every change loads, modifies and saves inside the
/// actor, so the organizer and the reader's own edits cannot overwrite each other.
actor LearningRecordStore {
    static let shared = LearningRecordStore()

    private let rootOverride: URL?
    private let fileManager = FileManager()

    /// `rootDirectory` is the `ReadPaper` application support directory.
    init(rootDirectory: URL? = nil) {
        rootOverride = rootDirectory
    }

    enum StoreError: Error, Equatable {
        /// Written by a newer version of the app: readable by nobody here, and not to be
        /// overwritten.
        case unsupportedRecord
    }

    /// The paper's record, an empty one when none was written yet.
    func record(paperID: UUID) throws -> PaperLearningRecord {
        let url = try fileURL(paperID: paperID)
        guard fileManager.fileExists(atPath: url.path) else {
            return PaperLearningRecord(paperID: paperID)
        }
        guard let record = try? Self.decoder.decode(PaperLearningRecord.self, from: Data(contentsOf: url)),
              record.version <= PaperLearningRecord.currentVersion else {
            throw StoreError.unsupportedRecord
        }
        return record
    }

    /// The readable records of every paper, including papers no longer in the library.
    func allRecords() -> [PaperLearningRecord] {
        guard let directory = try? recordsDirectory(),
              let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let record = try? Self.decoder.decode(PaperLearningRecord.self, from: Data(contentsOf: url)),
                      record.version <= PaperLearningRecord.currentVersion else { return nil }
                return record
            }
    }

    @discardableResult
    func update<Result: Sendable>(
        paperID: UUID,
        _ change: @Sendable (inout PaperLearningRecord) -> Result
    ) throws -> Result {
        var record = try record(paperID: paperID)
        let original = record
        let result = change(&record)
        guard record != original else { return result }
        let url = try fileURL(paperID: paperID)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(record).write(to: url, options: .atomic)
        return result
    }

    private func fileURL(paperID: UUID) throws -> URL {
        try recordsDirectory().appendingPathComponent("\(paperID.uuidString).json")
    }

    private func recordsDirectory() throws -> URL {
        let root = try rootOverride ?? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("ReadPaper", isDirectory: true)
        return root
            .appendingPathComponent("Learning", isDirectory: true)
            .appendingPathComponent("papers", isDirectory: true)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
