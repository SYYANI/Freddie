import Foundation
import Readability
import SwiftSoup

struct HTMLLocalizer: @unchecked Sendable {
    let session: URLSession
    let fileManager: FileManager

    init(session: URLSession = .shared, fileManager: FileManager = .default) {
        self.session = session
        self.fileManager = fileManager
    }

    func fetchAndLocalize(from sourceURL: URL, outputURL: URL, resourcesDirectory: URL) async throws -> URL {
        let request = BrowserRequestHeaders.request(for: sourceURL, accept: .document)
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return try await localize(htmlData: data, sourceURL: sourceURL, outputURL: outputURL, resourcesDirectory: resourcesDirectory)
    }

    func localize(htmlData: Data, sourceURL: URL, outputURL: URL, resourcesDirectory: URL) async throws -> URL {
        if !fileManager.fileExists(atPath: resourcesDirectory.path) {
            try fileManager.createDirectory(at: resourcesDirectory, withIntermediateDirectories: true)
        }

        let html = String(data: htmlData, encoding: .utf8) ?? String(decoding: htmlData, as: UTF8.self)
        let document = try makeDocumentForLocalization(html: html, sourceURL: sourceURL)
        try document.select("script[src]").remove()

        for link in try document.select("link[rel=stylesheet][href]").array() {
            let href = try link.attr("href")
            guard let resourceURL = resolve(href, relativeTo: sourceURL) else { continue }
            do {
                let css = try await downloadText(from: resourceURL)
                let rewritten = try await rewriteCSS(css, baseURL: resourceURL, resourcesDirectory: resourcesDirectory)
                let filename = try writeResource(Data(rewritten.utf8), originalURL: resourceURL, resourcesDirectory: resourcesDirectory, preferredExtension: "css")
                try link.tagName("style")
                try link.removeAttr("href")
                try link.removeAttr("rel")
                try setRawStyleContent("/* \(filename) */\n\(rewritten)", on: link)
            } catch {
                continue
            }
        }

        for image in try document.select("img[src]").array() {
            let source = try image.attr("src")
            guard let resourceURL = resolve(source, relativeTo: sourceURL) else { continue }
            do {
                let data = try await downloadData(from: resourceURL)
                let filename = try writeResource(data, originalURL: resourceURL, resourcesDirectory: resourcesDirectory)
                try image.attr("src", "Resources/\(filename)")
                try preferLocalizedImageSource(for: image)
            } catch {
                continue
            }
        }

        for source in try document.select("source[srcset]").array() {
            let srcset = try source.attr("srcset")
            let rewritten = try await rewriteSrcset(srcset, baseURL: sourceURL, resourcesDirectory: resourcesDirectory)
            try source.attr("srcset", rewritten)
        }

        try tuneEmbeddedMediaLoading(in: document)

        let output = try document.outerHtml()
        try output.write(to: outputURL, atomically: true, encoding: .utf8)
        return outputURL
    }

    func makeDocumentForLocalization(html: String, sourceURL: URL) throws -> Document {
        let document = try SwiftSoup.parse(html, sourceURL.absoluteString)
        try reconcileCharsetDeclaration(in: document)
        try absolutizeHyperlinks(in: document, baseURL: sourceURL)
        try document.select("base[href]").remove()

        guard let readableDocument = try makeReadableDocument(from: html, sourceURL: sourceURL, fallback: document) else {
            return document
        }
        return readableDocument
    }

    func rewriteCSS(_ css: String, baseURL: URL, resourcesDirectory: URL) async throws -> String {
        var rewritten = css
        let pattern = #"url\(([^)]+)\)"#
        let regex = try NSRegularExpression(pattern: pattern)
        let matches = regex.matches(in: css, range: NSRange(css.startIndex..., in: css)).reversed()

        for match in matches {
            guard let valueRange = Range(match.range(at: 1), in: css) else { continue }
            let rawValue = String(css[valueRange]).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            guard !rawValue.hasPrefix("data:"), let resourceURL = resolve(rawValue, relativeTo: baseURL) else { continue }
            do {
                let data = try await downloadData(from: resourceURL)
                let filename = try writeResource(data, originalURL: resourceURL, resourcesDirectory: resourcesDirectory)
                if let fullRange = Range(match.range(at: 0), in: rewritten) {
                    rewritten.replaceSubrange(fullRange, with: "url('Resources/\(filename)')")
                }
            } catch {
                continue
            }
        }
        return rewritten
    }

    private func rewriteSrcset(_ srcset: String, baseURL: URL, resourcesDirectory: URL) async throws -> String {
        var rewrittenItems: [String] = []
        for item in srcset.split(separator: ",") {
            let parts = item.split(separator: " ", maxSplits: 1).map(String.init)
            guard let first = parts.first, let resourceURL = resolve(first, relativeTo: baseURL) else {
                rewrittenItems.append(String(item))
                continue
            }
            do {
                let data = try await downloadData(from: resourceURL)
                let filename = try writeResource(data, originalURL: resourceURL, resourcesDirectory: resourcesDirectory)
                if parts.count == 2 {
                    rewrittenItems.append("Resources/\(filename) \(parts[1])")
                } else {
                    rewrittenItems.append("Resources/\(filename)")
                }
            } catch {
                rewrittenItems.append(String(item))
            }
        }
        return rewrittenItems.joined(separator: ", ")
    }

    private func makeReadableDocument(from html: String, sourceURL: URL, fallback document: Document) throws -> Document? {
        do {
            let readability = try Readability(
                html: html,
                baseURL: sourceURL,
                options: ReadabilityOptions(keepClasses: true)
            )
            let result = try readability.parse()
            guard try shouldUseReadabilityResult(result) else {
                return nil
            }
            try applyReadabilityResult(result, to: document)
            return document
        } catch {
            return nil
        }
    }

    private func shouldUseReadabilityResult(_ result: ReadabilityResult) throws -> Bool {
        let contentDocument = try SwiftSoup.parseBodyFragment(result.content)
        let visibleText = try contentDocument.text().trimmingCharacters(in: .whitespacesAndNewlines)
        return visibleText.count >= 40
    }

    private func applyReadabilityResult(_ result: ReadabilityResult, to document: Document) throws {
        try updateMetadata(from: result, in: document)
        try injectReadabilityStyles(into: document)
        try document.body()?.addClass("rp-readability-body")
        try document.body()?.html(renderReadableBody(for: result))
        try splitMarkdownProsePreBlocks(in: document)
    }

    private func splitMarkdownProsePreBlocks(in document: Document) throws {
        for pre in try document.select("pre[data-readability-pre-type=markdown]").array() {
            let paragraphs = markdownProseParagraphHTML(from: try pre.html())
            guard !paragraphs.isEmpty else { continue }

            for paragraphHTML in paragraphs {
                let paragraph = try document.createElement("p")
                try paragraph.addClass("rp-readability-prose-paragraph")
                try paragraph.html(paragraphHTML)
                try pre.before(paragraph.outerHtml())
            }
            try pre.remove()
        }
    }

    private func markdownProseParagraphHTML(from html: String) -> [String] {
        let normalized = html
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var paragraphs: [String] = []
        var currentLines: [String] = []

        func flushCurrentParagraph() {
            let paragraph = currentLines
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !paragraph.isEmpty {
                paragraphs.append(paragraph)
            }
            currentLines.removeAll(keepingCapacity: true)
        }

        for line in normalized.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                flushCurrentParagraph()
            } else {
                currentLines.append(line)
            }
        }
        flushCurrentParagraph()

        return paragraphs
    }

    private func updateMetadata(from result: ReadabilityResult, in document: Document) throws {
        if let html = try document.select("html").first() {
            if let lang = nonEmpty(result.lang) {
                try html.attr("lang", lang)
            }
            if let dir = nonEmpty(result.dir) {
                try html.attr("dir", dir)
            }
        }

        if let head = document.head() {
            let titleText = nonEmpty(result.title) ?? AppLocalization.localized("Paper")
            if let titleElement = try head.select("title").first() {
                try titleElement.text(titleText)
            } else {
                let titleElement = try document.createElement("title")
                try titleElement.text(titleText)
                try head.appendChild(titleElement)
            }
        }
    }

    private func injectReadabilityStyles(into document: Document) throws {
        let styleID = "rp-readability-style"
        if try document.getElementById(styleID) != nil {
            return
        }
        let style = try document.createElement("style")
        try style.attr("id", styleID)
        try setRawStyleContent("""
        body.rp-readability-body { margin: 0; padding: 32px 24px 56px; }
        .rp-readability-shell { max-width: 980px; margin: 0 auto; }
        .rp-readability-header {
            display: block;
            margin-bottom: 2rem;
            background: transparent;
            padding: 0;
            width: auto;
            box-sizing: border-box;
        }
        .rp-readability-title { margin: 0; font-size: 2rem; line-height: 1.25; }
        .rp-readability-byline, .rp-readability-excerpt { color: #5f6368; margin-top: 0.75rem; line-height: 1.5; }
        .rp-readability-content { color: #1f1f1f; font-size: 1rem; line-height: 1.65; }
        .rp-readability-content p.rp-readability-prose-paragraph {
            color: inherit !important;
            font-size: inherit !important;
            line-height: inherit !important;
            margin: 0 0 1.1em 0 !important;
        }
        .rp-readability-content p.rp-readability-prose-paragraph a {
            color: #335c85;
            text-decoration: underline;
            text-underline-offset: 0.16em;
        }
        .rp-readability-content img, .rp-readability-content video, .rp-readability-content svg, .rp-readability-content math { max-width: 100%; }
        .rp-readability-content .page,
        .rp-readability-content .available-content,
        .rp-readability-content .grid,
        .rp-readability-content [class~='pc-display-grid'] {
            display: block !important;
        }
        .rp-readability-content .available-content {
            padding: 0 !important;
        }
        .rp-readability-content .page > *,
        .rp-readability-content .available-content > *,
        .rp-readability-content .grid > *,
        .rp-readability-content [class~='pc-display-grid'] > * {
            width: 100% !important;
            max-width: 100% !important;
            grid-column: auto !important;
            box-sizing: border-box;
        }
        """, on: style)
        if let head = document.head() {
            try head.appendChild(style)
        }
    }

    private func setRawStyleContent(_ css: String, on style: Element) throws {
        style.empty()
        try style.appendChild(DataNode(Array(css.utf8), style.getBaseUriUTF8()))
    }

    private func tuneEmbeddedMediaLoading(in document: Document) throws {
        for image in try document.select("img[src]").array() {
            if (try? image.attr("loading")).flatMap(nonEmpty) == nil {
                try image.attr("loading", "lazy")
            }
            if (try? image.attr("decoding")).flatMap(nonEmpty) == nil {
                try image.attr("decoding", "async")
            }
        }

        // Imported reader pages should prioritize fast paper switching over eager media buffering.
        for media in try document.select("video, audio").array() {
            let preload = (try? media.attr("preload"))?.lowercased() ?? ""
            if preload != "none" {
                try media.attr("preload", "none")
            }
        }
    }

    private func preferLocalizedImageSource(for image: Element) throws {
        try image.removeAttr("srcset")
        try image.removeAttr("sizes")

        guard let picture = image.parent(), picture.tagName().lowercased() == "picture" else {
            return
        }
        try picture.select("source").remove()
    }

    private func renderReadableBody(for result: ReadabilityResult) -> String {
        var parts: [String] = [
            #"<main class="rp-readability-shell">"#
        ]

        if let title = nonEmpty(result.title) {
            parts.append(#"<div class="rp-readability-header">"#)
            parts.append(#"<h1 class="rp-readability-title">\#(escapeHTML(title))</h1>"#)
            if let byline = nonEmpty(result.byline) {
                parts.append(#"<p class="rp-readability-byline">\#(escapeHTML(byline))</p>"#)
            }
            if let excerpt = nonEmpty(result.excerpt),
               shouldRenderExcerpt(excerpt, contentHTML: result.content) {
                parts.append(#"<p class="rp-readability-excerpt">\#(escapeHTML(excerpt))</p>"#)
            }
            parts.append("</div>")
        }

        parts.append(#"<article class="rp-readability-content">\#(result.content)</article>"#)
        parts.append("</main>")
        return parts.joined()
    }

    private func shouldRenderExcerpt(_ excerpt: String, contentHTML: String) -> Bool {
        let normalizedExcerpt = normalizeVisibleText(excerpt)
        guard !normalizedExcerpt.isEmpty else {
            return false
        }
        let contentText = (try? SwiftSoup.parseBodyFragment(contentHTML).text()) ?? contentHTML
        let normalizedContent = normalizeVisibleText(contentText)
        return !normalizedContent.hasPrefix(normalizedExcerpt)
    }

    private func normalizeVisibleText(_ text: String) -> String {
        text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func reconcileCharsetDeclaration(in document: Document) throws {
        let knownEquivPatterns = [
            "content-type",
            "Content-Type",
        ]
        for meta in try document.select("meta[http-equiv]").array() {
            let equiv = (try? meta.attr("http-equiv")) ?? ""
            if knownEquivPatterns.contains(equiv) {
                try meta.remove()
            }
        }
        try document.select("meta[charset]").remove()

        if let head = document.head() {
            let charsetMeta = try document.createElement("meta")
            try charsetMeta.attr("charset", "UTF-8")
            let existingMetaTags = try head.children().array()
            if let firstMeta = existingMetaTags.first(where: { $0.tagName() == "meta" }) {
                try firstMeta.before(charsetMeta.outerHtml())
            } else if let firstChild = existingMetaTags.first {
                try firstChild.before(charsetMeta.outerHtml())
            }
        }
    }

    private func absolutizeHyperlinks(in document: Document, baseURL: URL) throws {
        for link in try document.select("a[href]").array() {
            let href = try link.attr("href")
            guard let resolvedURL = resolve(href, relativeTo: baseURL) else { continue }
            try link.attr("href", resolvedURL.absoluteString)
        }
    }

    private func resolve(_ value: String, relativeTo baseURL: URL) -> URL? {
        let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
        let lowercased = trimmed.lowercased()
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("#"),
              !lowercased.hasPrefix("data:"),
              !lowercased.hasPrefix("javascript:") else { return nil }
        return URL(string: trimmed, relativeTo: baseURL)?.absoluteURL
    }

    private func downloadText(from url: URL) async throws -> String {
        let data = try await downloadData(from: url)
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    private func downloadData(from url: URL) async throws -> Data {
        let request = BrowserRequestHeaders.request(for: url, accept: .resource)
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    @discardableResult
    private func writeResource(_ data: Data, originalURL: URL, resourcesDirectory: URL, preferredExtension: String? = nil) throws -> String {
        let originalExtension = originalURL.pathExtension
        let fileExtension = preferredExtension ?? (originalExtension.isEmpty ? "bin" : originalExtension)
        let filename = "\(Hashing.sha256Hex(originalURL.absoluteString).prefix(16)).\(fileExtension)"
        let target = resourcesDirectory.appendingPathComponent(filename)
        if !fileManager.fileExists(atPath: target.path) {
            try data.write(to: target, options: .atomic)
        }
        return filename
    }
}

enum BrowserRequestHeaders {
    static let chromeUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    static let englishAcceptLanguage = "en-US,en;q=0.9"

    enum Accept {
        case document
        case resource

        fileprivate var value: String {
            switch self {
            case .document:
                "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
            case .resource:
                "*/*"
            }
        }
    }

    static func request(for url: URL, accept: Accept) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(chromeUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(englishAcceptLanguage, forHTTPHeaderField: "Accept-Language")
        request.setValue(accept.value, forHTTPHeaderField: "Accept")
        if case .document = accept {
            request.setValue("max-age=0", forHTTPHeaderField: "Cache-Control")
            request.setValue("document", forHTTPHeaderField: "Sec-Fetch-Dest")
            request.setValue("navigate", forHTTPHeaderField: "Sec-Fetch-Mode")
            request.setValue("none", forHTTPHeaderField: "Sec-Fetch-Site")
            request.setValue("?1", forHTTPHeaderField: "Sec-Fetch-User")
            request.setValue("1", forHTTPHeaderField: "Upgrade-Insecure-Requests")
        }
        return request
    }
}
