import Foundation
import PDFKit
import SwiftData

/// A page saved from the browser extension in `BrowserExtension/`, as it posts it to
/// `BrowserClipperServer`. The extension captures the page as the reader sees it, logged in
/// and after scripts have run, which a download by URL often cannot.
struct BrowserClip: Decodable, Sendable {
    enum Kind: String, Decodable, Sendable {
        /// Rendered HTML from the page.
        case html
        /// The PDF the tab shows, or the one the page links as its full text.
        case pdf
        /// An arXiv page, imported like an arXiv ID.
        case arxiv
    }

    enum Extraction: String, Decodable, Sendable {
        /// The article region the reader confirmed; Readability tidies it.
        case article
        /// The reader's selection, as is.
        case selection
        /// The whole page in its own layout.
        case page

        var contentExtraction: HTMLLocalizer.ContentExtraction {
            switch self {
            case .article: .clipped(simplifies: true)
            case .selection: .clipped(simplifies: false)
            case .page: .original
            }
        }
    }

    /// What the page says about itself (`citation_*`, Dublin Core, Open Graph, JSON-LD).
    struct Metadata: Decodable, Sendable {
        var authors: [String]?
        var doi: String?
        var abstract: String?
        var publishedDate: String?
    }

    var kind: Kind
    /// The page's address.
    var url: String
    /// Empty to use the title found in the saved file.
    var title: String?
    var html: String?
    var extraction: Extraction?
    /// The PDF as the browser fetched it, with the reader's cookies; base64 in JSON.
    var pdfData: Data?
    /// Downloaded by the app when the browser could not fetch it.
    var pdfURL: String?
    var metadata: Metadata?
    var folderID: UUID?
    /// Saves again even when the library has this page.
    var allowDuplicate: Bool?

    private enum CodingKeys: String, CodingKey {
        case kind, url, title, html, extraction
        case pdfData = "pdfBase64"
        case pdfURL, metadata, folderID, allowDuplicate
    }
}

enum BrowserClipError: Error, LocalizedError, Equatable {
    case missingContent
    case notAPDF

    var errorDescription: String? {
        switch self {
        case .missingContent:
            AppLocalization.localized("The browser sent nothing to save.")
        case .notAPDF:
            AppLocalization.localized("The downloaded file is not a PDF.")
        }
    }
}

@MainActor
final class BrowserClipImporter {
    struct Result {
        var paper: Paper
        /// The library already had the page; nothing was saved.
        var isExisting: Bool
    }

    private let fileStore: PaperFileStore
    private let htmlLocalizer: HTMLLocalizer
    private let session: URLSession
    private let paperImporter: PaperImporter
    private let fullTextSearchService: PaperFullTextSearchService

    init(
        fileStore: PaperFileStore = PaperFileStore(),
        htmlLocalizer: HTMLLocalizer = HTMLLocalizer(),
        session: URLSession = .shared,
        paperImporter: PaperImporter? = nil
    ) {
        self.fileStore = fileStore
        self.htmlLocalizer = htmlLocalizer
        self.session = session
        self.paperImporter = paperImporter ?? PaperImporter(
            fileStore: fileStore,
            htmlLocalizer: htmlLocalizer,
            session: session
        )
        self.fullTextSearchService = PaperFullTextSearchService(fileStore: fileStore)
    }

    func importClip(_ clip: BrowserClip, modelContext: ModelContext) async throws -> Result {
        let result: Result
        switch clip.kind {
        case .arxiv:
            result = try await importArxiv(clip, modelContext: modelContext)
        case .html:
            result = try await importHTML(clip, modelContext: modelContext)
        case .pdf:
            result = try await importPDF(clip, modelContext: modelContext)
        }
        if !result.isExisting, let folderID = clip.folderID {
            try moveToFolder(result.paper.id, folderID: folderID, modelContext: modelContext)
        }
        return result
    }

    private func importArxiv(_ clip: BrowserClip, modelContext: ModelContext) async throws -> Result {
        let identifier = try ArxivClient.normalizeIdentifier(clip.url)
        if let existing = try modelContext.fetch(FetchDescriptor<Paper>())
            .first(where: { $0.arxivID == identifier.baseID }) {
            return Result(paper: existing, isExisting: true)
        }
        let paper = try await paperImporter.importArxiv(clip.url, modelContext: modelContext, includeHTML: true)
        return Result(paper: paper, isExisting: false)
    }

    /// A page already in the library gets the clip as a second file, as Zotero adds a PDF to
    /// an item with a snapshot; only a paper with that kind of file already is reported back.
    private func importHTML(_ clip: BrowserClip, modelContext: ModelContext) async throws -> Result {
        let sourceURL = try PaperImporter.normalizeWebPageURL(clip.url)
        guard let html = clip.html, !html.isEmpty else { throw BrowserClipError.missingContent }
        let existing = clip.allowDuplicate == true ? nil : try modelContext.fetch(FetchDescriptor<Paper>())
            .first(where: { $0.htmlURLString == sourceURL.absoluteString })
        if let existing, try hasAttachment(.html, paperID: existing.id, modelContext: modelContext) {
            return Result(paper: existing, isExisting: true)
        }

        let paper = existing ?? Paper(
            title: PaperImporter.fallbackWebPageTitle(for: sourceURL),
            htmlURLString: sourceURL.absoluteString
        )
        let outputURL = try fileStore.directory(for: paper.id).appendingPathComponent("paper.html")
        do {
            paper.localDirectoryPath = try fileStore.directory(for: paper.id).path
            let htmlURL = try await htmlLocalizer.localize(
                htmlData: Data(html.utf8),
                sourceURL: sourceURL,
                outputURL: outputURL,
                resourcesDirectory: fileStore.resourcesDirectory(for: paper),
                extraction: (clip.extraction ?? .article).contentExtraction
            )
            try Task.checkCancellation()
            if existing == nil {
                paper.title = nonEmpty(clip.title) ?? PaperImporter.extractHTMLTitle(from: htmlURL) ?? paper.title
                modelContext.insert(paper)
            }
            apply(clip.metadata, to: paper, keepingExisting: existing != nil)

            let attachment = PaperAttachment(
                paperID: paper.id,
                kind: .html,
                source: .webPage,
                filename: htmlURL.lastPathComponent,
                filePath: htmlURL.path
            )
            modelContext.insert(attachment)
            _ = try? fullTextSearchService.rebuild(paper: paper, attachments: [attachment])
            paper.modifiedAt = Date()
            try modelContext.save()
        } catch {
            discard(paper, isNew: existing == nil, file: outputURL, modelContext: modelContext)
            throw error
        }
        AuthorExtractionService.extractAuthorsIfNeeded(for: paper, modelContext: modelContext)
        return Result(paper: paper, isExisting: false)
    }

    private func importPDF(_ clip: BrowserClip, modelContext: ModelContext) async throws -> Result {
        let pageURL = try PaperImporter.normalizeWebPageURL(clip.url)
        let pdfURL = try nonEmpty(clip.pdfURL).map(PaperImporter.normalizeWebPageURL) ?? pageURL
        let doi = nonEmpty(clip.metadata?.doi).flatMap(PaperImporter.extractDOI(from:))
        let existing = clip.allowDuplicate == true ? nil : try modelContext.fetch(FetchDescriptor<Paper>()).first(where: {
            $0.pdfURLString == pdfURL.absoluteString
                || $0.htmlURLString == pageURL.absoluteString
                || (doi != nil && $0.doi?.caseInsensitiveCompare(doi ?? "") == .orderedSame)
        })
        if let existing, try hasAttachment(.pdf, paperID: existing.id, modelContext: modelContext) {
            return Result(paper: existing, isExisting: true)
        }

        let data = try await pdfData(for: clip, pdfURL: pdfURL)
        guard let document = PDFDocument(data: data) else { throw BrowserClipError.notAPDF }

        let paper = existing ?? Paper(
            title: PaperImporter.fallbackWebPageTitle(for: pdfURL),
            htmlURLString: pageURL.absoluteString
        )
        let outputURL = try fileStore.directory(for: paper.id).appendingPathComponent("paper.pdf")
        do {
            paper.localDirectoryPath = try fileStore.directory(for: paper.id).path
            let pdfFile = try fileStore.write(data, named: "paper.pdf", for: paper.id)
            paper.pdfURLString = paper.pdfURLString ?? pdfURL.absoluteString

            // The page's own metadata, which the reader may have edited, comes before
            // what the PDF says about itself.
            let attributes = document.documentAttributes ?? [:]
            let searchableText = ([PaperImporter.extractText(from: document, maxPages: 3)]
                + PaperImporter.extractMetadataStrings(from: attributes))
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            if paper.arxivID == nil, let arxiv = PaperImporter.extractArxivID(from: searchableText) {
                paper.arxivID = arxiv.baseID
                paper.arxivVersion = arxiv.version
            }
            paper.doi = paper.doi ?? PaperImporter.extractDOI(from: searchableText)
            if existing == nil {
                if let author = nonEmpty(attributes[PDFDocumentAttribute.authorAttribute] as? String) {
                    paper.authors = [author]
                }
                paper.title = nonEmpty(clip.title)
                    ?? nonEmpty(attributes[PDFDocumentAttribute.titleAttribute] as? String)
                    ?? paper.title
                modelContext.insert(paper)
            }
            apply(clip.metadata, to: paper, keepingExisting: existing != nil)

            modelContext.insert(PaperAttachment(
                paperID: paper.id,
                kind: .pdf,
                source: .webPage,
                filename: pdfFile.lastPathComponent,
                filePath: pdfFile.path
            ))
            paper.modifiedAt = Date()
            try modelContext.save()
        } catch {
            discard(paper, isNew: existing == nil, file: outputURL, modelContext: modelContext)
            throw error
        }
        AuthorExtractionService.extractAuthorsIfNeeded(for: paper, modelContext: modelContext)
        return Result(paper: paper, isExisting: false)
    }

    private func hasAttachment(_ kind: AttachmentKind, paperID: UUID, modelContext: ModelContext) throws -> Bool {
        try modelContext.fetch(FetchDescriptor<PaperAttachment>(
            predicate: #Predicate { $0.paperID == paperID }
        )).contains { $0.kind == kind }
    }

    /// A new paper goes away with its folder; a paper that was already there only loses
    /// the file this clip wrote and keeps its other changes unsaved.
    private func discard(_ paper: Paper, isNew: Bool, file: URL, modelContext: ModelContext) {
        if isNew {
            try? fileStore.removeDirectory(for: paper.id)
        } else {
            try? fileStore.fileManager.removeItem(at: file)
            modelContext.rollback()
        }
    }

    private func pdfData(for clip: BrowserClip, pdfURL: URL) async throws -> Data {
        if let data = clip.pdfData {
            return data
        }
        let (data, response) = try await session.data(for: BrowserRequestHeaders.request(for: pdfURL, accept: .resource))
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw PaperImportError.webPageHTTPError(statusCode: http.statusCode)
        }
        return data
    }

    /// `keepingExisting` only fills what the paper lacks, so a second clip does not undo
    /// the reader's edits.
    private func apply(_ metadata: BrowserClip.Metadata?, to paper: Paper, keepingExisting: Bool) {
        guard let metadata else { return }
        let authors = (metadata.authors ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !authors.isEmpty, !keepingExisting || paper.authors.isEmpty {
            paper.authors = authors
        }
        if let doi = nonEmpty(metadata.doi).flatMap(PaperImporter.extractDOI(from:)), !keepingExisting || paper.doi == nil {
            paper.doi = doi
        }
        if let abstract = nonEmpty(metadata.abstract), !keepingExisting || paper.abstractText.isEmpty {
            paper.abstractText = abstract
        }
        if let date = nonEmpty(metadata.publishedDate).flatMap(Self.parseDate), !keepingExisting || paper.publishedAt == nil {
            paper.publishedAt = date
        }
    }

    /// A folder deleted since the extension listed it leaves the paper unfiled.
    private func moveToFolder(_ paperID: UUID, folderID: UUID, modelContext: ModelContext) throws {
        let folders = try modelContext.fetch(FetchDescriptor<PaperFolder>(
            predicate: #Predicate<PaperFolder> { $0.id == folderID }
        ))
        guard !folders.isEmpty else { return }
        try PaperFolderService().move(paperID: paperID, to: folderID, modelContext: modelContext)
    }

    /// Dates as pages write them in `citation_publication_date` and similar tags:
    /// ISO 8601 with or without a time, `2017/06/12`, `2017-06` or a bare year.
    nonisolated static func parseDate(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let isoFormatter = ISO8601DateFormatter()
        if let date = isoFormatter.date(from: trimmed) {
            return date
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in ["yyyy-MM-dd", "yyyy/MM/dd", "yyyy-MM", "yyyy/MM", "yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: String(trimmed.prefix(format.count))) {
                return date
            }
        }
        return nil
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
