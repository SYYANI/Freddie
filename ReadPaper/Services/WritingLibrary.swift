import Foundation
import Observation

/// The user's writings and the one open in the inspector's Writing tab.
///
/// Kept out of SwiftData (see `WritingStore`) and out of `@Query`, so saving a writing
/// while typing only updates the views that read this library.
@MainActor
@Observable
final class WritingLibrary {
    static let shared = WritingLibrary()
    static let currentWritingUserDefaultsKey = "ReadPaper.Writing.CurrentWritingID"

    /// Most recently modified first.
    private(set) var writings: [WritingMetadata] = []
    private(set) var currentWritingID: UUID?
    /// The last failed load or save, shown under the editor until a save succeeds.
    private(set) var lastErrorMessage: String?

    @ObservationIgnored private let store: WritingStore
    @ObservationIgnored private let userDefaults: UserDefaults
    @ObservationIgnored private var hasLoaded = false

    init(store: WritingStore = WritingStore(), userDefaults: UserDefaults = .standard) {
        self.store = store
        self.userDefaults = userDefaults
    }

    var currentWriting: WritingMetadata? {
        guard let currentWritingID else { return nil }
        return writings.first { $0.id == currentWritingID }
    }

    func loadIfNeeded() {
        guard hasLoaded == false else { return }
        reload()
    }

    func reload() {
        hasLoaded = true
        do {
            writings = try store.loadAll()
            lastErrorMessage = nil
        } catch {
            writings = []
            lastErrorMessage = AppLocalization.format("Unable to load writings: %@", error.localizedDescription)
        }
        let storedID = userDefaults.string(forKey: Self.currentWritingUserDefaultsKey).flatMap(UUID.init(uuidString:))
        selectWriting(writings.contains { $0.id == storedID } ? storedID : writings.first?.id)
    }

    func metadata(for id: UUID) -> WritingMetadata? {
        writings.first { $0.id == id }
    }

    func selectWriting(_ id: UUID?) {
        if currentWritingID != id {
            currentWritingID = id
        }
        if let id {
            userDefaults.set(id.uuidString, forKey: Self.currentWritingUserDefaultsKey)
        } else {
            userDefaults.removeObject(forKey: Self.currentWritingUserDefaultsKey)
        }
    }

    /// Creates a writing and makes it the current one.
    @discardableResult
    func createWriting(markdown: String = "") throws -> WritingMetadata {
        loadIfNeeded()
        let metadata = try store.create(markdown: markdown)
        writings.insert(metadata, at: 0)
        selectWriting(metadata.id)
        return metadata
    }

    func deleteWriting(_ id: UUID) throws {
        try store.delete(id)
        writings.removeAll { $0.id == id }
        if currentWritingID == id {
            selectWriting(writings.first?.id)
        }
    }

    func markdown(for id: UUID) throws -> String {
        try store.loadMarkdown(for: id)
    }

    func markdownURL(for id: UUID) -> URL? {
        try? store.markdownURL(for: id)
    }

    /// Saves right away. Writings that were deleted in the meantime are not recreated.
    @discardableResult
    func save(markdown: String, for id: UUID) -> Bool {
        guard let index = writings.firstIndex(where: { $0.id == id }) else { return false }
        do {
            let metadata = try store.save(markdown: markdown, for: id, createdAt: writings[index].createdAt)
            writings.remove(at: index)
            writings.insert(metadata, at: 0)
            if lastErrorMessage != nil {
                lastErrorMessage = nil
            }
            return true
        } catch {
            lastErrorMessage = AppLocalization.format("Unable to save the writing: %@", error.localizedDescription)
            return false
        }
    }

    /// Writings with at least one citation of the paper, most recently modified first.
    func writings(citing paperID: UUID) -> [WritingMetadata] {
        writings.filter { $0.citedPaperIDs.contains(paperID) }
    }
}
