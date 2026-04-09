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

    func translationsDirectory(for paper: Paper) throws -> URL {
        try directory(for: paper.id).appendingPathComponent("translations", isDirectory: true)
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

    func ensureDirectory(_ url: URL) throws {
        if !fileManager.fileExists(atPath: url.path) {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}
