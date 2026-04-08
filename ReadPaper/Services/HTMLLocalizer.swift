import Foundation
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
        let document = try SwiftSoup.parse(html, sourceURL.absoluteString)
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

    private func resolve(_ value: String, relativeTo baseURL: URL) -> URL? {
        let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix("data:") else { return nil }
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
