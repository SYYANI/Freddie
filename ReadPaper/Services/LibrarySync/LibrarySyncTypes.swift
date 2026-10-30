import Foundation

enum LibrarySyncCoding {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var value = encoder.singleValueContainer()
            try value.encode(Int64((date.timeIntervalSince1970 * 1000).rounded()))
        }
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(Int64.self)
            return Date(timeIntervalSince1970: Double(value) / 1000)
        }
        return decoder
    }
}

extension UUID {
    var librarySyncID: String { uuidString.lowercased() }
}

struct LibrarySyncScope: Codable, Equatable, Sendable {
    var paperID: UUID?
    var writingID: UUID?
}

/// The wire payload is small even for long notes and pressure-aware ink. The
/// versioned native document lives in an immutable, independently verified blob.
struct LibrarySyncEnvelope: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var documentHash: String
    var scope: LibrarySyncScope?
}

struct LibrarySyncRecord: Codable, Equatable, Sendable {
    var kind: String
    var id: String
    var revision: UInt64
    var deleted: Bool
    var payload: LibrarySyncEnvelope?
    var blobs: [String]
    var deviceID: String
    var updatedAt: String

    var key: String { kind + "/" + id }
}

struct LibrarySyncMutation: Codable, Equatable, Sendable {
    var kind: String
    var id: String
    var baseRevision: UInt64
    var deleted: Bool
    var restore: Bool = false
    var payload: LibrarySyncEnvelope?
    var blobs: [String]
    var key: String { kind + "/" + id }
}

struct LibrarySyncPush: Codable, Equatable, Sendable {
    var requestID: String
    var mutations: [LibrarySyncMutation]
}

struct LibrarySyncReceipt: Codable, Sendable {
    var requestID: String
    var revisions: [UInt64]
}

struct LibrarySyncPage: Codable, Sendable {
    var changes: [LibrarySyncRecord]
    var cursor: UInt64
    var headRevision: UInt64
    var hasMore: Bool
}

struct LibrarySyncInfo: Codable, Equatable, Sendable {
    var protocolVersion: Int
    var storeID: String
    var libraryID: String
    var deviceID: String
}

struct LibrarySyncConfiguration: Codable, Equatable, Sendable {
    var baseURL: URL
    var deviceID: String
    var libraryID: String
    var label: String
    var isEnabled: Bool
}

struct LibrarySyncCredential: Decodable, Sendable {
    struct Device: Decodable, Sendable {
        var id: String
        var libraryID: String
        var label: String
    }
    var baseURL: URL
    var device: Device
    var token: String
}

struct LibrarySyncFile: Codable, Equatable, Sendable {
    var relativePath: String
    var hash: String
    var size: Int64
}

struct LibrarySyncPaper: Codable, Equatable, Sendable {
    var id: UUID
    var arxivID: String?
    var arxivVersion: String?
    var doi: String?
    var title: String
    var abstractText: String
    var authorsStorage: String
    var categoriesStorage: String
    var publishedAt: Date?
    var updatedAt: Date?
    var pdfURLString: String?
    var htmlURLString: String?
    var tagsStorage: String
    var isFavorite: Bool
    var createdAt: Date
    var modifiedAt: Date
}

struct LibrarySyncAttachment: Codable, Equatable, Sendable {
    var id: UUID
    var paperID: UUID
    var kind: String
    var source: String
    var filename: String
    var file: LibrarySyncFile
    var translatedLastPage: Int?
    var createdAt: Date
}

struct LibrarySyncFolder: Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var parentID: UUID?
    var createdAt: Date
    var modifiedAt: Date
}

struct LibrarySyncMembership: Codable, Equatable, Sendable {
    var paperID: UUID
    var folderID: UUID
    var addedAt: Date
}

struct LibrarySyncItemType: Codable, Equatable, Sendable {
    var paperID: UUID
    var rawValue: String
    var assignedAt: Date
}

struct LibrarySyncNote: Codable, Equatable, Sendable {
    var id: UUID
    var paperID: UUID
    var attachmentID: UUID?
    var quote: String
    var body: String
    var pageIndex: Int?
    var htmlSelector: String?
    var createdAt: Date
    var modifiedAt: Date
}

struct LibrarySyncReading: Codable, Equatable, Sendable {
    var paperID: UUID
    var attachmentID: UUID?
    var readerMode: String
    var pageIndex: Int
    var scrollRatio: Double
    var htmlAnchor: String?
    var modifiedAt: Date
}

struct LibrarySyncTranslation: Codable, Equatable, Sendable {
    var id: UUID
    var sourceType: String
    var targetLanguage: String
    var sourceHash: String
    var sourceText: String
    var translatedText: String
    var modelName: String
    var createdAt: Date
    var modifiedAt: Date
    // Part of the cache identity: switching provider/model must not hit another
    // route's translation. Absent in documents from earlier builds.
    var providerProfileID: UUID?
    var modelProfileID: UUID?

    var cacheKey: String {
        [sourceType, targetLanguage, sourceHash, providerProfileID?.librarySyncID ?? "", modelProfileID?.librarySyncID ?? "", modelName]
            .joined(separator: "|")
    }
}

struct LibrarySyncTranslations: Codable, Equatable, Sendable {
    var paperID: UUID
    var segments: [LibrarySyncTranslation]
}

struct LibrarySyncAnnotation: Codable, Equatable, Sendable {
    var paperID: UUID
    var attachmentID: UUID
    var annotation: PDFAnnotationRecord
}

struct LibrarySyncResource: Codable, Equatable, Sendable {
    var scope: LibrarySyncScope
    var file: LibrarySyncFile
    var id: String {
        Hashing.sha256Hex(((scope.paperID ?? scope.writingID)?.librarySyncID ?? "") + "/" + file.relativePath)
    }
}

struct LibrarySyncWriting: Codable, Equatable, Sendable {
    var id: UUID
    var title: String
    var createdAt: Date
    var modifiedAt: Date
    var file: LibrarySyncFile
}

/// A versioned DTO, separate from @Model definitions and all local absolute paths.
struct LibrarySyncDocument: Codable, Equatable, Sendable {
    enum Content: Codable, Equatable, Sendable {
        case paper(LibrarySyncPaper)
        case attachment(LibrarySyncAttachment)
        case folder(LibrarySyncFolder)
        case membership(LibrarySyncMembership)
        case itemType(LibrarySyncItemType)
        case note(LibrarySyncNote)
        case reading(LibrarySyncReading)
        case translations(LibrarySyncTranslations)
        case annotation(LibrarySyncAnnotation)
        case resource(LibrarySyncResource)
        case writing(LibrarySyncWriting)
    }
    var schemaVersion = 1
    var content: Content

    var identity: (kind: String, id: String) {
        switch content {
        case .paper(let value): ("paper", value.id.librarySyncID)
        case .attachment(let value): ("attachment", value.id.librarySyncID)
        case .folder(let value): ("folder", value.id.librarySyncID)
        case .membership(let value): ("folderMembership", value.paperID.librarySyncID)
        case .itemType(let value): ("itemType", value.paperID.librarySyncID)
        case .note(let value): ("note", value.id.librarySyncID)
        case .reading(let value): ("readingState", value.paperID.librarySyncID)
        case .translations(let value): ("translationSegment", value.paperID.librarySyncID)
        case .annotation(let value): ("pdfAnnotation", value.annotation.id.librarySyncID)
        case .resource(let value): ("htmlState", value.id)
        case .writing(let value): ("writing", value.id.librarySyncID)
        }
    }
    var key: String { identity.kind + "/" + identity.id }
    var scope: LibrarySyncScope {
        switch content {
        case .paper(let v): .init(paperID: v.id)
        case .attachment(let v): .init(paperID: v.paperID)
        case .folder: .init()
        case .membership(let v): .init(paperID: v.paperID)
        case .itemType(let v): .init(paperID: v.paperID)
        case .note(let v): .init(paperID: v.paperID)
        case .reading(let v): .init(paperID: v.paperID)
        case .translations(let v): .init(paperID: v.paperID)
        case .annotation(let v): .init(paperID: v.paperID)
        case .resource(let v): v.scope
        case .writing(let v): .init(writingID: v.id)
        }
    }
    var files: [LibrarySyncFile] {
        switch content {
        case .attachment(let v): [v.file]
        case .resource(let v): [v.file]
        case .writing(let v): [v.file]
        default: []
        }
    }
    var title: String {
        switch content {
        case .paper(let v): v.title
        case .folder(let v): v.name
        case .writing(let v): v.title
        case .attachment(let v): v.filename
        case .resource(let v): v.file.relativePath
        default: identity.kind
        }
    }
}

struct LibrarySyncEntry: Codable, Equatable, Sendable {
    var kind: String
    var id: String
    var payload: LibrarySyncEnvelope
    var blobs: [String]
    var scope: LibrarySyncScope
    var title: String
    var key: String { kind + "/" + id }
}

enum LibrarySyncError: Error, LocalizedError, Equatable {
    case message(String)
    case server(status: Int, code: String, retryAfter: TimeInterval?)
    case conflict(LibrarySyncRecord?)
    case fileChanged

    /// The server refused the request without committing it, and replaying the
    /// same request can only fail again. Transient and auth failures excluded.
    var rejectsRequest: Bool {
        guard case .server(let status, _, _) = self else { return false }
        return status == 507 || ((400..<500).contains(status) && ![401, 408, 429].contains(status))
    }

    var errorDescription: String? {
        switch self {
        case .message(let message): AppLocalization.localized(message)
        case .conflict: AppLocalization.localized("Some changes need conflict resolution.")
        case .fileChanged: AppLocalization.localized("A file is still changing. Sync will retry shortly.")
        case .server(let status, _, _):
            switch status {
            case 401: AppLocalization.localized("This device credential is invalid or has been revoked. Import a new credential.")
            case 429, 503: AppLocalization.localized("The sync server is busy. Freddie will retry shortly.")
            case 507: AppLocalization.localized("The sync server has reached its storage limit.")
            default: AppLocalization.format("Sync server returned HTTP %d.", status)
            }
        }
    }
}
