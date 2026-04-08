import Foundation
import SwiftData

@Model
final class Paper {
    @Attribute(.unique) var id: UUID
    var arxivID: String?
    var arxivVersion: String?
    var title: String
    var abstractText: String
    var authorsStorage: String
    var categoriesStorage: String
    var publishedAt: Date?
    var updatedAt: Date?
    var pdfURLString: String?
    var htmlURLString: String?
    var localDirectoryPath: String
    var tagsStorage: String
    var isFavorite: Bool
    var createdAt: Date
    var modifiedAt: Date

    init(
        id: UUID = UUID(),
        arxivID: String? = nil,
        arxivVersion: String? = nil,
        title: String,
        abstractText: String = "",
        authors: [String] = [],
        categories: [String] = [],
        publishedAt: Date? = nil,
        updatedAt: Date? = nil,
        pdfURLString: String? = nil,
        htmlURLString: String? = nil,
        localDirectoryPath: String = "",
        tags: [String] = [],
        isFavorite: Bool = false,
        createdAt: Date = Date(),
        modifiedAt: Date = Date()
    ) {
        self.id = id
        self.arxivID = arxivID
        self.arxivVersion = arxivVersion
        self.title = title
        self.abstractText = abstractText
        self.authorsStorage = Paper.encodeList(authors)
        self.categoriesStorage = Paper.encodeList(categories)
        self.publishedAt = publishedAt
        self.updatedAt = updatedAt
        self.pdfURLString = pdfURLString
        self.htmlURLString = htmlURLString
        self.localDirectoryPath = localDirectoryPath
        self.tagsStorage = Paper.encodeList(tags)
        self.isFavorite = isFavorite
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }

    var authors: [String] {
        get { Paper.decodeList(authorsStorage) }
        set { authorsStorage = Paper.encodeList(newValue) }
    }

    var categories: [String] {
        get { Paper.decodeList(categoriesStorage) }
        set { categoriesStorage = Paper.encodeList(newValue) }
    }

    var tags: [String] {
        get { Paper.decodeList(tagsStorage) }
        set { tagsStorage = Paper.encodeList(newValue) }
    }

    var localDirectoryURL: URL? {
        guard !localDirectoryPath.isEmpty else { return nil }
        return URL(fileURLWithPath: localDirectoryPath, isDirectory: true)
    }

    var displayAuthors: String {
        let names = authors
        guard !names.isEmpty else { return "Unknown authors" }
        if names.count <= 3 {
            return names.joined(separator: ", ")
        }
        return names.prefix(3).joined(separator: ", ") + " et al."
    }

    static func encodeList(_ values: [String]) -> String {
        values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    static func decodeList(_ storage: String) -> [String] {
        storage
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
