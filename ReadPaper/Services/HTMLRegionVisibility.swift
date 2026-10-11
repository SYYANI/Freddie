import Foundation
import SwiftSoup

/// One region edit on an imported page: hide or restore the element at `path`.
///
/// `path` uses the `rp-anchor:` format shared with note anchors. `signature` records the
/// element's shape, so a path that resolves to a different element in the saved file (the
/// reader DOM drifted from it) is rejected instead of hiding the wrong content.
struct HTMLRegionChange: Codable, Hashable, Sendable {
    var path: String
    var signature: String
    var isHidden: Bool
}

struct HTMLRegionVisibilityUpdate: Sendable {
    var html: String
    var didChange: Bool
    var hiddenRegionCount: Int
    var unmatchedChanges: [HTMLRegionChange]
}

/// Lets readers hide leftovers Readability kept on an imported page (navigation, share
/// bars, newsletter boxes). Regions are only marked, never removed, so element indices —
/// and with them `rp-anchor:` note anchors — stay valid and every edit can be undone.
enum HTMLRegionVisibility {
    static let hiddenAttribute = "data-rp-region-hidden"
    /// Set on `<html>` by the reader while regions are being edited.
    static let editingAttribute = "data-rp-region-edit"
    static let styleElementID = "rp-region-visibility-style"

    /// Hides marked regions together with the translation block that follows a hidden
    /// source; while editing, the reader shows them faded instead. `:not(#…)` only raises
    /// specificity, so source-site `display: … !important` rules cannot reveal a region.
    static let hiddenRegionCSS = """
    html:not([\(editingAttribute)='true']):not(#rp-region-visibility) [\(hiddenAttribute)='true'],
    html:not([\(editingAttribute)='true']):not(#rp-region-visibility) [\(hiddenAttribute)='true'] + .rp-translation-block {
        display: none !important;
    }
    """

    static func isHidden(_ element: Element) -> Bool {
        (try? element.attr(hiddenAttribute)) == "true"
    }

    /// Whether the element or one of its ancestors was hidden by the reader.
    static func isWithinHiddenRegion(_ element: Element) -> Bool {
        var current: Element? = element
        while let candidate = current {
            if isHidden(candidate) { return true }
            current = candidate.parent()
        }
        return false
    }

    /// Drops hidden descendants from a detached copy before its text is read.
    static func removeHiddenRegions(in element: Element) throws {
        for hidden in try element.select("[\(hiddenAttribute)=true]").array() where hidden !== element {
            try hidden.remove()
        }
    }

    static func applying(_ changes: [HTMLRegionChange], toHTML html: String) throws -> HTMLRegionVisibilityUpdate {
        let document = try SwiftSoup.parse(html)
        // Keep the saved file byte-for-byte except for the edited attributes.
        document.outputSettings().prettyPrint(pretty: false)
        var didChange = false
        var unmatchedChanges: [HTMLRegionChange] = []
        for change in changes {
            guard let element = HTMLAnchorPath.element(at: change.path, in: document),
                  HTMLAnchorPath.signature(of: element) == change.signature else {
                unmatchedChanges.append(change)
                continue
            }
            if change.isHidden, !isHidden(element) {
                try element.attr(hiddenAttribute, "true")
                didChange = true
            } else if !change.isHidden, element.hasAttr(hiddenAttribute) {
                try element.removeAttr(hiddenAttribute)
                didChange = true
            }
        }

        let hiddenRegionCount = try document.select("[\(hiddenAttribute)=true]").count
        if try synchronizeStyle(in: document, hasHiddenRegions: hiddenRegionCount > 0) {
            didChange = true
        }
        guard didChange else {
            return HTMLRegionVisibilityUpdate(
                html: html,
                didChange: false,
                hiddenRegionCount: hiddenRegionCount,
                unmatchedChanges: unmatchedChanges
            )
        }
        try ensureUTF8CharsetDeclaration(in: document)
        return HTMLRegionVisibilityUpdate(
            html: try document.outerHtml(),
            didChange: true,
            hiddenRegionCount: hiddenRegionCount,
            unmatchedChanges: unmatchedChanges
        )
    }

    /// Parses and rewrites the whole page, so callers on the main actor go through `HTMLRegionWriter`.
    @discardableResult
    static func apply(_ changes: [HTMLRegionChange], toFileAt url: URL) throws -> HTMLRegionVisibilityUpdate {
        let html = try String(contentsOf: url, encoding: .utf8)
        let update = try applying(changes, toHTML: html)
        if update.didChange {
            try update.html.write(to: url, atomically: true, encoding: .utf8)
        }
        return update
    }

    /// Persists the hiding rule with the document, so exports and other readers of
    /// `paper.html` honor hidden regions without the reader's scripts.
    private static func synchronizeStyle(in document: Document, hasHiddenRegions: Bool) throws -> Bool {
        let existing = try document.getElementById(styleElementID)
        guard hasHiddenRegions else {
            guard let existing else { return false }
            try existing.remove()
            return true
        }
        if let existing {
            guard existing.data() != hiddenRegionCSS else { return false }
            existing.empty()
            try existing.appendChild(DataNode(Array(hiddenRegionCSS.utf8), existing.getBaseUriUTF8()))
            return true
        }
        guard let head = document.head() else { return false }
        let style = try document.createElement("style")
        try style.attr("id", styleElementID)
        try style.appendChild(DataNode(Array(hiddenRegionCSS.utf8), style.getBaseUriUTF8()))
        try head.appendChild(style)
        return true
    }

    /// Rewritten `paper.html` must declare UTF-8; see `HTMLLocalizer.reconcileCharsetDeclaration`.
    private static func ensureUTF8CharsetDeclaration(in document: Document) throws {
        guard let head = document.head() else { return }
        let charsetDeclarations = try head.select("meta[charset]").array()
        let declaresUTF8 = charsetDeclarations.contains {
            (try? $0.attr("charset"))?.lowercased() == "utf-8"
        }
        guard !declaresUTF8 else { return }
        let contentTypeDeclarations = try head.select("meta[http-equiv]").array().filter {
            (try? $0.attr("http-equiv"))?.lowercased() == "content-type"
        }
        for declaration in charsetDeclarations + contentTypeDeclarations {
            try declaration.remove()
        }
        let declaration = try document.createElement("meta")
        try declaration.attr("charset", "UTF-8")
        try head.prependChild(declaration)
    }
}

/// Writes region edits to `paper.html` off the main actor, in the order they were made.
///
/// Each write parses and rewrites the whole page, which takes tens of milliseconds on a large
/// page (several times that in Debug builds). Writes run one at a time, so a later edit is never
/// overwritten by an earlier one.
@MainActor
final class HTMLRegionWriter {
    static let shared = HTMLRegionWriter()

    private struct Write {
        let id = UUID()
        var changes: [HTMLRegionChange]
        var fileURL: URL
    }

    /// Writes whose turn has not come yet.
    private var queued: [Write] = []
    private var lastWrite: Task<Void, Never>?
    /// Entered while a write runs in the background, so termination can wait for it.
    private let writing = DispatchGroup()

    /// Queues a write behind the earlier ones; `completion` receives its outcome.
    func write(
        _ changes: [HTMLRegionChange],
        toFileAt fileURL: URL,
        completion: @escaping @MainActor (Result<HTMLRegionVisibilityUpdate, any Error>) -> Void
    ) {
        let write = Write(changes: changes, fileURL: fileURL)
        queued.append(write)
        let previous = lastWrite
        lastWrite = Task { @MainActor in
            await previous?.value
            // `finishBeforeTermination` may have written it already.
            guard let index = queued.firstIndex(where: { $0.id == write.id }) else { return }
            queued.remove(at: index)
            let writing = writing
            writing.enter()
            let result = await Task.detached(priority: .userInitiated) {
                defer { writing.leave() }
                return Result { try HTMLRegionVisibility.apply(write.changes, toFileAt: write.fileURL) }
            }.value
            completion(result)
        }
    }

    /// Returns once the writes queued so far are on disk, e.g. before the page is read or rewritten.
    func waitForQueuedWrites() async {
        await lastWrite?.value
    }

    /// The app is about to exit and cannot wait for tasks: finish the running write, then the rest here.
    func finishBeforeTermination() {
        let remaining = queued
        queued = []
        _ = writing.wait(timeout: .now() + 10)
        for write in remaining {
            _ = try? HTMLRegionVisibility.apply(write.changes, toFileAt: write.fileURL)
        }
    }
}

/// Swift mirror of the reader's `rp-anchor:` paths: element indices from `<body>` that skip
/// translation blocks and typeset TeX, which exist only in the reader. Must stay in sync with
/// `buildOriginalPathAnchor` in `HTMLReaderView.Coordinator.instrumentationScript`.
enum HTMLAnchorPath {
    static let prefix = "rp-anchor:"
    private static let signatureChildLimit = 16

    static func anchorChildren(of element: Element) -> [Element] {
        element.children().array().filter { child in
            !child.hasClass("rp-translation-block") &&
                (try? child.attr("data-rp-translation")) != "true" &&
                !child.hasClass(HTMLTeXRendering.wrapperClass)
        }
    }

    static func element(at path: String, in document: Document) -> Element? {
        guard path.hasPrefix(prefix), var current = document.body() else { return nil }
        let indices = path.dropFirst(prefix.count)
        guard !indices.isEmpty else { return current }
        for component in indices.split(separator: "/", omittingEmptySubsequences: false) {
            guard let index = Int(component), index >= 0 else { return nil }
            let children = anchorChildren(of: current)
            guard index < children.count else { return nil }
            current = children[index]
        }
        return current
    }

    static func path(of element: Element) -> String? {
        guard let body = element.ownerDocument()?.body() else { return nil }
        var indices: [String] = []
        var current = element
        while current !== body {
            guard let parent = current.parent(),
                  let index = anchorChildren(of: parent).firstIndex(where: { $0 === current }) else {
                return nil
            }
            indices.insert(String(index), at: 0)
            current = parent
        }
        return prefix + indices.joined(separator: "/")
    }

    /// Tag, id, and child tags; deliberately no text, which typeset TeX changes in the reader.
    static func signature(of element: Element) -> String {
        let children = anchorChildren(of: element)
        return [
            element.tagNameNormal().lowercased(),
            element.id(),
            String(children.count),
            children.prefix(signatureChildLimit).map { $0.tagNameNormal().lowercased() }.joined(separator: ","),
        ].joined(separator: "|")
    }
}
