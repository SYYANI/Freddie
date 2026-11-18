import Foundation

/// A concept the reader met in one or more papers. Not stored: derived from the papers'
/// organized records by grouping concept entries with the same normalized name. The
/// organizer is told the names already in the library, so the same idea keeps one name.
struct LearningConcept: Equatable, Identifiable, Sendable {
    /// How far along the reader is, derived by rule from their own actions. The model
    /// never judges this.
    enum Stage: Equatable, Sendable {
        /// Looked up once or twice in a single paper.
        case new
        /// Looked up at least `recurringLookupCount` times, or met in several papers.
        case recurring
        /// The reader wrote about it: a note of their own or a passage quoted in a writing.
        case writtenAbout
    }

    struct Entry: Equatable, Sendable {
        var paperID: UUID
        var item: LearningRecordItem
    }

    static let recurringLookupCount = 3

    /// The normalized name.
    var id: String
    var name: String
    /// Most recently updated first.
    var entries: [Entry]
    /// Translation, explanation and question events behind the entries.
    var lookupCount: Int
    var isWrittenAbout: Bool
    var updatedAt: Date
    /// Normalized names the reader renamed it from. A passage using one still mentions it.
    var aliases: [String] = []

    var paperIDs: [UUID] {
        var seen = Set<UUID>()
        return entries.map(\.paperID).filter { seen.insert($0).inserted }
    }

    var stage: Stage {
        if isWrittenAbout { return .writtenAbout }
        if lookupCount >= Self.recurringLookupCount || paperIDs.count > 1 { return .recurring }
        return .new
    }
}

enum LearningLibrary {
    /// Case, width, diacritics, hyphens and spacing do not distinguish concepts.
    static func normalizedName(_ name: String) -> String {
        let folded = name.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: nil
        )
        let separators: Set<Character> = ["-", "_", "‐", "–"]
        let spaced = String(folded.map { separators.contains($0) ? " " : $0 })
        return spaced.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Every concept in the library, most recently updated first.
    static func concepts(
        records: [PaperLearningRecord],
        eventsByID: [String: LearningEvent]
    ) -> [LearningConcept] {
        var entriesByName: [String: [LearningConcept.Entry]] = [:]
        for record in records {
            for item in record.items(of: .concept) {
                let key = normalizedName(item.title)
                guard key.isEmpty == false else { continue }
                entriesByName[key, default: []].append(.init(paperID: record.paperID, item: item))
            }
        }
        // A passage behind a concept that the reader went on to quote in a writing: they
        // wrote about it, whether or not the organizer has tied the quotation to the
        // concept yet. "Write About It" quotes exactly such a passage.
        func passageKey(_ event: LearningEvent) -> String? {
            guard let quote = event.quote?.filter({ $0.isWhitespace == false }), quote.isEmpty == false else {
                return nil
            }
            return event.paperID.uuidString + "\n" + quote
        }
        let quotedPassages = Set(eventsByID.values.filter { $0.kind == .citation }.compactMap(passageKey))
        return entriesByName.map { key, entries in
            let entries = entries.sorted { $0.item.updatedAt > $1.item.updatedAt }
            var evidenceIDs = Set<String>()
            let evidence = entries
                .flatMap(\.item.evidence)
                .filter { evidenceIDs.insert($0).inserted }
                .compactMap { eventsByID[$0] }
            return LearningConcept(
                id: key,
                // The name it was first given, so the title does not change as papers are added.
                name: entries.min { $0.item.createdAt < $1.item.createdAt }?.item.title ?? key,
                entries: entries,
                lookupCount: evidence.filter {
                    $0.kind == .question || $0.kind == .explanation || $0.kind == .translation
                }.count,
                isWrittenAbout: evidence.contains {
                    $0.kind == .citation || ($0.kind == .note && $0.text?.isEmpty == false)
                        || passageKey($0).map(quotedPassages.contains) == true
                },
                updatedAt: entries.first?.item.updatedAt ?? .distantPast,
                aliases: Array(Set(entries.flatMap { $0.item.aliases ?? [] }.map(normalizedName)))
                    .filter { $0 != key && entriesByName[$0] == nil }
                    .sorted()
            )
        }
        .sorted { ($0.updatedAt, $0.id) > ($1.updatedAt, $1.id) }
    }

    /// Concept names from other papers, most recently updated first, for the organizer to
    /// reuse.
    static func knownConceptNames(
        records: [PaperLearningRecord],
        excluding paperID: UUID,
        limit: Int = 120
    ) -> [String] {
        var seen = Set<String>()
        return records
            .filter { $0.paperID != paperID }
            .flatMap { $0.items(of: .concept) }
            .sorted { $0.updatedAt > $1.updatedAt }
            .filter { seen.insert(normalizedName($0.title)).inserted }
            .prefix(limit)
            .map(\.title)
    }

    /// Names the reader replaced, mapped to the name they chose (normalized old name →
    /// current title). A name some concept still carries is not a replaced one. The
    /// organizer files a new concept under the chosen name, so a correction made once
    /// holds in every paper read afterwards.
    static func conceptRenames(records: [PaperLearningRecord]) -> [String: String] {
        let concepts = records.flatMap { $0.items(of: .concept) }.sorted { $0.updatedAt < $1.updatedAt }
        let current = Set(concepts.map { normalizedName($0.title) })
        var renames: [String: String] = [:]
        for item in concepts {
            for alias in item.aliases ?? [] {
                let name = normalizedName(alias)
                if name.isEmpty == false, current.contains(name) == false {
                    renames[name] = item.title
                }
            }
        }
        return renames
    }

    /// Concepts whose name appears in the text, the ones with the most history first. A
    /// name made of Latin letters must match whole words, so "RNN" is not found in
    /// "learnng"; names shorter than two characters never match.
    static func concepts(
        mentionedIn text: String,
        among concepts: [LearningConcept],
        limit: Int = 3
    ) -> [LearningConcept] {
        let haystack = normalizedName(text)
        guard haystack.isEmpty == false else { return [] }
        return concepts
            .filter { concept in
                ([concept.id] + concept.aliases).contains { name in
                    guard name.count >= 2 else { return false }
                    var searchRange = haystack.startIndex..<haystack.endIndex
                    while let range = haystack.range(of: name, range: searchRange) {
                        if isWordBoundary(in: haystack, before: range.lowerBound, name: name.first),
                           isWordBoundary(in: haystack, after: range.upperBound, name: name.last) {
                            return true
                        }
                        searchRange = haystack.index(after: range.lowerBound)..<haystack.endIndex
                    }
                    return false
                }
            }
            .sorted { ($0.lookupCount, $0.id.count, $0.id) > ($1.lookupCount, $1.id.count, $1.id) }
            .prefix(limit)
            .map { $0 }
    }

    private static func isWordBoundary(in text: String, before index: String.Index, name: Character?) -> Bool {
        guard let name, name.isASCII, name.isLetter || name.isNumber, index > text.startIndex else { return true }
        let previous = text[text.index(before: index)]
        return (previous.isASCII && (previous.isLetter || previous.isNumber)) == false
    }

    private static func isWordBoundary(in text: String, after index: String.Index, name: Character?) -> Bool {
        guard let name, name.isASCII, name.isLetter || name.isNumber, index < text.endIndex else { return true }
        let next = text[index]
        return (next.isASCII && (next.isLetter || next.isNumber)) == false
    }
}
