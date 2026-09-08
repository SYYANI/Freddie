import Foundation
import PDFKit
import SwiftData
import SwiftSoup
import WebKit

@MainActor
final class PaperImporter {
    private let fileStore: PaperFileStore
    private let arxivClient: ArxivClient
    private let htmlLocalizer: HTMLLocalizer
    private let webPageHTMLRenderer: any WebPageHTMLRendering
    private let session: URLSession
    private let fullTextSearchService: PaperFullTextSearchService

    init(
        fileStore: PaperFileStore = PaperFileStore(),
        arxivClient: ArxivClient = .shared,
        htmlLocalizer: HTMLLocalizer = HTMLLocalizer(),
        webPageHTMLRenderer: any WebPageHTMLRendering = WebKitWebPageHTMLRenderer(),
        session: URLSession = .shared,
        fullTextSearchService: PaperFullTextSearchService? = nil
    ) {
        self.fileStore = fileStore
        self.arxivClient = arxivClient
        self.htmlLocalizer = htmlLocalizer
        self.webPageHTMLRenderer = webPageHTMLRenderer
        self.session = session
        self.fullTextSearchService = fullTextSearchService
            ?? PaperFullTextSearchService(fileStore: fileStore)
    }

    func importArxiv(
        _ rawValue: String,
        modelContext: ModelContext,
        includeHTML: Bool = false,
        onProgress: ((ArxivImportProgress) -> Void)? = nil
    ) async throws -> Paper {
        onProgress?(.resolvingInput(includesHTML: includeHTML))
        let identifier = try ArxivClient.normalizeIdentifier(rawValue)
        onProgress?(.resolvingInput(identifier: identifier.queryID, includesHTML: includeHTML))
        let existingPapers = try modelContext.fetch(FetchDescriptor<Paper>())
        if let existing = existingPapers.first(where: { $0.arxivID == identifier.baseID }) {
            return existing
        }

        onProgress?(.fetchingMetadata(for: identifier.queryID, includesHTML: includeHTML))
        let metadata = try await arxivClient.fetchMetadata(for: rawValue)
        onProgress?(.creatingLibraryEntry(
            title: metadata.title.isEmpty ? metadata.arxivID : metadata.title,
            includesHTML: includeHTML
        ))
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
            onProgress?(.downloadingPDF(for: metadata.arxivID, includesHTML: includeHTML))
            let request = BrowserRequestHeaders.request(for: pdfURL, accept: .resource)
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw PaperImportError.arxivHTTPError(statusCode: http.statusCode)
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

        let htmlImported: Bool
        if includeHTML {
            htmlImported = await importArxivHTMLIfAvailable(
                for: paper,
                modelContext: modelContext,
                onProgress: onProgress
            )
        } else {
            htmlImported = false
        }
        onProgress?(.finalizing(htmlImported: htmlImported, includesHTML: includeHTML))
        try modelContext.save()
        AuthorExtractionService.extractAuthorsIfNeeded(for: paper, modelContext: modelContext)
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
        AuthorExtractionService.extractAuthorsIfNeeded(for: paper, modelContext: modelContext)
        return paper
    }

    func importWebPage(
        _ rawValue: String,
        modelContext: ModelContext,
        onProgress: ((WebPageImportProgress) -> Void)? = nil
    ) async throws -> Paper {
        onProgress?(.validatingURL())
        let sourceURL = try Self.normalizeWebPageURL(rawValue)
        onProgress?(.validatingURL(urlString: sourceURL.absoluteString))

        let existingPapers = try modelContext.fetch(FetchDescriptor<Paper>())
        let existing = existingPapers.first(where: { $0.htmlURLString == sourceURL.absoluteString })
        if let existing, try hasUsableWebImport(for: existing, modelContext: modelContext) {
            return existing
        }

        let isNewPaper = existing == nil
        let paper = existing ?? Paper(
            title: Self.fallbackWebPageTitle(for: sourceURL),
            htmlURLString: sourceURL.absoluteString
        )
        paper.localDirectoryPath = try fileStore.directory(for: paper.id).path

        do {
            onProgress?(.fetchingHTML(from: sourceURL))
            let request = BrowserRequestHeaders.request(for: sourceURL, accept: .document)
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw PaperImportError.webPageHTTPError(statusCode: http.statusCode)
            }

            if (response as? HTTPURLResponse)?.mimeType?.lowercased() == "application/pdf" {
                return try await importWebPagePDF(
                    data: data,
                    sourceURL: sourceURL,
                    paper: paper,
                    insertPaper: isNewPaper,
                    modelContext: modelContext,
                    onProgress: onProgress
                )
            }

            var htmlData = data
            let originalHTML = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            if htmlLocalizer.requiresBrowserRendering(originalHTML) {
                let renderedHTML = try await webPageHTMLRenderer.renderHTML(for: request)
                guard htmlLocalizer.shouldUseRenderedHTML(renderedHTML, insteadOf: originalHTML) else {
                    throw URLError(.cannotDecodeContentData)
                }
                htmlData = Data(renderedHTML.utf8)
            }

            let outputURL = try fileStore.directory(for: paper.id).appendingPathComponent("paper.html")
            let resourcesDirectory = try fileStore.resourcesDirectory(for: paper)

            let htmlURL = try await htmlLocalizer.localize(
                htmlData: htmlData,
                sourceURL: sourceURL,
                outputURL: outputURL,
                resourcesDirectory: resourcesDirectory
            )
            paper.title = Self.extractHTMLTitle(from: htmlURL) ?? paper.title
            onProgress?(.creatingLibraryEntry(title: paper.title))

            if isNewPaper {
                modelContext.insert(paper)
            }
            let htmlAttachment = try upsertWebPageAttachment(
                for: paper,
                kind: .html,
                fileURL: htmlURL,
                modelContext: modelContext
            )
            _ = try? fullTextSearchService.rebuild(
                paper: paper,
                attachments: [htmlAttachment]
            )

            onProgress?(.finalizing())
            paper.modifiedAt = Date()
            try modelContext.save()
            AuthorExtractionService.extractAuthorsIfNeeded(for: paper, modelContext: modelContext)
            return paper
        } catch {
            if isNewPaper {
                try? fileStore.removeDirectory(for: paper.id)
            }
            throw error
        }
    }

    private func importWebPagePDF(
        data: Data,
        sourceURL: URL,
        paper: Paper,
        insertPaper: Bool,
        modelContext: ModelContext,
        onProgress: ((WebPageImportProgress) -> Void)?
    ) async throws -> Paper {
        onProgress?(.downloadingPDF(from: sourceURL))

        let pdfFile = try fileStore.write(data, named: "paper.pdf", for: paper.id)
        paper.pdfURLString = sourceURL.absoluteString

        if let pdfDocument = PDFDocument(data: data) {
            let attributes = pdfDocument.documentAttributes ?? [:]
            let extractedTitle = (attributes[PDFDocumentAttribute.titleAttribute] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let extractedAuthor = (attributes[PDFDocumentAttribute.authorAttribute] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = Self.extractText(from: pdfDocument, maxPages: 3)
            let searchableText = ([text] + Self.extractMetadataStrings(from: attributes))
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            let arxiv = Self.extractArxivID(from: searchableText)
            let doi = Self.extractDOI(from: searchableText)

            if let title = extractedTitle, !title.isEmpty {
                paper.title = title
            }
            paper.arxivID = arxiv?.baseID
            paper.arxivVersion = arxiv?.version
            paper.doi = doi
            if let author = extractedAuthor {
                paper.authors = [author]
            }
        }

        onProgress?(.creatingLibraryEntry(title: paper.title))

        if insertPaper {
            modelContext.insert(paper)
        }
        _ = try upsertWebPageAttachment(
            for: paper,
            kind: .pdf,
            fileURL: pdfFile,
            modelContext: modelContext
        )

        onProgress?(.finalizing())
        paper.modifiedAt = Date()
        try modelContext.save()
        AuthorExtractionService.extractAuthorsIfNeeded(for: paper, modelContext: modelContext)
        return paper
    }

    private func hasUsableWebImport(for paper: Paper, modelContext: ModelContext) throws -> Bool {
        let attachments = try modelContext.fetch(FetchDescriptor<PaperAttachment>())
            .filter { $0.paperID == paper.id && $0.source == .webPage }

        for attachment in attachments {
            let fileURL = attachment.resolvedFileURL(fileStore: fileStore)
            guard fileStore.fileManager.fileExists(atPath: fileURL.path) else { continue }

            switch attachment.kind {
            case .html:
                guard let html = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
                if htmlLocalizer.hasMeaningfulHTMLContent(html) {
                    return true
                }
            case .pdf:
                if let attributes = try? fileStore.fileManager.attributesOfItem(atPath: fileURL.path),
                   let size = attributes[.size] as? NSNumber,
                   size.intValue > 0 {
                    return true
                }
            default:
                continue
            }
        }

        return false
    }

    private func upsertWebPageAttachment(
        for paper: Paper,
        kind: AttachmentKind,
        fileURL: URL,
        modelContext: ModelContext
    ) throws -> PaperAttachment {
        let attachments = try modelContext.fetch(FetchDescriptor<PaperAttachment>())
        if let attachment = attachments.first(where: {
            $0.paperID == paper.id && $0.source == .webPage && $0.kind == kind
        }) {
            attachment.filename = fileURL.lastPathComponent
            attachment.filePath = fileURL.path
            return attachment
        } else {
            let attachment = PaperAttachment(
                paperID: paper.id,
                kind: kind,
                source: .webPage,
                filename: fileURL.lastPathComponent,
                filePath: fileURL.path
            )
            modelContext.insert(attachment)
            return attachment
        }
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
                let htmlAttachment = PaperAttachment(
                    paperID: paper.id,
                    kind: .html,
                    source: .arxivHTML,
                    filename: htmlURL.lastPathComponent,
                    filePath: htmlURL.path
                )
                modelContext.insert(htmlAttachment)
                _ = try? fullTextSearchService.rebuild(
                    paper: paper,
                    attachments: [htmlAttachment]
                )
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

    static func normalizeWebPageURL(_ rawValue: String) throws -> URL {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw PaperImportError.invalidWebPageURL
        }

        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard var components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              components.host?.isEmpty == false else {
            throw PaperImportError.invalidWebPageURL
        }

        guard ["http", "https"].contains(scheme) else {
            throw PaperImportError.unsupportedWebPageURLScheme
        }

        components.scheme = scheme
        components.fragment = nil
        guard let url = components.url else {
            throw PaperImportError.invalidWebPageURL
        }
        return url
    }

    static func fallbackWebPageTitle(for url: URL) -> String {
        let pathTitle = url
            .deletingPathExtension()
            .lastPathComponent
            .removingPercentEncoding?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let pathTitle, !pathTitle.isEmpty, pathTitle != "/" {
            return pathTitle.replacingOccurrences(of: "-", with: " ")
        }

        if let host = url.host, !host.isEmpty {
            return host
        }

        return AppLocalization.localized("Untitled Web Page")
    }

    static func extractHTMLTitle(from htmlURL: URL) -> String? {
        guard let html = try? String(contentsOf: htmlURL, encoding: .utf8),
              let document = try? SwiftSoup.parse(html) else {
            return nil
        }
        guard let titleElement = try? document.select("title").first(),
              let title = try? titleElement.text().trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            return nil
        }
        return title
    }
}

@MainActor
protocol WebPageHTMLRendering: AnyObject {
    func renderHTML(for request: URLRequest) async throws -> String
}

@MainActor
final class WebKitWebPageHTMLRenderer: NSObject, WebPageHTMLRendering, WKNavigationDelegate {
    private let timeout: TimeInterval
    private var continuation: CheckedContinuation<String, Error>?
    private var webView: WKWebView?
    private var timeoutWorkItem: DispatchWorkItem?
    private var isCapturingDOM = false

    init(timeout: TimeInterval = 20) {
        self.timeout = timeout
    }

    func renderHTML(for request: URLRequest) async throws -> String {
        guard continuation == nil else {
            throw URLError(.cannotLoadFromNetwork)
        }
        try Task.checkCancellation()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation

                let configuration = WKWebViewConfiguration()
                configuration.websiteDataStore = .nonPersistent()
                configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
                configuration.mediaTypesRequiringUserActionForPlayback = .all

                let webView = WKWebView(frame: .zero, configuration: configuration)
                webView.navigationDelegate = self
                webView.customUserAgent = BrowserRequestHeaders.chromeUserAgent
                self.webView = webView

                let timeoutWorkItem = DispatchWorkItem { [weak self] in
                    self?.finish(with: .failure(URLError(.timedOut)))
                }
                self.timeoutWorkItem = timeoutWorkItem
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + timeout,
                    execute: timeoutWorkItem
                )

                webView.load(request)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(with: .failure(CancellationError()))
            }
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        captureDOM(from: webView)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        captureDOM(from: webView)
    }

    private func captureDOM(from webView: WKWebView) {
        guard !isCapturingDOM else { return }
        isCapturingDOM = true

        let script = """
        new Promise(resolve => {
            const startedAt = Date.now();
            let lastHTML = '';
            let stableSince = Date.now();

            const sample = () => {
                const html = document.documentElement?.outerHTML || '';
                if (html !== lastHTML) {
                    lastHTML = html;
                    stableSince = Date.now();
                }
                const textLength = (document.body?.innerText || '').trim().length;
                if ((textLength >= 40 && Date.now() - stableSince >= 300) || Date.now() - startedAt >= 10000) {
                    resolve(html);
                    return;
                }
                setTimeout(sample, 100);
            };

            requestAnimationFrame(() => requestAnimationFrame(sample));
        });
        """

        webView.evaluateJavaScript(script) { [weak self, weak webView] value, error in
            Task { @MainActor in
                guard let self, let webView else { return }
                self.isCapturingDOM = false
                if error != nil {
                    self.captureCurrentDOM(from: webView)
                } else if let html = value as? String, !html.isEmpty {
                    self.finish(with: .success(html))
                } else {
                    self.finish(with: .failure(URLError(.cannotDecodeContentData)))
                }
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        captureCurrentDOM(from: webView)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        captureCurrentDOM(from: webView)
    }

    private func captureCurrentDOM(from webView: WKWebView) {
        let script = """
        (() => {
            const textLength = (document.body?.innerText || '').trim().length;
            return textLength >= 40 ? (document.documentElement?.outerHTML || '') : null;
        })();
        """
        webView.evaluateJavaScript(script) { [weak self] value, _ in
            Task { @MainActor in
                guard let self else { return }
                if let html = value as? String, !html.isEmpty {
                    self.finish(with: .success(html))
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self, weak webView] in
                        guard let self, let webView, self.continuation != nil else { return }
                        self.captureDOM(from: webView)
                    }
                }
            }
        }
    }

    private func finish(with result: Result<String, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        isCapturingDOM = false
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        webView = nil
        continuation.resume(with: result)
    }
}
