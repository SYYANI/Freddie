import Foundation
import Readability
import SwiftSoup

struct HTMLLocalizer: @unchecked Sendable {
    private static let maxConcurrentResourceDownloads = 6
    private static let maxStylesheetDownloads = 16
    private static let maxCSSResourceDownloads = 24
    private static let maxImageDownloads = 96
    private static let maxSourceSetDownloads = 32
    private static let resourceRequestTimeout: TimeInterval = 8
    static let defaultResourceTimeBudget: Duration = .seconds(30)

    // Extracted articles use our reading surface, so their prose must use the
    // matching palette too. Keep source styles for code, formulas, and graphics.
    // Also inject this in the reader to repair saved HTML without moving nodes
    // referenced by note anchors.
    static let readableProseColorCSS = """
    body.rp-readability-body {
        color: var(--rp-reader-text, #1f1f1f) !important;
        background: transparent !important;
    }
    body.rp-readability-body .rp-readability-shell,
    body.rp-readability-body .rp-readability-shell :where(article, section, main, header, footer, aside, div, p, h1, h2, h3, h4, h5, h6, ul, ol, li, dl, dt, dd, blockquote, figure, figcaption, table, thead, tbody, tfoot, tr, th, td, span, strong, b, em, i, small, sup, sub):not(:where(pre *, code *, svg *, math *)) {
        color: inherit !important;
        text-shadow: none !important;
    }
    body.rp-readability-body .rp-readability-shell :where(article, section, main, header, footer, aside, div, p, h1, h2, h3, h4, h5, h6, ul, ol, li, dl, dt, dd, figure, figcaption, table, thead, tbody, tfoot, tr, th, td):not(:where(pre *, code *, svg *, math *, .rp-note-anchor-target, .rp-assistant-history-fallback)) {
        background-color: transparent !important;
    }
    body.rp-readability-body .rp-readability-header,
    body.rp-readability-body .rp-readability-content {
        color: var(--rp-reader-text, #1f1f1f) !important;
    }
    body.rp-readability-body .rp-readability-byline,
    body.rp-readability-body .rp-readability-excerpt {
        color: var(--rp-reader-muted, #5f6368) !important;
    }
    body.rp-readability-body .rp-readability-shell a:not(:where(pre *, code *, svg *, math *)) {
        color: var(--rp-reader-link, #335c85) !important;
    }
    body.rp-readability-body .rp-readability-shell .rp-translation-block {
        color: var(--rp-reader-translation, #1f4d3a) !important;
    }
    """

    // Readability owns the reading column. Source-site prose classes can otherwise
    // constrain only the original (e.g. a centered 640px paragraph), leaving its
    // translated sibling at full width. Share this with the reader to repair saved
    // documents as well, without changing the DOM used by note anchors.
    // A source cap on the root (mandoc.css: `html { max-width: 65em; }`) pins the
    // whole page to the left and confines the sidenote reserve, so lift it; the
    // shell already caps and centers the column.
    static let readableProseLayoutCSS = """
    html:has(> body.rp-readability-body) {
        max-width: none !important;
    }
    body.rp-readability-body :is(.rp-readability-header, .rp-readability-content) :is(p, h1, h2, h3, h4, h5, h6):not(svg *, math *) {
        width: 100% !important;
        min-width: 0 !important;
        max-width: 100% !important;
        margin-inline: 0 !important;
        padding-inline: 0 !important;
        box-sizing: border-box !important;
    }
    """

    let session: URLSession
    let fileManager: FileManager
    /// Wall-clock budget for downloading page resources. Once it runs out no new requests
    /// start; in-flight ones finish within `resourceRequestTimeout`.
    let resourceTimeBudget: Duration

    init(
        session: URLSession = .shared,
        fileManager: FileManager = .default,
        resourceTimeBudget: Duration = HTMLLocalizer.defaultResourceTimeBudget
    ) {
        self.session = session
        self.fileManager = fileManager
        self.resourceTimeBudget = resourceTimeBudget
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
        try removeArchiveReplayChromeResources(from: document, sourceURL: sourceURL)

        // One wall-clock budget covers every resource download, so a slow host (Wayback replay,
        // archive mirrors, throttled CDNs) degrades to online fallbacks instead of stalling
        // import. Downloads run in two waves split only by real dependencies; within a wave the
        // sliding window starts URLs in list order: layout CSS, article images, then decoration.
        let resourceDeadline = ContinuousClock.now + resourceTimeBudget

        var stylesheetTargets: [(element: Element, url: URL)] = []
        for link in try document.select("link[rel=stylesheet][href]").array() {
            let href = try link.attr("href")
            guard let resourceURL = resolve(href, relativeTo: sourceURL) else { continue }
            // If this stylesheet falls outside the localization budget or its download
            // fails, keep an absolute online fallback instead of a broken file-relative URL.
            try link.attr("href", resourceURL.absoluteString)
            stylesheetTargets.append((link, resourceURL))
        }

        var imageTargets: [(element: Element, url: URL)] = []
        for image in try document.select("img[src]").array() {
            let source = try image.attr("src")
            guard let resourceURL = resolve(source, relativeTo: sourceURL) else { continue }
            // Same online fallback as stylesheets for images outside the budget or failed downloads.
            try image.attr("src", resourceURL.absoluteString)
            imageTargets.append((image, resourceURL))
        }

        // Wave 1: stylesheets and article images do not depend on each other.
        let localizedStylesheets = Array(stylesheetTargets.prefix(Self.maxStylesheetDownloads))
        let stylesheetURLs = uniqueDownloadURLs(localizedStylesheets.map(\.url))
        let stylesheetURLSet = Set(stylesheetURLs)
        // Budget distinct images, so repeated avatars or spacers do not crowd out figures.
        let imageURLs = uniqueDownloadURLs(imageTargets.map(\.url))
            .filter { !stylesheetURLSet.contains($0) }
            .prefix(Self.maxImageDownloads)
        let firstWave = try await downloadResources(
            stylesheetURLs + imageURLs,
            deadline: resourceDeadline
        ) { url, data -> LocalizedResource? in
            if stylesheetURLSet.contains(url) {
                return .stylesheet(String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self))
            }
            return (try? writeResource(data, originalURL: url, resourcesDirectory: resourcesDirectory)).map { .file($0) }
        }
        let stylesheetTextByURL = firstWave.compactMapValues(\.stylesheetText)
        var localizedFilenames = firstWave.compactMapValues(\.filename)

        for target in imageTargets {
            guard let filename = localizedFilenames[normalizedDownloadURL(target.url)] else { continue }
            try target.element.attr("src", localizedReference(filename, for: target.url))
            try preferLocalizedImageSource(for: target.element)
        }

        // Wave 2: what is left to fetch depends on wave 1 — <source> candidates only for images
        // that stayed online (localized ones dropped their <source> nodes), and url(...) entries
        // only for stylesheets that arrived. The two sets are independent of each other.
        var sourceSetURLs: [URL] = []
        for source in try document.select("source[srcset]").array() {
            sourceSetURLs.append(contentsOf: srcsetCandidates(try source.attr("srcset"), baseURL: sourceURL).compactMap(\.url))
        }
        var nestedCSSResourceURLs: [URL] = []
        for target in localizedStylesheets {
            guard let css = stylesheetTextByURL[normalizedDownloadURL(target.url)] else { continue }
            nestedCSSResourceURLs.append(contentsOf: try cssURLReferences(in: css, baseURL: target.url).map(\.url))
        }
        let pendingSourceSetURLs = uniqueDownloadURLs(sourceSetURLs)
            .filter { localizedFilenames[$0] == nil }
            .prefix(Self.maxSourceSetDownloads)
        let pendingCSSResourceURLs = uniqueDownloadURLs(nestedCSSResourceURLs)
            .filter { localizedFilenames[$0] == nil }
            .prefix(Self.maxCSSResourceDownloads)
        let secondWave = try await downloadResourceFiles(
            Array(pendingSourceSetURLs) + Array(pendingCSSResourceURLs),
            into: resourcesDirectory,
            deadline: resourceDeadline
        )
        localizedFilenames.merge(secondWave) { existing, _ in existing }

        for element in try document.select("img[srcset], source[srcset]").array() {
            let srcset = try element.attr("srcset")
            try element.attr("srcset", rewriteSrcset(srcset, baseURL: sourceURL, localizedFilenames: localizedFilenames))
        }

        for target in localizedStylesheets {
            guard let css = stylesheetTextByURL[normalizedDownloadURL(target.url)] else { continue }
            do {
                let rewritten = try rewriteCSS(css, baseURL: target.url, localizedFilenames: localizedFilenames)
                let filename = try writeResource(Data(rewritten.utf8), originalURL: target.url, resourcesDirectory: resourcesDirectory, preferredExtension: "css")
                try target.element.tagName("style")
                try target.element.removeAttr("href")
                try target.element.removeAttr("rel")
                try setRawStyleContent("/* \(filename) */\n\(rewritten)", on: target.element)
            } catch {
                continue
            }
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
        let repairedPreformattedProse = try splitPreformattedProseBlocks(in: document)

        let readabilityInput = repairedPreformattedProse ? try document.outerHtml() : html
        guard let readableDocument = try makeReadableDocument(from: readabilityInput, sourceURL: sourceURL, fallback: document) else {
            return document
        }
        return readableDocument
    }

    func requiresBrowserRendering(_ html: String) -> Bool {
        guard let document = try? SwiftSoup.parse(html),
              let body = document.body() else {
            return false
        }

        let visibleText = ((try? body.text()) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let externalScriptCount = (try? document.select("script[src]").count) ?? 0
        return visibleText.count < 40 && externalScriptCount > 0
    }

    func shouldUseRenderedHTML(_ renderedHTML: String, insteadOf originalHTML: String) -> Bool {
        visibleBodyTextLength(in: renderedHTML) >= 40 &&
            visibleBodyTextLength(in: renderedHTML) > visibleBodyTextLength(in: originalHTML)
    }

    func hasMeaningfulHTMLContent(_ html: String) -> Bool {
        visibleBodyTextLength(in: html) >= 40 && !needsXPostParagraphRepair(html)
    }

    func rewriteCSS(_ css: String, baseURL: URL, localizedFilenames: [URL: String]) throws -> String {
        var rewritten = ""
        var cursor = css.startIndex
        for reference in try cssURLReferences(in: css, baseURL: baseURL) {
            let target = localizedFilenames[normalizedDownloadURL(reference.url)]
                .map { localizedReference($0, for: reference.url) } ?? reference.url.absoluteString
            rewritten += css[cursor..<reference.range.lowerBound]
            rewritten += "url('\(escapedCSSURL(target))')"
            cursor = reference.range.upperBound
        }
        rewritten += css[cursor...]
        return rewritten
    }

    private func rewriteSrcset(_ srcset: String, baseURL: URL, localizedFilenames: [URL: String]) -> String {
        srcsetCandidates(srcset, baseURL: baseURL).map { candidate in
            guard let url = candidate.url else { return candidate.raw }
            let target = localizedFilenames[normalizedDownloadURL(url)]
                .map { localizedReference($0, for: url) } ?? url.absoluteString
            return candidate.descriptor.map { "\(target) \($0)" } ?? target
        }.joined(separator: ", ")
    }

    // Content cleanup, not a speed workaround: the Wayback toolbar styles would otherwise be
    // inlined into the saved article. Download time is bounded by `resourceTimeBudget`.
    private func removeArchiveReplayChromeResources(from document: Document, sourceURL: URL) throws {
        let archiveHosts: Set<String> = ["web.archive.org", "web-static.archive.org"]
        guard let sourceHost = sourceURL.host?.lowercased(), archiveHosts.contains(sourceHost) else { return }

        for link in try document.select("link[rel=stylesheet][href]").array() {
            let href = try link.attr("href")
            guard let url = resolve(href, relativeTo: sourceURL),
                  let host = url.host?.lowercased(), archiveHosts.contains(host),
                  url.path.hasPrefix("/_static/") else {
                continue
            }
            try link.remove()
        }

        // Readability normally drops these nodes with the rest of the navigation chrome.
        // Remove them as a fallback for pages whose article extraction is intentionally skipped.
        try document.select("#wm-ipp-base, #wm-ipp-print").remove()
    }

    private func cssURLReferences(in css: String, baseURL: URL) throws -> [(range: Range<String.Index>, url: URL)] {
        let regex = try NSRegularExpression(pattern: #"url\(([^)]+)\)"#)
        return regex.matches(in: css, range: NSRange(css.startIndex..., in: css)).compactMap { match in
            guard let fullRange = Range(match.range(at: 0), in: css),
                  let valueRange = Range(match.range(at: 1), in: css),
                  let resourceURL = resolve(String(css[valueRange]), relativeTo: baseURL) else {
                return nil
            }
            return (fullRange, resourceURL)
        }
    }

    private func srcsetCandidates(_ srcset: String, baseURL: URL) -> [(raw: String, url: URL?, descriptor: String?)] {
        srcset.split(separator: ",").map { item in
            let raw = item.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = raw.split(separator: " ", maxSplits: 1).map(String.init)
            let url = parts.first.flatMap { resolve($0, relativeTo: baseURL) }
            return (raw, url, parts.count == 2 ? parts[1] : nil)
        }
    }

    private func localizedReference(_ filename: String, for url: URL) -> String {
        let fragment = url.fragment.map { "#\($0)" } ?? ""
        return "Resources/\(filename)\(fragment)"
    }

    private func uniqueDownloadURLs(_ urls: [URL]) -> [URL] {
        var seen: Set<URL> = []
        return urls.compactMap { url in
            let normalized = normalizedDownloadURL(url)
            return seen.insert(normalized).inserted ? normalized : nil
        }
    }

    private func normalizedDownloadURL(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.fragment != nil else {
            return url
        }
        components.fragment = nil
        return components.url ?? url
    }

    private func escapedCSSURL(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
    }

    private enum LocalizedResource: Sendable {
        case stylesheet(String)
        case file(String)

        var stylesheetText: String? {
            if case .stylesheet(let text) = self { text } else { nil }
        }

        var filename: String? {
            if case .file(let filename) = self { filename } else { nil }
        }
    }

    private struct ResourceDownloadResult: Sendable {
        let url: URL
        let data: Data?
    }

    private func downloadResourceFiles(
        _ urls: [URL],
        into resourcesDirectory: URL,
        deadline: ContinuousClock.Instant
    ) async throws -> [URL: String] {
        try await downloadResources(urls, deadline: deadline) { url, data in
            try? writeResource(data, originalURL: url, resourcesDirectory: resourcesDirectory)
        }
    }

    /// Downloads with a sliding window of `maxConcurrentResourceDownloads` requests and hands
    /// each payload to `handle` as soon as it arrives, so callers can write it out instead of
    /// buffering every resource. Failed downloads are omitted; cancellation propagates.
    /// No request starts after `deadline`; URLs not yet started are simply left out.
    private func downloadResources<Value: Sendable>(
        _ urls: [URL],
        deadline: ContinuousClock.Instant,
        handle: (URL, Data) -> Value?
    ) async throws -> [URL: Value] {
        let uniqueURLs = uniqueDownloadURLs(urls)
        guard !uniqueURLs.isEmpty else { return [:] }

        return try await withThrowingTaskGroup(of: ResourceDownloadResult.self) { group in
            var nextIndex = 0
            while nextIndex < min(Self.maxConcurrentResourceDownloads, uniqueURLs.count),
                  ContinuousClock.now < deadline {
                let url = uniqueURLs[nextIndex]
                group.addTask { try await fetchResource(url) }
                nextIndex += 1
            }

            var resolved: [URL: Value] = [:]
            while let result = try await group.next() {
                if let data = result.data, let value = handle(result.url, data) {
                    resolved[result.url] = value
                }
                if nextIndex < uniqueURLs.count, ContinuousClock.now < deadline {
                    try Task.checkCancellation()
                    let url = uniqueURLs[nextIndex]
                    group.addTask { try await fetchResource(url) }
                    nextIndex += 1
                }
            }
            return resolved
        }
    }

    private func fetchResource(_ url: URL) async throws -> ResourceDownloadResult {
        do {
            let data = try await downloadData(from: url, timeoutInterval: Self.resourceRequestTimeout)
            return ResourceDownloadResult(url: url, data: data)
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            return ResourceDownloadResult(url: url, data: nil)
        }
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
        try splitPreformattedProseBlocks(in: document)
    }

    @discardableResult
    private func splitPreformattedProseBlocks(in document: Document) throws -> Bool {
        var replacedElement = false
        for pre in try document.select("pre[data-readability-pre-type=markdown]").array() {
            replacedElement = try replaceWithProseParagraphsIfNeeded(
                pre,
                in: document,
                requireMultipleParagraphs: false,
                preserveInlineWrapper: false
            ) || replacedElement
        }

        // Some social pages, including X long posts, encode paragraph boundaries as blank
        // lines inside a white-space: pre-wrap element. The utility class stylesheet is an
        // external resource and may be unavailable offline, so preserve the semantics in the
        // localized DOM instead of relying on the source site's CSS.
        for element in try document.select(".whitespace-pre-wrap").array() {
            let hasNestedPreformattedElement = try element
                .select(".whitespace-pre-wrap")
                .array()
                .contains { $0 !== element }
            guard !hasNestedPreformattedElement else { continue }
            replacedElement = try replaceWithProseParagraphsIfNeeded(
                element,
                in: document,
                requireMultipleParagraphs: true,
                preserveInlineWrapper: true
            ) || replacedElement
        }
        return replacedElement
    }

    private func replaceWithProseParagraphsIfNeeded(
        _ element: Element,
        in document: Document,
        requireMultipleParagraphs: Bool,
        preserveInlineWrapper: Bool
    ) throws -> Bool {
        let paragraphs = markdownProseParagraphHTML(from: try whitespacePreservingInnerHTML(of: element))
        guard !paragraphs.isEmpty,
              !requireMultipleParagraphs || paragraphs.count > 1 else {
            return false
        }

        if preserveInlineWrapper,
           let parent = element.parent(),
           parent.tagName().lowercased() == "div",
           parent.hasClass("whitespace-pre-wrap") {
            try parent.addClass("rp-readability-prose-container")
            try parent.addClass("rp-readability-font-normal")
            if parent.hasClass("font-chirp") {
                try parent.addClass("rp-readability-font-chirp")
            }
        }

        for paragraphHTML in paragraphs {
            let paragraph = try document.createElement("p")
            try paragraph.addClass("rp-readability-prose-paragraph")
            if preserveInlineWrapper {
                let inlineWrapper = try document.createElement(element.tagName())
                for attribute in element.getAttributes() ?? Attributes() where attribute.getKey().lowercased() != "id" {
                    try inlineWrapper.attr(attribute.getKey(), attribute.getValue())
                }
                try inlineWrapper.html(paragraphHTML)
                try paragraph.appendChild(inlineWrapper)
            } else {
                try paragraph.html(paragraphHTML)
            }
            try element.before(paragraph.outerHtml())
        }
        try element.remove()
        return true
    }

    private func whitespacePreservingInnerHTML(of element: Element) throws -> String {
        try element.getChildNodes().map { node in
            if let textNode = node as? TextNode {
                return escapeHTML(textNode.getWholeText())
            }
            return try node.outerHtml()
        }.joined()
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
        /*
         * Zero specificity: a source theme that caps and centers its body
         * (`body { max-width: 650px; margin: 0 auto; }`) keeps its column instead
         * of being pinned to the left edge.
         */
        :where(body.rp-readability-body) { margin: 0; }
        body.rp-readability-body { padding: 32px 24px 56px; }
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
            margin: 0 0 0.8em 0 !important;
            white-space: normal !important;
        }
        .rp-readability-content .rp-readability-prose-container {
            font-size: inherit !important;
            line-height: inherit !important;
            white-space: normal !important;
        }
        .rp-readability-content .rp-readability-font-normal {
            font-weight: 400 !important;
        }
        .rp-readability-content .rp-readability-font-chirp {
            font-family: TwitterChirp, -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif !important;
        }
        .rp-readability-content p.rp-readability-prose-paragraph > .whitespace-pre-wrap {
            line-height: inherit !important;
            white-space: normal !important;
        }
        .rp-readability-content p.rp-readability-prose-paragraph a {
            color: #335c85;
            text-decoration: underline;
            text-underline-offset: 0.16em;
        }
        .rp-readability-content img, .rp-readability-content video, .rp-readability-content svg, .rp-readability-content math { max-width: 100%; }
        /*
         * Readability keeps source classes so that math, code, and article-specific
         * semantics survive localization. Some source sites use those classes to
         * absolutely position or transform every article block for scroll effects.
         * Once their scripts are removed, all of those blocks occupy the same visual
         * position. Restore normal document flow while leaving SVG/MathML internals
         * untouched.
         */
        body.rp-readability-body .rp-readability-content #readability-page-1 :not(svg, svg *, math, math *) {
            position: static !important;
            inset: auto !important;
            transform: none !important;
            translate: none !important;
            rotate: none !important;
            scale: none !important;
        }
        /* Keep list-generated markers anchored to their own list container. */
        body.rp-readability-body .rp-readability-content #readability-page-1 :is(ul, ol) {
            position: relative !important;
        }
        body.rp-readability-body .rp-readability-content #readability-page-1 :is(article, section, main, header, footer, aside, div) {
            height: auto !important;
            min-height: 0 !important;
            max-height: none !important;
            overflow: visible !important;
        }
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
        \(Self.readableProseLayoutCSS)
        \(Self.readableProseColorCSS)
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

    private func visibleBodyTextLength(in html: String) -> Int {
        guard let document = try? SwiftSoup.parse(html),
              let body = document.body() else {
            return 0
        }
        return ((try? body.text()) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .count
    }

    private func needsXPostParagraphRepair(_ html: String) -> Bool {
        guard let document = try? SwiftSoup.parse(html),
              (try? document.select(".rp-readability-content .whitespace-pre-wrap").count) ?? 0 > 0 else {
            return false
        }

        let sourceURLs = [
            try? document.select("link[rel=canonical][href]").first()?.attr("href"),
            try? document.select("meta[property=og:url][content]").first()?.attr("content"),
        ].compactMap { $0 }
        let isXStatusPage = sourceURLs.contains { value in
            guard let url = URL(string: value),
                  let host = url.host?.lowercased() else {
                return false
            }
            return (host == "x.com" || host == "www.x.com" || host == "twitter.com" || host == "www.twitter.com") &&
                url.path.contains("/status/")
        }
        guard isXStatusPage else { return false }

        let descriptions = [
            try? document.select("meta[name=description][content]").first()?.attr("content"),
            try? document.select("meta[property=og:description][content]").first()?.attr("content"),
        ].compactMap { $0 }
        let sourceHasParagraphBreaks = descriptions.contains { description in
            description.range(of: #"\r?\n[\t ]*\r?\n"#, options: .regularExpression) != nil
        }
        guard sourceHasParagraphBreaks else { return false }

        let proseParagraphCount = (try? document.select(
            ".rp-readability-content .rp-readability-prose-paragraph"
        ).count) ?? 0
        let hasWhitespacePreservingParagraphContainer = ((try? document.select(
            ".rp-readability-content div.whitespace-pre-wrap"
        ).array()) ?? []).contains { container in
            !container.hasClass("rp-readability-prose-container") &&
                container.children().array().contains {
                    $0.tagName().lowercased() == "p" && $0.hasClass("rp-readability-prose-paragraph")
                }
        }
        return proseParagraphCount == 0 || hasWhitespacePreservingParagraphContainer
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
            let existingMetaTags = head.children().array()
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

    private func downloadData(from url: URL, timeoutInterval: TimeInterval? = nil) async throws -> Data {
        var request = BrowserRequestHeaders.request(for: url, accept: .resource)
        if let timeoutInterval {
            request.timeoutInterval = timeoutInterval
        }
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
