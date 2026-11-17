import Foundation
import NaturalLanguage
import Observation
import SwiftUI

/// Something the reader did before (a highlight, a note, a question, a quoted passage)
/// that relates to what they are reading or writing now. Echoes are found locally from
/// the learning log: no model is asked and nothing is sent anywhere.
struct LearningEcho: Equatable, Identifiable, Sendable {
    var event: LearningEvent
    /// 0…1. Only echoes at or above `LearningEchoIndex.threshold` are offered.
    var score: Double
    /// Why it was offered: the words both passages use, most distinctive first.
    var sharedTerms: [String]
    /// A concept from the reader's records that the current passage mentions and this
    /// event is evidence of.
    var conceptName: String?

    var id: String { event.subject }
}

/// Splits text into the terms echoes are matched on: Latin words (lowercased, lightly
/// stemmed, without function words), pairs of adjacent words, and pairs of adjacent CJK
/// characters.
enum LearningEchoText {
    /// Each term mapped to how it first appeared, for showing it.
    static func terms(in text: String) -> [String: String] {
        var terms: [String: String] = [:]
        var previousWord: (key: String, display: String)?
        var word = ""
        var cjkRun: [Character] = []

        func flushWord() {
            defer { word = "" }
            guard word.isEmpty == false else { return }
            let lower = word.lowercased()
            let isAcronym = word.count >= 2 && word.allSatisfy { $0.isUppercase || $0.isNumber }
                && word.contains(where: \.isLetter)
            guard (lower.count >= 3 || isAcronym),
                  lower.contains(where: \.isLetter),
                  stopWords.contains(lower) == false else {
                previousWord = nil
                return
            }
            let key = stem(lower)
            let display = isAcronym ? word : lower
            if terms[key] == nil { terms[key] = display }
            if let previousWord, previousWord.key != key {
                let pair = previousWord.key + " " + key
                if terms[pair] == nil { terms[pair] = previousWord.display + " " + display }
            }
            previousWord = (key, display)
        }

        func flushCJK() {
            defer { cjkRun = [] }
            guard cjkRun.count >= 2 else { return }
            for word in cjkWords(in: String(cjkRun)) where terms[word] == nil {
                terms[word] = word
            }
        }

        for character in text.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil) {
            if isCJK(character) {
                flushWord()
                previousWord = nil
                cjkRun.append(character)
            } else if character.isLetter || character.isNumber {
                flushCJK()
                word.append(character)
            } else {
                flushCJK()
                flushWord()
                // Punctuation ends a phrase; a space or hyphen does not.
                if character.isWhitespace == false, character != "-", character != "‐" {
                    previousWord = nil
                }
            }
        }
        flushWord()
        flushCJK()
        return terms
    }

    /// Chinese and Japanese have no spaces: words come from the system's segmenter. Single
    /// characters and function words are dropped.
    static func cjkWords(in run: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = run
        var words: [String] = []
        tokenizer.enumerateTokens(in: run.startIndex..<run.endIndex) { range, _ in
            let word = String(run[range])
            if word.count >= 2, cjkStopWords.contains(word) == false {
                words.append(word)
            }
            return true
        }
        return words
    }

    /// Plural and verb endings, so "models" meets "model" and "trained" meets "training".
    static func stem(_ word: String) -> String {
        guard word.count > 4, word.allSatisfy(\.isASCII) else { return word }
        func dropping(_ count: Int, adding suffix: String = "") -> String? {
            let base = String(word.dropLast(count)) + suffix
            return base.count >= 3 ? base : nil
        }
        if word.hasSuffix("ies") { return dropping(3, adding: "y") ?? word }
        if word.hasSuffix("ing") { return dropping(3) ?? word }
        if word.hasSuffix("ed") { return dropping(2) ?? word }
        if word.hasSuffix("sses") || word.hasSuffix("xes") || word.hasSuffix("ches") || word.hasSuffix("shes") {
            return dropping(2) ?? word
        }
        if word.hasSuffix("s"), ["ss", "us", "is"].contains(where: word.hasSuffix) == false {
            return dropping(1) ?? word
        }
        return word
    }

    static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F,
                 0x3040...0x30FF, 0xAC00...0xD7AF: true
            default: false
            }
        }
    }

    /// Words that carry no topic, including the vocabulary every paper uses.
    static let stopWords: Set<String> = [
        "the", "and", "for", "are", "but", "not", "you", "all", "any", "can", "had", "her", "was", "one",
        "our", "out", "has", "have", "him", "his", "how", "its", "may", "new", "now", "old", "see", "two",
        "way", "who", "did", "get", "let", "put", "say", "she", "too", "use", "used", "uses", "using",
        "this", "that", "these", "those", "with", "from", "into", "onto", "upon", "than", "then", "them",
        "they", "their", "there", "here", "where", "when", "which", "while", "what", "whose", "whom",
        "will", "would", "should", "could", "might", "must", "shall", "been", "being", "were", "does",
        "doing", "done", "each", "every", "both", "either", "neither", "such", "same", "other", "others",
        "another", "some", "many", "much", "more", "most", "less", "least", "few", "fewer", "very", "also",
        "only", "just", "even", "still", "yet", "already", "again", "once", "about", "above", "below",
        "after", "before", "between", "among", "through", "during", "without", "within", "across",
        "against", "along", "around", "because", "since", "until", "unless", "although", "though",
        "however", "therefore", "thus", "hence", "whether", "while", "via", "per", "etc", "i.e", "e.g",
        "we", "us", "it", "is", "be", "an", "as", "at", "by", "if", "in", "of", "on", "or", "so", "to",
        "up", "do", "no", "my", "me", "he", "his", "hers", "its", "itself", "themselves", "ourselves",
        "show", "shows", "shown", "showing", "propose", "proposed", "present", "presented", "paper",
        "papers", "work", "works", "section", "sections", "figure", "figures", "fig", "table", "tables",
        "appendix", "result", "results", "example", "examples", "case", "cases", "approach", "approaches",
        "method", "methods", "first", "second", "third", "three", "four", "five", "number", "numbers",
        "large", "small", "high", "low", "higher", "lower", "better", "best", "well", "good", "different",
        "similar", "based", "given", "make", "makes", "made", "take", "takes", "taken", "like", "able",
        "important", "significant", "significantly", "respectively", "particular", "particularly",
        "following", "follows", "further", "furthermore", "moreover", "addition", "additional", "note",
        "notes", "e.g.", "et", "al", "eq", "equation", "denote", "denotes", "consider", "considered",
        "obtain", "obtained", "provide", "provides", "provided", "include", "includes", "including",
        "need", "needs", "know", "known", "time", "times", "set", "sets", "way", "ways", "part", "parts",
        "term", "terms", "type", "types", "level", "levels", "order", "value", "values", "point",
        "points", "use", "general", "generally", "specific", "specifically", "simple", "simply",
        "often", "usually", "always", "never", "sometimes", "various", "several", "certain", "likely",
        "possible", "possibly", "instead", "rather", "whereas", "within", "overall", "total", "main",
        "key", "related", "relative", "relatively", "due", "directly", "previous", "previously",
        "recent", "recently", "current", "currently", "last", "next", "prior", "why",
    ]

    /// Words nearly every machine learning paper uses. They still match, at a third of the
    /// weight, so a passage needs more than these in common to be an echo.
    static let commonResearchWords: Set<String> = [
        "model", "data", "language", "train", "learn", "network", "neural", "task", "performance",
        "dataset", "input", "output", "layer", "parameter", "function", "loss", "accuracy", "evaluat",
        "evaluation", "experiment", "baseline", "feature", "representation", "system", "algorithm",
        "problem", "process", "information", "structure", "sample", "distribution", "step", "size",
        "rate", "test", "score", "prediction", "predict", "generat", "generate", "generation", "evaluate", "text", "token", "sequence",
        "image", "compute", "computation", "large", "scale", "benchmark", "metric", "improve",
        "improvement", "achieve", "method", "framework", "architecture", "design", "analysis",
        "study", "research", "deep", "machine", "objective", "optimization", "fine", "tun",
        "inference", "context", "prompt", "answer", "question", "label", "class", "domain",
        "模型", "数据", "训练", "学习", "方法", "任务", "性能", "结果", "网络", "语言", "实验", "效果", "生成",
    ]

    /// Chinese words too common to mean anything.
    static let cjkStopWords: Set<String> = [
        "我们", "你们", "他们", "她们", "它们", "自己", "这个", "那个", "一个", "一些", "什么", "为什么", "怎么",
        "怎样", "如何", "因为", "所以", "但是", "然而", "如果", "虽然", "而且", "并且", "可以", "可能", "能够",
        "没有", "就是", "这是", "那是", "不是", "也是", "还是", "以及", "或者", "然后", "其中", "这些", "那些",
        "这种", "那种", "一种", "进行", "通过", "使用", "论文", "本文", "文章", "这里", "那里", "这样", "那样",
        "之间", "之后", "之前", "以后", "以前", "时候", "会不会", "是不是", "能不能", "有没有", "不会", "不能",
        "是否", "能否", "已经", "仍然", "还有", "只是", "非常", "比较", "更加", "得到", "需要", "应该", "其实",
        "觉得", "认为", "问题", "感觉", "关于", "对于", "由于", "根据", "这么", "那么", "多少", "一下", "一样",
    ]
}

/// Every past action the reader might be reminded of, prepared for matching. Built off
/// the main thread from the learning log and the organized records, and replaced when
/// either changes.
struct LearningEchoIndex: Sendable {
    /// Echoes below this are not offered: a wrong reminder costs more trust than a
    /// missing one.
    static let threshold = 0.4
    static let limit = 5
    /// The score an event gets when the current passage names a concept it is evidence of.
    static let conceptScore = 0.6
    /// The shared weight that counts as a full match: about three distinctive words.
    static let fullStrengthWeight = 3.0

    struct Entry: Sendable {
        var event: LearningEvent
        /// The quote and the reader's own words, not the assistant's answer.
        var terms: [String: String]
        /// Each part's own words, for coverage: a note in Chinese about an English
        /// passage should not dilute how much of the passage is on screen.
        var parts: [Set<String>]
        /// Normalized names of the concepts this event is evidence of.
        var conceptIDs: Set<String>
        /// The quote without spacing or case, to tell whether it is on screen.
        var compactQuote: String?
    }

    struct Query: Equatable, Sendable {
        var text: String
        var paperID: UUID?
        var pageIndex: Int?
        /// The writing being written: its own citations are not echoes of it.
        var writingID: UUID?
    }

    let entries: [Entry]
    let concepts: [LearningConcept]
    private let documentFrequency: [String: Int]

    init(events: [LearningEvent], records: [PaperLearningRecord]) {
        let latest = LearningEvent.latestRevisions(of: events)
        let eventsByID = Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        concepts = LearningLibrary.concepts(records: records, eventsByID: eventsByID)
        var conceptsByEvent: [String: Set<String>] = [:]
        for concept in concepts {
            for evidence in concept.entries.flatMap(\.item.evidence) {
                conceptsByEvent[evidence, default: []].insert(concept.id)
            }
        }
        // Concepts cite the revision the organizer saw; later revisions share its subject.
        var conceptsBySubject: [String: Set<String>] = [:]
        for event in events {
            if let ids = conceptsByEvent[event.id] {
                conceptsBySubject[event.subject, default: []].formUnion(ids)
            }
        }
        entries = latest.compactMap { event in
            let parts = [event.quote, event.text].compactMap { $0 }.map(LearningEchoText.terms(in:))
            let terms = parts.reduce(into: [String: String]()) { all, part in
                all.merge(part) { first, _ in first }
            }
            guard terms.isEmpty == false else { return nil }
            return Entry(
                event: event,
                terms: terms,
                parts: parts.map { Set($0.keys.filter { $0.contains(" ") == false }) }.filter { $0.isEmpty == false },
                conceptIDs: conceptsBySubject[event.subject] ?? [],
                compactQuote: event.quote.map(Self.compact).flatMap { $0.count >= 12 ? $0 : nil }
            )
        }
        var frequency: [String: Int] = [:]
        for entry in entries {
            for term in entry.terms.keys {
                frequency[term, default: 0] += 1
            }
        }
        documentFrequency = frequency
    }

    var isEmpty: Bool { entries.isEmpty }

    /// How much a term says about a passage, 0…1: a term in few of the reader's past
    /// actions says more than one in most of them.
    func weight(of term: String) -> Double {
        let count = Double(max(entries.count, 1))
        let frequency = Double(documentFrequency[term] ?? 1)
        return log(1 + count / frequency) / log(1 + count)
    }

    /// A term's weight with everyday research vocabulary discounted: two passages that
    /// both say "language models" and "data" are not about the same thing.
    func adjustedWeight(of term: String) -> Double {
        let words = term.split(separator: " ").map(String.init)
        let common = words.filter(LearningEchoText.commonResearchWords.contains).count
        let factor: Double = switch (words.count, common) {
        case (1, 1): 0.35
        case (_, 0): 1
        case (2, 1): 0.8
        default: 0.6
        }
        return weight(of: term) * factor
    }

    /// 0…1 from the terms a past action shares with the query. Matches are counted as
    /// units, a shared word pair absorbing its two words, and at least two units must
    /// match: one phrase in common ("square root") is a coincidence.
    func lexicalScore(shared: [String], entry: Entry) -> Double {
        let pairs = shared.filter { $0.contains(" ") }
        let pairedWords = Set(pairs.flatMap { $0.split(separator: " ").map(String.init) })
        let units = pairs + shared.filter { $0.contains(" ") == false && pairedWords.contains($0) == false }
        guard units.count >= 2 else { return 0 }
        let sharedWeight = units.reduce(0) { total, unit in
            total + adjustedWeight(of: unit) * (unit.contains(" ") ? 1.5 : 1)
        }
        let sharedSet = Set(shared)
        let coverage = entry.parts.map { words in
            let total = words.reduce(0) { $0 + adjustedWeight(of: $1) }
            let matched = words.filter(sharedSet.contains).reduce(0) { $0 + adjustedWeight(of: $1) }
            return total > 0 ? matched / total : 0
        }.max() ?? 0
        let strength = min(1, sharedWeight / Self.fullStrengthWeight)
        return coverage.squareRoot() * strength
    }

    /// The past actions most related to the query, best first. `similarity` adds at most
    /// 0.1 by meaning: it orders near ties and can lift a borderline match, never an
    /// unrelated one.
    func echoes(
        for query: Query,
        excludingSubjects excluded: Set<String> = [],
        similarity: LearningEchoSimilarity? = nil,
        limit: Int = LearningEchoIndex.limit
    ) -> [LearningEcho] {
        let text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty == false, entries.isEmpty == false else { return [] }
        let queryTerms = LearningEchoText.terms(in: text)
        let compactText = Self.compact(text)
        var conceptNames: [String: String] = [:]
        for concept in LearningLibrary.concepts(mentionedIn: text, among: concepts, limit: 8) {
            conceptNames[concept.id] = concept.name
        }

        var candidates: [LearningEcho] = []
        for entry in entries {
            let event = entry.event
            guard excluded.contains(event.subject) == false else { continue }
            if let paperID = query.paperID, event.paperID == paperID,
               let page = query.pageIndex, event.pageIndex == page {
                continue
            }
            if let writingID = query.writingID, event.kind == .citation, event.writingID == writingID {
                continue
            }
            // Already on screen, or already quoted in the writing.
            if let quote = entry.compactQuote, compactText.contains(quote) {
                continue
            }

            let shared = entry.terms.keys.filter { queryTerms[$0] != nil }
            let lexical = lexicalScore(shared: shared, entry: entry)
            let concept = entry.conceptIDs.compactMap { conceptNames[$0] }.sorted().first
            let score = max(lexical, concept == nil ? 0 : Self.conceptScore)
            guard score >= Self.threshold * 0.75 else { continue }
            candidates.append(LearningEcho(
                event: event,
                score: score,
                sharedTerms: displayTerms(shared, entry: entry),
                conceptName: concept
            ))
        }

        if let similarity, candidates.isEmpty == false {
            let queryText = String(text.prefix(1200))
            candidates = candidates.map { candidate in
                var candidate = candidate
                let words = [candidate.event.quote, candidate.event.text].compactMap { $0 }.joined(separator: " ")
                if let meaning = similarity.score(queryText, words) {
                    candidate.score += 0.1 * min(max(meaning, 0), 1)
                }
                return candidate
            }
        }

        // One card per passage: the follow-ups of a conversation and a highlight of the
        // same sentence say the same thing.
        var best: [String: LearningEcho] = [:]
        for candidate in candidates where candidate.score >= Self.threshold {
            let event = candidate.event
            let key = event.quote.map { event.paperID.uuidString + "\n" + Self.compact($0) } ?? event.subject
            // Within a few points, the reader's own words win over a bare highlight.
            func rank(_ echo: LearningEcho) -> Double { echo.score + 0.02 * Double(echo.event.kind.echoPriority) }
            if let current = best[key], rank(current) >= rank(candidate) {
                continue
            }
            best[key] = candidate
        }
        return best.values
            .sorted { ($0.score, $0.event.occurredAt) > ($1.score, $1.event.occurredAt) }
            .prefix(limit)
            .map { $0 }
    }

    /// Up to three shared terms, most distinctive first; a word inside a shown pair is
    /// not shown again.
    private func displayTerms(_ shared: [String], entry: Entry) -> [String] {
        let ordered = shared.sorted {
            let left = ($0.contains(" ") ? 1 : 0, weight(of: $0), $0)
            let right = ($1.contains(" ") ? 1 : 0, weight(of: $1), $1)
            return left > right
        }
        var shown: [String] = []
        var covered = Set<String>()
        for term in ordered where shown.count < 3 {
            // "original distribution" and "distribution disappear" say the same word twice.
            let words = Set(term.split(separator: " ").map(String.init))
            guard covered.isDisjoint(with: words) else { continue }
            shown.append(entry.terms[term] ?? term)
            covered.formUnion(words)
        }
        return shown
    }

    static func compact(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }
}

extension LearningEvent.Kind {
    /// Which of several events about one passage to show: the reader's own words first.
    var echoPriority: Int {
        switch self {
        case .note: 5
        case .question: 4
        case .citation: 3
        case .explanation: 2
        case .translation: 1
        case .highlight: 0
        }
    }
}

/// Closeness in meaning between two passages, 0…1, or nil when it cannot tell (e.g. not
/// English).
struct LearningEchoSimilarity: Sendable {
    var score: @Sendable (String, String) -> Double?

    /// Apple's on-device English sentence embedding. It separates related from unrelated
    /// passages only weakly, so it is used to order near ties, not to decide.
    static let onDevice = LearningEchoSimilarity { first, second in
        OnDeviceSentenceEmbedding.shared.similarity(first, second)
    }
}

private final class OnDeviceSentenceEmbedding: @unchecked Sendable {
    static let shared = OnDeviceSentenceEmbedding()

    private let lock = NSLock()
    private var embedding: NLEmbedding?
    private var didLoad = false

    func similarity(_ first: String, _ second: String) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        if didLoad == false {
            didLoad = true
            embedding = NLEmbedding.sentenceEmbedding(for: .english)
        }
        guard let embedding, Self.isMostlyLatin(first), Self.isMostlyLatin(second),
              embedding.vector(for: first) != nil, embedding.vector(for: second) != nil else { return nil }
        // Measured cosine distances: about 1.14 for related academic sentences and 1.26 for
        // unrelated ones. Map the band 1.3 … 1.1 to 0 … 1.
        let distance = embedding.distance(between: first, and: second, distanceType: .cosine)
        return min(max((1.3 - distance) / 0.2, 0), 1)
    }

    private static func isMostlyLatin(_ text: String) -> Bool {
        let letters = text.filter(\.isLetter)
        guard letters.isEmpty == false else { return false }
        return Double(letters.filter(\.isASCII).count) / Double(letters.count) > 0.8
    }
}

/// Passages the reader marked as unrelated, so they are not offered again in the same
/// paper or writing. Kept beside the learning log, not in SwiftData or UserDefaults.
actor LearningEchoDismissalStore {
    static let shared = LearningEchoDismissalStore()

    private struct File: Codable {
        var version = 1
        /// Context key → dismissed event subjects.
        var dismissed: [String: [String]] = [:]
    }

    private let rootOverride: URL?
    private var cache: File?

    /// `rootDirectory` is the `ReadPaper` application support directory.
    init(rootDirectory: URL? = nil) {
        rootOverride = rootDirectory
    }

    func dismissed() -> [String: Set<String>] {
        load().dismissed.mapValues(Set.init)
    }

    func dismiss(_ subject: String, context: String) {
        var file = load()
        var subjects = file.dismissed[context] ?? []
        guard subjects.contains(subject) == false else { return }
        subjects.append(subject)
        file.dismissed[context] = subjects
        cache = file
        guard let url = try? fileURL() else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder.sortedKeys.encode(file) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func load() -> File {
        if let cache { return cache }
        let file = (try? fileURL())
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode(File.self, from: $0) }
            ?? File()
        cache = file
        return file
    }

    private func fileURL() throws -> URL {
        let root = try rootOverride ?? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("ReadPaper", isDirectory: true)
        return root
            .appendingPathComponent("Learning", isDirectory: true)
            .appendingPathComponent("echo-dismissals.json")
    }
}

private extension JSONEncoder {
    static var sortedKeys: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

/// What the reader has on screen: the readers report it as they scroll.
struct ReadingFocus: Equatable, Sendable {
    var paperID: UUID
    var attachmentID: UUID?
    /// Zero-based; nil for HTML.
    var pageIndex: Int?
    var text: String
}

/// Lets a reader report the text on screen. The reader pane sets it for the attachments
/// that hold the paper's own text (not a translation).
struct ReadingFocusSink {
    var paperID: UUID
    var attachmentIDs: Set<UUID>
    var model: LearningEchoModel

    @MainActor
    func report(attachmentID: UUID?, pageIndex: Int?, text: String) {
        guard let attachmentID, attachmentIDs.contains(attachmentID) else { return }
        model.reportReading(ReadingFocus(paperID: paperID, attachmentID: attachmentID, pageIndex: pageIndex, text: text))
    }
}

private struct ReadingFocusSinkKey: EnvironmentKey {
    static let defaultValue: ReadingFocusSink? = nil
}

extension EnvironmentValues {
    /// Set by the reader pane; the PDF and HTML readers report the text on screen to it.
    var readingFocusSink: ReadingFocusSink? {
        get { self[ReadingFocusSinkKey.self] }
        set { self[ReadingFocusSinkKey.self] = newValue }
    }
}

/// Finds echoes for what the reader has on screen and for the paragraph being written.
/// Only the views showing echoes (and the Learning tab's badge) observe it, so scrolling
/// does not redraw the reader or the inspector.
@MainActor
@Observable
final class LearningEchoModel {
    static let shared = LearningEchoModel()

    struct ReadingEchoes: Equatable {
        var focus: ReadingFocus
        var echoes: [LearningEcho]
    }

    struct WritingEchoes: Equatable {
        var writingID: UUID
        var echoes: [LearningEcho]
    }

    private(set) var reading: ReadingEchoes?
    private(set) var writing: WritingEchoes?
    /// Echoes for the screen that the reader has not seen in the Learning tab yet.
    private(set) var hasUnacknowledgedReadingEchoes = false
    /// Echoes the reader opened in this run of the app: they move to the "seen" pile.
    private(set) var openedSubjects: Set<String> = []

    @ObservationIgnored private let load: @Sendable () async -> (records: [PaperLearningRecord], events: [LearningEvent])
    @ObservationIgnored private let revision: @MainActor () -> Int
    @ObservationIgnored private let similarity: LearningEchoSimilarity?
    @ObservationIgnored private let dismissals: LearningEchoDismissalStore
    @ObservationIgnored private let delay: Duration
    @ObservationIgnored private var cachedIndex: (revision: Int, index: LearningEchoIndex)?
    @ObservationIgnored private var dismissed: [String: Set<String>]?
    @ObservationIgnored private var acknowledgedSubjects: Set<String> = []
    @ObservationIgnored private var readingTask: Task<Void, Never>?
    @ObservationIgnored private var writingTask: Task<Void, Never>?
    @ObservationIgnored private var lastReadingQuery: (focus: ReadingFocus, revision: Int)?
    @ObservationIgnored private var lastWritingQuery: (id: UUID, text: String, revision: Int)?

    init(
        load: @escaping @Sendable () async -> (records: [PaperLearningRecord], events: [LearningEvent])
            = LearningAssistantContext.standard.load,
        revision: @escaping @MainActor () -> Int = {
            LearningRecorder.shared.revision &* 31 &+ LearningOrganizer.shared.revision
        },
        similarity: LearningEchoSimilarity? = .onDevice,
        dismissals: LearningEchoDismissalStore = .shared,
        delay: Duration = .milliseconds(600)
    ) {
        self.load = load
        self.revision = revision
        self.similarity = similarity
        self.dismissals = dismissals
        self.delay = delay
    }

    static func readingContext(_ paperID: UUID) -> String { "paper/\(paperID.uuidString)" }
    static func writingContext(_ writingID: UUID) -> String { "writing/\(writingID.uuidString)" }

    /// Called as the reader scrolls; the search runs once the screen has settled.
    func reportReading(_ focus: ReadingFocus) {
        if let reading, reading.focus.paperID != focus.paperID {
            setReading(nil)
        }
        readingTask?.cancel()
        readingTask = Task { [weak self, delay] in
            try? await Task.sleep(for: delay)
            guard Task.isCancelled == false else { return }
            await self?.refreshReading(focus)
        }
    }

    /// Searches again for the last reported screen, e.g. after the log changed.
    func refreshReading() async {
        guard let focus = lastReadingQuery?.focus ?? reading?.focus else { return }
        await refreshReading(focus)
    }

    /// Called as the writer types or moves the caret. `paragraph` is the text around the
    /// caret; `fullText` is the whole writing, so passages it already quotes are skipped.
    func reportWriting(writingID: UUID, paragraph: String, fullText: String) {
        if let writing, writing.writingID != writingID {
            self.writing = nil
        }
        writingTask?.cancel()
        writingTask = Task { [weak self, delay] in
            try? await Task.sleep(for: delay)
            guard Task.isCancelled == false else { return }
            await self?.refreshWriting(writingID: writingID, paragraph: paragraph, fullText: fullText)
        }
    }

    /// The echoes now shown in the Learning tab have been seen.
    func acknowledgeReadingEchoes() {
        guard let reading else { return }
        acknowledgedSubjects.formUnion(reading.echoes.map(\.id))
        updateUnacknowledged()
    }

    func markOpened(_ echo: LearningEcho) {
        acknowledgedSubjects.insert(echo.id)
        openedSubjects.insert(echo.id)
        updateUnacknowledged()
    }

    /// Not offered again in this paper (or writing).
    func dismiss(_ echo: LearningEcho, context: String) async {
        dismissed?[context, default: []].insert(echo.id)
        if var reading, context == Self.readingContext(reading.focus.paperID) {
            reading.echoes.removeAll { $0.id == echo.id }
            setReading(reading)
        }
        if var writing, context == Self.writingContext(writing.writingID) {
            writing.echoes.removeAll { $0.id == echo.id }
            self.writing = writing
        }
        await dismissals.dismiss(echo.id, context: context)
    }

    // MARK: - Searching

    private func refreshReading(_ focus: ReadingFocus) async {
        let currentRevision = revision()
        if let last = lastReadingQuery, last.focus == focus, last.revision == currentRevision { return }
        lastReadingQuery = (focus, currentRevision)
        guard let index = await index(), index.isEmpty == false else {
            setReading(ReadingEchoes(focus: focus, echoes: []))
            return
        }
        let excluded = await dismissedSubjects(context: Self.readingContext(focus.paperID))
        let query = LearningEchoIndex.Query(text: focus.text, paperID: focus.paperID, pageIndex: focus.pageIndex)
        let similarity = similarity
        let echoes = await Task.detached(priority: .utility) {
            index.echoes(for: query, excludingSubjects: excluded, similarity: similarity)
        }.value
        guard Task.isCancelled == false, lastReadingQuery?.focus == focus else { return }
        setReading(ReadingEchoes(focus: focus, echoes: echoes))
    }

    private func refreshWriting(writingID: UUID, paragraph: String, fullText: String) async {
        let currentRevision = revision()
        if let last = lastWritingQuery, last.id == writingID, last.text == paragraph, last.revision == currentRevision {
            return
        }
        lastWritingQuery = (writingID, paragraph, currentRevision)
        guard paragraph.count >= 12, let index = await index(), index.isEmpty == false else {
            setWriting(WritingEchoes(writingID: writingID, echoes: []))
            return
        }
        let excluded = await dismissedSubjects(context: Self.writingContext(writingID))
        let compactWriting = LearningEchoIndex.compact(fullText)
        let query = LearningEchoIndex.Query(text: paragraph, writingID: writingID)
        let similarity = similarity
        let echoes = await Task.detached(priority: .utility) {
            index.echoes(for: query, excludingSubjects: excluded, similarity: similarity, limit: 8)
                .filter { echo in
                    // A passage the writing already quotes elsewhere is not news.
                    guard let quote = echo.event.quote else { return true }
                    let compact = LearningEchoIndex.compact(quote)
                    return compact.count < 12 || compactWriting.contains(compact) == false
                }
                .prefix(LearningEchoIndex.limit)
                .map { $0 }
        }.value
        guard Task.isCancelled == false, lastWritingQuery?.text == paragraph else { return }
        setWriting(WritingEchoes(writingID: writingID, echoes: echoes))
    }

    private func index() async -> LearningEchoIndex? {
        let currentRevision = revision()
        if let cachedIndex, cachedIndex.revision == currentRevision {
            return cachedIndex.index
        }
        let load = load
        let index = await Task.detached(priority: .utility) {
            let (records, events) = await load()
            return LearningEchoIndex(events: events, records: records)
        }.value
        cachedIndex = (currentRevision, index)
        return index
    }

    private func dismissedSubjects(context: String) async -> Set<String> {
        if dismissed == nil {
            dismissed = await dismissals.dismissed()
        }
        return dismissed?[context] ?? []
    }

    private func setReading(_ newValue: ReadingEchoes?) {
        guard newValue != reading else { return }
        reading = newValue
        updateUnacknowledged()
    }

    private func setWriting(_ newValue: WritingEchoes) {
        guard newValue != writing else { return }
        writing = newValue
    }

    private func updateUnacknowledged() {
        let value = reading?.echoes.contains { acknowledgedSubjects.contains($0.id) == false } ?? false
        if value != hasUnacknowledgedReadingEchoes {
            hasUnacknowledgedReadingEchoes = value
        }
    }
}

/// The part of a writing that echoes are searched for: the paragraph at the caret, with
/// the one before it when it is short (a heading, a sentence just begun), and without
/// Markdown link targets, which are addresses rather than words.
enum WritingEchoFocus {
    static let shortParagraph = 80

    static func paragraph(in text: String, at location: Int) -> String {
        let string = text as NSString
        let location = min(max(0, location), string.length)
        let range = string.paragraphRange(for: NSRange(location: location, length: 0))
        var focus = string.substring(with: range)
        if focus.trimmingCharacters(in: .whitespacesAndNewlines).count < shortParagraph, range.location > 0 {
            let previous = string.paragraphRange(for: NSRange(location: range.location - 1, length: 0))
            focus = string.substring(with: previous) + focus
        }
        return withoutLinkTargets(focus)
    }

    static func withoutLinkTargets(_ markdown: String) -> String {
        markdown.replacingOccurrences(
            of: #"\]\([^)\s]*(\s+"[^"]*")?\)"#,
            with: "]",
            options: .regularExpression
        )
    }
}
