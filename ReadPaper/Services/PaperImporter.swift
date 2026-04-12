import Foundation
import PDFKit
import SwiftData

@MainActor
final class PaperImporter {
    private let fileStore: PaperFileStore
    private let arxivClient: ArxivClient
    private let htmlLocalizer: HTMLLocalizer
    private let session: URLSession

    init(
        fileStore: PaperFileStore = PaperFileStore(),
        arxivClient: ArxivClient = .shared,
        htmlLocalizer: HTMLLocalizer = HTMLLocalizer(),
        session: URLSession = .shared
    ) {
        self.fileStore = fileStore
        self.arxivClient = arxivClient
        self.htmlLocalizer = htmlLocalizer
        self.session = session
    }

    func importArxiv(
        _ rawValue: String,
        modelContext: ModelContext,
        onProgress: ((ArxivImportProgress) -> Void)? = nil
    ) async throws -> Paper {
        onProgress?(.resolvingInput())
        let identifier = try ArxivClient.normalizeIdentifier(rawValue)
        onProgress?(.resolvingInput(identifier: identifier.queryID))
        let existingPapers = try modelContext.fetch(FetchDescriptor<Paper>())
        if let existing = existingPapers.first(where: { $0.arxivID == identifier.baseID }) {
            return existing
        }

        onProgress?(.fetchingMetadata(for: identifier.queryID))
        let metadata = try await arxivClient.fetchMetadata(for: rawValue)
        onProgress?(.creatingLibraryEntry(title: metadata.title.isEmpty ? metadata.arxivID : metadata.title))
        let paper = Paper(
            arxivID: metadata.arxivID,
            arxivVersion: metadata.arxivVersion,
            title: metadata.title.isEmpty ? metadata.arxivID : metadata.title,
            abstractText: metadata.abstractText,
            authors: metadata.authors,
            categories: metadata.categories,
            publishedAt: metadata.publishedAt,
            updatedAt: metadata.updatedAt,
            pdfURLString: metadata.pdfURL?.absoluteString,
            htmlURLString: metadata.absURL?.absoluteString
        )
        paper.localDirectoryPath = try fileStore.directory(for: paper.id).path
        modelContext.insert(paper)

        if let pdfURL = metadata.pdfURL ?? URL(string: "https://arxiv.org/pdf/\(metadata.arxivID)") {
            onProgress?(.downloadingPDF(for: metadata.arxivID))
            let (data, response) = try await session.data(from: pdfURL)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }
            let pdfFile = try fileStore.write(data, named: "paper.pdf", for: paper.id)
            modelContext.insert(PaperAttachment(
                paperID: paper.id,
                kind: .pdf,
                source: .arxivPDF,
                filename: pdfFile.lastPathComponent,
                filePath: pdfFile.path
            ))
        }

        let htmlImported = await importArxivHTMLIfAvailable(
            for: paper,
            modelContext: modelContext,
            onProgress: onProgress
        )
        onProgress?(.finalizing(htmlImported: htmlImported))
        try modelContext.save()
        return paper
    }

    func importLocalPDF(_ url: URL, modelContext: ModelContext) throws -> Paper {
        guard url.pathExtension.lowercased() == "pdf" else {
            throw PaperImportError.unsupportedFile(url)
        }
        let pdfDocument = PDFDocument(url: url)
        let attributes = pdfDocument?.documentAttributes ?? [:]
        let extractedTitle = (attributes[PDFDocumentAttribute.titleAttribute] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let extractedAuthor = (attributes[PDFDocumentAttribute.authorAttribute] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = Self.extractText(from: pdfDocument, maxPages: 3)
        let searchableText = ([text] + Self.extractMetadataStrings(from: attributes))
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let arxiv = Self.extractArxivID(from: searchableText)
        let doi = Self.extractDOI(from: searchableText)

        let title = [extractedTitle, url.deletingPathExtension().lastPathComponent]
            .compactMap { $0 }
            .first { !$0.isEmpty } ?? AppLocalization.localized("Untitled PDF")
        let authors = extractedAuthor.map { [$0] } ?? []

        let paper = Paper(
            arxivID: arxiv?.baseID,
            arxivVersion: arxiv?.version,
            doi: doi,
            title: title,
            authors: authors
        )
        paper.localDirectoryPath = try fileStore.directory(for: paper.id).path
        let pdfFile = try fileStore.copyPDF(from: url, for: paper.id)
        modelContext.insert(paper)
        modelContext.insert(PaperAttachment(
            paperID: paper.id,
            kind: .pdf,
            source: .localImport,
            filename: pdfFile.lastPathComponent,
            filePath: pdfFile.path
        ))
        try modelContext.save()
        return paper
    }

    func importArxivHTMLIfAvailable(
        for paper: Paper,
        modelContext: ModelContext,
        onProgress: ((ArxivImportProgress) -> Void)? = nil
    ) async -> Bool {
        guard let arxivID = paper.arxivID else { return false }
        let outputURL: URL
        let resourcesDirectory: URL
        do {
            outputURL = try fileStore.directory(for: paper.id).appendingPathComponent("paper.html")
            resourcesDirectory = try fileStore.resourcesDirectory(for: paper)
        } catch {
            return false
        }

        let candidates = [
            (ArxivImportProgress.HTMLSource.arxiv, URL(string: "https://arxiv.org/html/\(arxivID)")),
            (ArxivImportProgress.HTMLSource.ar5iv, URL(string: "https://ar5iv.labs.arxiv.org/html/\(arxivID)"))
        ].compactMap { source, url in
            url.map { (source, $0) }
        }

        for (index, candidate) in candidates.enumerated() {
            onProgress?(.importingHTML(from: candidate.0, isFallback: index > 0))
            do {
                let htmlURL = try await htmlLocalizer.fetchAndLocalize(
                    from: candidate.1,
                    outputURL: outputURL,
                    resourcesDirectory: resourcesDirectory
                )
                paper.htmlURLString = candidate.1.absoluteString
                modelContext.insert(PaperAttachment(
                    paperID: paper.id,
                    kind: .html,
                    source: .arxivHTML,
                    filename: htmlURL.lastPathComponent,
                    filePath: htmlURL.path
                ))
                try? modelContext.save()
                return true
            } catch {
                continue
            }
        }

        return false
    }

    static func extractText(from document: PDFDocument?, maxPages: Int) -> String {
        guard let document else { return "" }
        let upperBound = min(document.pageCount, maxPages)
        guard upperBound > 0 else { return "" }
        return (0..<upperBound)
            .compactMap { document.page(at: $0)?.string }
            .joined(separator: "\n")
    }

    static func extractMetadataStrings(from attributes: [AnyHashable: Any]) -> [String] {
        attributes.values.flatMap { value in
            switch value {
            case let string as String:
                return [string]
            case let strings as [String]:
                return strings
            case let array as NSArray:
                return array.compactMap { $0 as? String }
            default:
                return []
            }
        }
    }

    static func extractArxivID(from text: String) -> ArxivIdentifier? {
        let explicitPatterns = [
            #"(?i)\barxiv\s*:?\s*(\d{4}\.\d{4,5}(?:v\d+)?|[a-zA-Z\-]+(?:\.[A-Z]{2})?/\d{7}(?:v\d+)?)\b"#,
            #"(?i)\bhttps?://(?:www\.)?(?:arxiv\.org|ar5iv\.labs\.arxiv\.org)/\S+"#
        ]

        for pattern in explicitPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
                continue
            }

            if match.numberOfRanges > 1,
               let range = Range(match.range(at: 1), in: text),
               let identifier = try? ArxivClient.normalizeIdentifier(String(text[range])) {
                return identifier
            }

            if let range = Range(match.range(at: 0), in: text) {
                let candidate = String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: "[](){}<>.,;\"'"))
                if let identifier = try? ArxivClient.normalizeIdentifier(candidate) {
                    return identifier
                }
            }
        }

        return nil
    }

    static func extractDOI(from text: String) -> String? {
        let normalized = text
            .replacingOccurrences(of: #"(10\.)\s+"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)(doi(?:\.org/|:))\s+"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"/\s+"#, with: "/", options: .regularExpression)

        let patterns = [
            #"(?i)\b(?:https?://(?:dx\.)?doi\.org/|doi:\s*)(10\.\d{4,9}/[-._;()/:A-Z0-9]+)\b"#,
            #"(?i)\b(10\.\d{4,9}/[-._;()/:A-Z0-9]+)\b"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)) else {
                continue
            }

            let captureIndex = match.numberOfRanges > 1 ? 1 : 0
            if let range = Range(match.range(at: captureIndex), in: normalized) {
                return String(normalized[range])
            }
        }

        return nil
    }
}
