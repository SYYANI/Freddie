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

    func importArxiv(_ rawValue: String, modelContext: ModelContext) async throws -> Paper {
        let identifier = try ArxivClient.normalizeIdentifier(rawValue)
        let existingPapers = try modelContext.fetch(FetchDescriptor<Paper>())
        if let existing = existingPapers.first(where: { $0.arxivID == identifier.baseID }) {
            return existing
        }

        let metadata = try await arxivClient.fetchMetadata(for: rawValue)
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

        await importArxivHTMLIfAvailable(for: paper, modelContext: modelContext)
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
        let arxiv = Self.extractArxivID(from: text)

        let title = [extractedTitle, url.deletingPathExtension().lastPathComponent]
            .compactMap { $0 }
            .first { !$0.isEmpty } ?? "Untitled PDF"
        let authors = extractedAuthor.map { [$0] } ?? []

        let paper = Paper(
            arxivID: arxiv?.baseID,
            arxivVersion: arxiv?.version,
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

    func importArxivHTMLIfAvailable(for paper: Paper, modelContext: ModelContext) async {
        guard let arxivID = paper.arxivID else { return }
        let outputURL: URL
        let resourcesDirectory: URL
        do {
            outputURL = try fileStore.directory(for: paper.id).appendingPathComponent("paper.html")
            resourcesDirectory = try fileStore.resourcesDirectory(for: paper)
        } catch {
            return
        }

        let candidates = [
            URL(string: "https://arxiv.org/html/\(arxivID)"),
            URL(string: "https://ar5iv.labs.arxiv.org/html/\(arxivID)")
        ].compactMap { $0 }

        for candidate in candidates {
            do {
                let htmlURL = try await htmlLocalizer.fetchAndLocalize(from: candidate, outputURL: outputURL, resourcesDirectory: resourcesDirectory)
                paper.htmlURLString = candidate.absoluteString
                modelContext.insert(PaperAttachment(
                    paperID: paper.id,
                    kind: .html,
                    source: .arxivHTML,
                    filename: htmlURL.lastPathComponent,
                    filePath: htmlURL.path
                ))
                try? modelContext.save()
                return
            } catch {
                continue
            }
        }
    }

    static func extractText(from document: PDFDocument?, maxPages: Int) -> String {
        guard let document else { return "" }
        let upperBound = min(document.pageCount, maxPages)
        guard upperBound > 0 else { return "" }
        return (0..<upperBound)
            .compactMap { document.page(at: $0)?.string }
            .joined(separator: "\n")
    }

    static func extractArxivID(from text: String) -> ArxivIdentifier? {
        let pattern = #"(?:arXiv:)?(\d{4}\.\d{4,5}(?:v\d+)?|[a-zA-Z\-]+(?:\.[A-Z]{2})?/\d{7}(?:v\d+)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return try? ArxivClient.normalizeIdentifier(String(text[range]))
    }
}
