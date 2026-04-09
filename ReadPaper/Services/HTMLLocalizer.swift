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
        let (data, response) = try await session.data(from: sourceURL)
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
                try link.html("/* \(filename) */\n\(rewritten)")
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
            } catch {
                continue
            }
        }

        for source in try document.select("source[srcset]").array() {
            let srcset = try source.attr("srcset")
            let rewritten = try await rewriteSrcset(srcset, baseURL: sourceURL, resourcesDirectory: resourcesDirectory)
            try source.attr("srcset", rewritten)
        }

        let output = try document.outerHtml()
        try output.write(to: outputURL, atomically: true, encoding: .utf8)
        return outputURL
    }

    func makeDocumentForLocalization(html: String, sourceURL: URL) throws -> Document {
        let document = try SwiftSoup.parse(html, sourceURL.absoluteString)
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
            try applyReadabilityResult(result, to: document)
            return document
        } catch {
            return nil
        }
    }

    private func applyReadabilityResult(_ result: ReadabilityResult, to document: Document) throws {
        try updateMetadata(from: result, in: document)
        try injectReadabilityStyles(into: document)
        try document.body()?.addClass("rp-readability-body")
        try document.body()?.html(renderReadableBody(for: result))
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
            let titleText = nonEmpty(result.title) ?? "Paper"
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
        try style.html("""
        body.rp-readability-body { margin: 0; padding: 32px 24px 56px; }
        .rp-readability-shell { max-width: 980px; margin: 0 auto; }
        .rp-readability-header { margin-bottom: 2rem; }
        .rp-readability-title { margin: 0; font-size: 2rem; line-height: 1.25; }
        .rp-readability-byline, .rp-readability-excerpt { color: #5f6368; margin-top: 0.75rem; }
        .rp-readability-content img, .rp-readability-content video, .rp-readability-content svg, .rp-readability-content math { max-width: 100%; }
        """)
        if let head = document.head() {
            try head.appendChild(style)
        }
    }

    private func renderReadableBody(for result: ReadabilityResult) -> String {
        var parts: [String] = [
            #"<main class="rp-readability-shell">"#
        ]

        if let title = nonEmpty(result.title) {
            parts.append(#"<header class="rp-readability-header">"#)
            parts.append(#"<h1 class="rp-readability-title">\#(escapeHTML(title))</h1>"#)
            if let byline = nonEmpty(result.byline) {
                parts.append(#"<p class="rp-readability-byline">\#(escapeHTML(byline))</p>"#)
            }
            if let excerpt = nonEmpty(result.excerpt) {
                parts.append(#"<p class="rp-readability-excerpt">\#(escapeHTML(excerpt))</p>"#)
            }
            parts.append("</header>")
        }

        parts.append(#"<article class="rp-readability-content">\#(result.content)</article>"#)
        parts.append("</main>")
        return parts.joined()
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
        let (data, response) = try await session.data(from: url)
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
