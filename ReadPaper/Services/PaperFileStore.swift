import Foundation

struct PaperFileStore {
    let fileManager: FileManager
    private let applicationSupportOverride: URL?

    init(fileManager: FileManager = .default, applicationSupportDirectory: URL? = nil) {
        self.fileManager = fileManager
        self.applicationSupportOverride = applicationSupportDirectory
    }

    var applicationSupportDirectory: URL {
        get throws {
            if let applicationSupportOverride {
                return applicationSupportOverride
            }
            return try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            .appendingPathComponent("ReadPaper", isDirectory: true)
        }
    }

    var libraryDirectory: URL {
        get throws {
            try applicationSupportDirectory.appendingPathComponent("Library", isDirectory: true)
        }
    }

    var toolDirectory: URL {
        get throws {
            try applicationSupportDirectory.appendingPathComponent("Tools", isDirectory: true)
        }
    }

    func ensureRootDirectories() throws {
        try ensureDirectory(libraryDirectory)
        try ensureDirectory(toolDirectory)
    }

    func directory(for paperID: UUID) throws -> URL {
        let directory = try libraryDirectory.appendingPathComponent(paperID.uuidString, isDirectory: true)
        try ensureDirectory(directory)
        try ensureDirectory(directory.appendingPathComponent("Resources", isDirectory: true))
        try ensureDirectory(directory.appendingPathComponent("translations", isDirectory: true))
        try ensureDirectory(directory.appendingPathComponent("notes", isDirectory: true))
        return directory
    }

    func resourcesDirectory(for paper: Paper) throws -> URL {
        try directory(for: paper.id).appendingPathComponent("Resources", isDirectory: true)
    }

    func notesDirectory(for paperID: UUID) throws -> URL {
        try directory(for: paperID).appendingPathComponent("notes", isDirectory: true)
    }

    func translationsDirectory(for paper: Paper) throws -> URL {
        try translationsDirectory(for: paper.id)
    }

    func translationsDirectory(for paperID: UUID) throws -> URL {
        try directory(for: paperID).appendingPathComponent("translations", isDirectory: true)
    }

    func latexSemanticDirectory(for paperID: UUID) throws -> URL {
        let directory = try self.directory(for: paperID)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("LaTeXSemantic", isDirectory: true)
        try ensureDirectory(directory)
        return directory
    }

    func latexTranslationDirectory(
        for paperID: UUID,
        targetLanguage: String,
        cacheIdentity: String
    ) throws -> URL {
        let language = safePathComponent(targetLanguage, fallback: "target")
        let identity = String(Hashing.sha256Hex(cacheIdentity).prefix(16))
        let directory = try translationsDirectory(for: paperID)
            .appendingPathComponent("latex", isDirectory: true)
            .appendingPathComponent(language, isDirectory: true)
            .appendingPathComponent(identity, isDirectory: true)
        try ensureDirectory(directory)
        return directory
    }

    func write(_ data: Data, named filename: String, for paperID: UUID) throws -> URL {
        let target = try directory(for: paperID).appendingPathComponent(filename)
        try data.write(to: target, options: .atomic)
        return target
    }

    func copyPDF(from source: URL, for paperID: UUID) throws -> URL {
        guard source.pathExtension.lowercased() == "pdf" else {
            throw PaperImportError.unsupportedFile(source)
        }
        let target = try directory(for: paperID).appendingPathComponent("paper.pdf")
        if fileManager.fileExists(atPath: target.path) {
            try fileManager.removeItem(at: target)
        }
        try fileManager.copyItem(at: source, to: target)
        return target
    }

    func removeDirectory(for paperID: UUID) throws {
        let target = try libraryDirectory.appendingPathComponent(paperID.uuidString, isDirectory: true)
        guard fileManager.fileExists(atPath: target.path) else { return }
        try fileManager.removeItem(at: target)
    }

    /// Resolves a path saved inside a previous app container against the current
    /// Application Support directory. iOS may change the app container UUID when
    /// Xcode installs a new build, so absolute sandbox paths must not be treated as
    /// stable identifiers.
    func resolvedManagedURL(
        forPersistedPath path: String,
        paperID: UUID,
        isDirectory: Bool = false
    ) -> URL {
        let persistedURL = URL(fileURLWithPath: path, isDirectory: isDirectory)
        guard let relativeComponents = managedRelativeComponents(
            in: persistedURL,
            paperID: paperID
        ), let currentLibraryDirectory = try? libraryDirectory else {
            return persistedURL
        }

        let resolvedURL = relativeComponents.reduce(currentLibraryDirectory) { partialURL, component in
            partialURL.appendingPathComponent(component)
        }
        return URL(fileURLWithPath: resolvedURL.path, isDirectory: isDirectory)
    }

    private func managedRelativeComponents(in url: URL, paperID: UUID) -> ArraySlice<String>? {
        let components = url.standardizedFileURL.pathComponents
        let paperIDComponent = paperID.uuidString.lowercased()

        guard let paperIndex = components.indices.last(where: { index in
            components[index].lowercased() == paperIDComponent &&
                index >= 2 &&
                components[index - 1] == "Library" &&
                components[index - 2] == "ReadPaper"
        }) else {
            return nil
        }

        return components[paperIndex...]
    }

    func ensureDirectory(_ url: URL) throws {
        if !fileManager.fileExists(atPath: url.path) {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    private func safePathComponent(_ value: String, fallback: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let characters = value.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(String(scalar)) : "_"
        }
        let result = String(characters)
        return result.isEmpty ? fallback : result
    }
}
