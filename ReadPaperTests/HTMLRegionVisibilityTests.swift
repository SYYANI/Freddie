import SwiftSoup
import SwiftUI
import WebKit
import XCTest
@testable import ReadPaper

final class HTMLRegionVisibilityTests: XCTestCase {
    func testAnchorPathsSkipReaderOnlyElementsAndRoundTrip() throws {
        let document = try SwiftSoup.parse("""
        <html><body><main>
        <p id="first" data-rp-segment-id="s1">First <span class="rp-tex-math">x</span><em>emphasis</em></p>
        <p class="rp-translation-block" data-rp-translation="true" data-rp-source-segment-id="s1">第一段</p>
        <div><span>Share</span><a href="https://example.com">X</a></div>
        </main></body></html>
        """)
        let body = try XCTUnwrap(document.body())
        let share = try XCTUnwrap(document.select("div").first())
        let emphasis = try XCTUnwrap(document.select("em").first())
        let translation = try XCTUnwrap(document.select(".rp-translation-block").first())

        XCTAssertEqual(HTMLAnchorPath.path(of: share), "rp-anchor:0/1")
        XCTAssertEqual(HTMLAnchorPath.path(of: emphasis), "rp-anchor:0/0/0", "Typeset TeX must not shift indices")
        XCTAssertNil(HTMLAnchorPath.path(of: translation), "Translation blocks only exist next to their source")
        XCTAssertTrue(HTMLAnchorPath.element(at: "rp-anchor:", in: document) === body)
        XCTAssertNil(HTMLAnchorPath.element(at: "rp-anchor:0/5", in: document))
        XCTAssertNil(HTMLAnchorPath.element(at: "[data-rp-segment-id=\"s1\"]", in: document))
        XCTAssertEqual(HTMLAnchorPath.signature(of: share), "div||2|span,a")
        XCTAssertEqual(HTMLAnchorPath.signature(of: try XCTUnwrap(document.getElementById("first"))), "p|first|1|em")

        for element in try body.select("*").array() {
            guard let path = HTMLAnchorPath.path(of: element) else { continue }
            XCTAssertTrue(HTMLAnchorPath.element(at: path, in: document) === element, path)
        }
    }

    func testApplyingHidesAndRestoresRegionsAndPersistsTheHidingStyle() throws {
        let html = """
        <!doctype html><html><head><meta charset="UTF-8"><title>Page</title></head><body>
        <main><p>Keep this paragraph.</p><div class="share"><span>Share</span><a href="https://example.com">X</a></div></main>
        </body></html>
        """
        let hide = HTMLRegionChange(path: "rp-anchor:0/1", signature: "div||2|span,a", isHidden: true)

        let hidden = try HTMLRegionVisibility.applying([hide], toHTML: html)
        XCTAssertTrue(hidden.didChange)
        XCTAssertEqual(hidden.hiddenRegionCount, 1)
        XCTAssertEqual(hidden.unmatchedChanges, [])
        let hiddenDocument = try SwiftSoup.parse(hidden.html)
        XCTAssertEqual(try hiddenDocument.select("div.share").first()?.attr("data-rp-region-hidden"), "true")
        XCTAssertEqual(
            try hiddenDocument.getElementById(HTMLRegionVisibility.styleElementID)?.data(),
            HTMLRegionVisibility.hiddenRegionCSS
        )
        XCTAssertEqual(try hiddenDocument.select("meta[charset]").first()?.attr("charset"), "UTF-8")
        XCTAssertEqual(try hiddenDocument.select("main > p").text(), "Keep this paragraph.")

        let repeated = try HTMLRegionVisibility.applying([hide], toHTML: hidden.html)
        XCTAssertFalse(repeated.didChange)
        XCTAssertEqual(repeated.html, hidden.html)

        var restore = hide
        restore.isHidden = false
        let restored = try HTMLRegionVisibility.applying([restore], toHTML: hidden.html)
        XCTAssertTrue(restored.didChange)
        XCTAssertEqual(restored.hiddenRegionCount, 0)
        let restoredDocument = try SwiftSoup.parse(restored.html)
        XCTAssertFalse(try XCTUnwrap(restoredDocument.select("div.share").first()).hasAttr("data-rp-region-hidden"))
        XCTAssertNil(try restoredDocument.getElementById(HTMLRegionVisibility.styleElementID))
    }

    func testApplyingRejectsChangesThatNoLongerMatchTheSavedElement() throws {
        let html = #"<html><head><meta charset="UTF-8"></head><body><p>One</p><p>Two <em>three</em></p></body></html>"#
        let stale = HTMLRegionChange(path: "rp-anchor:1", signature: "p||0|", isHidden: true)
        let missing = HTMLRegionChange(path: "rp-anchor:7", signature: "p||0|", isHidden: true)

        let update = try HTMLRegionVisibility.applying([stale, missing], toHTML: html)

        XCTAssertFalse(update.didChange)
        XCTAssertEqual(update.html, html)
        XCTAssertEqual(update.unmatchedChanges, [stale, missing])
    }

    func testApplyingDeclaresUTF8WhenTheSavedPageDoesNot() throws {
        let html = #"<html><head><meta http-equiv="Content-Type" content="text/html; charset=ISO-8859-1"></head><body><p>Café</p></body></html>"#

        let update = try HTMLRegionVisibility.applying(
            [HTMLRegionChange(path: "rp-anchor:0", signature: "p||0|", isHidden: true)],
            toHTML: html
        )

        let document = try SwiftSoup.parse(update.html)
        XCTAssertEqual(try document.head()?.child(0).attr("charset"), "UTF-8")
        XCTAssertEqual(try document.select("meta[http-equiv]").count, 0)
    }

    @MainActor
    func testApplyToFileOnlyRewritesThePageWhenRegionsChange() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("paper.html")
        let html = #"<html><head><meta charset="UTF-8"></head><body><nav>Menu</nav><p>Article</p></body></html>"#
        try html.write(to: fileURL, atomically: true, encoding: .utf8)
        let hideNavigation = HTMLRegionChange(path: "rp-anchor:0", signature: "nav||0|", isHidden: true)

        try HTMLRegionVisibility.apply([hideNavigation], toFileAt: fileURL)
        let saved = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(saved.contains(#"<nav data-rp-region-hidden="true">Menu</nav>"#))

        let unchanged = try HTMLRegionVisibility.apply([hideNavigation], toFileAt: fileURL)
        XCTAssertFalse(unchanged.didChange)
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), saved)
    }

    @MainActor
    func testReaderEditsResolveToTheSameElementsInTheSavedPage() async throws {
        let html = Self.readerHTML
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let coordinator = HTMLReaderView.Coordinator(
            scrollRatio: .constant(0), onNoteSelectionChanged: nil, onSelectionAssistantDismissed: nil
        )
        configuration.userContentController.add(coordinator, name: HTMLRegionEditing.messageHandlerName)
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 1000), configuration: configuration)
        let loaded = expectation(description: "Region document loaded")
        let observer = RegionNavigationObserver(loaded: loaded)
        webView.navigationDelegate = observer
        webView.loadHTMLString(html, baseURL: nil)
        await fulfillment(of: [loaded], timeout: 15)
        if !HTMLTeXRendering.userScript.isEmpty {
            _ = try await webView.evaluateJavaScript(HTMLTeXRendering.userScript)
        }
        _ = try await webView.evaluateJavaScript(HTMLReaderView.Coordinator.instrumentationScript)
        _ = try await webView.evaluateJavaScript(HTMLReaderView.Coordinator.findScript)
        _ = try await webView.evaluateJavaScript(HTMLRegionEditing.script)
        let bodyHTMLBeforeEditing = try await webView.evaluateJavaScript("document.body.innerHTML") as? String

        let recorder = RegionEditRecorder()
        coordinator.onRegionEditEvent = { event in recorder.record(event) }
        coordinator.isRegionEditing = true
        coordinator.regionEditLabels = HTMLRegionEditLabels(hide: "Hide", restore: "Restore")
        coordinator.webView(webView, didFinish: nil)
        try await recorder.waitForUpdates(1)
        XCTAssertEqual(recorder.updates.last?.changes, [])
        XCTAssertEqual(recorder.updates.last?.hiddenRegionCount, 0)

        // Inline content picks the enclosing block, and the click must not follow the link.
        let shareLinkDefaultPrevented = try await click(".share a", in: webView)
        XCTAssertTrue(shareLinkDefaultPrevented)
        try await recorder.waitForUpdates(2)
        // Clicking a translation edits its source; clicking the faded source again restores it.
        _ = try await click("#intro em", in: webView)
        _ = try await click(".rp-translation-block", in: webView)
        _ = try await click(".rp-translation-block", in: webView)
        try await recorder.waitForUpdates(5)
        XCTAssertEqual(recorder.updates[3].changes.map(\.isHidden), [false])

        // ↑ grows the outline to the parent block but never to the wrapper spanning the article.
        try await hover("#methods-one", in: webView)
        try await press(["key": "ArrowUp"], in: webView)
        try await press(["key": "ArrowUp"], in: webView)
        var state = try await editState(in: webView)
        XCTAssertEqual(state["selectedTag"] as? String, "section")
        XCTAssertEqual(state["action"] as? String, "Hide")
        _ = try await click("#methods-one", in: webView)
        try await recorder.waitForUpdates(6)
        state = try await editState(in: webView)
        XCTAssertEqual(state["action"] as? String, "Restore")

        // Table parts are skipped so a hover outlines the whole table.
        try await hover("td", in: webView)
        state = try await editState(in: webView)
        XCTAssertEqual(state["selectedTag"] as? String, "table")

        try await press(["key": "z", "metaKey": true], in: webView)
        try await recorder.waitForUpdates(7)
        XCTAssertEqual(recorder.updates[6].changes.map(\.isHidden), [false])
        XCTAssertEqual(recorder.updates[6].canRedo, true)
        try await press(["key": "Z", "metaKey": true, "shiftKey": true], in: webView)
        try await recorder.waitForUpdates(8)
        XCTAssertEqual(recorder.updates[7].hiddenRegionCount, 3)
        try await press(["key": "Escape"], in: webView)
        try await waitUntil { recorder.exitRequests == 1 }

        // Every reported path names the same element in the saved file.
        let savedDocument = try SwiftSoup.parse(html)
        let expectedPaths = try [".share", "#intro", "section"].map { selector in
            try XCTUnwrap(HTMLAnchorPath.path(of: try XCTUnwrap(savedDocument.select(selector).first())))
        }
        let latestChanges = Dictionary(
            recorder.updates.flatMap(\.changes).map { ($0.path, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        XCTAssertEqual(Set(latestChanges.keys), Set(expectedPaths))
        let saved = try HTMLRegionVisibility.applying(Array(latestChanges.values), toHTML: html)
        XCTAssertEqual(saved.unmatchedChanges, [])
        XCTAssertEqual(saved.hiddenRegionCount, 3)
        let hiddenTexts = try SwiftSoup.parse(saved.html).select("[data-rp-region-hidden=true]").array().map { try $0.text() }
        XCTAssertEqual(hiddenTexts.count, 3)
        XCTAssertTrue(hiddenTexts[0].hasPrefix("Intro text"))
        XCTAssertEqual(hiddenTexts[1], "Share on X")
        XCTAssertTrue(hiddenTexts[2].hasPrefix("Methods"))

        coordinator.isRegionEditing = false
        coordinator.applyRegionEditing(to: webView)
        let finalState = try await jsonObject("""
        JSON.stringify({
            share: getComputedStyle(document.querySelector('.share')).display,
            intro: getComputedStyle(document.getElementById('intro')).display,
            translation: getComputedStyle(document.querySelector('.rp-translation-block')).display,
            section: getComputedStyle(document.querySelector('section')).display,
            table: getComputedStyle(document.querySelector('table')).display,
            editing: document.documentElement.hasAttribute('\(HTMLRegionVisibility.editingAttribute)'),
            outlineVisible: document.querySelector('.rp-region-edit-box').classList.contains('is-visible'),
            sectionAnchorStable: window.__rpResolveNoteAnchor('\(expectedPaths[2])') === document.querySelector('section'),
            findText: JSON.parse(window.__rpFindCollect()).segments.join(' '),
            bodyHTML: document.body.innerHTML.replaceAll(' \(HTMLRegionVisibility.hiddenAttribute)="true"', '')
        })
        """, in: webView)
        XCTAssertEqual(finalState["share"] as? String, "none")
        XCTAssertEqual(finalState["intro"] as? String, "none")
        XCTAssertEqual(finalState["translation"] as? String, "none", "A hidden source also hides its translation")
        XCTAssertEqual(finalState["section"] as? String, "none")
        XCTAssertNotEqual(finalState["table"] as? String, "none")
        XCTAssertEqual(finalState["editing"] as? Bool, false)
        XCTAssertEqual(finalState["outlineVisible"] as? Bool, false)
        XCTAssertEqual(finalState["sectionAnchorStable"] as? Bool, true)
        let findText = try XCTUnwrap(finalState["findText"] as? String)
        XCTAssertTrue(findText.contains("Cell A"))
        XCTAssertFalse(findText.contains("Share on"))
        XCTAssertFalse(findText.contains("Methods paragraph"))
        XCTAssertEqual(finalState["bodyHTML"] as? String, bodyHTMLBeforeEditing, "Editing must only toggle the hidden attribute")
    }

    private static let readerHTML = #"""
    <!doctype html>
    <html><head><meta charset="UTF-8"><style>body { margin: 0; padding: 20px; font: 16px -apple-system; }</style></head>
    <body class="rp-readability-body"><main class="rp-readability-shell">
    <div class="rp-readability-header"><h1 class="rp-readability-title">Region Editing</h1></div>
    <article class="rp-readability-content"><div id="readability-page-1" class="page"><div class="wrapper">
    <p id="intro" data-rp-segment-id="s1" data-rp-source="true"><em>Intro text</em> with math \(x^2\) and <a href="https://example.com/intro">a link</a>.</p>
    <p class="rp-translation-block" data-rp-translation="true" data-rp-source-segment-id="s1">介绍文字，包含公式。</p>
    <div class="share"><span>Share on</span> <a href="https://example.com/share">X</a></div>
    <section><h2>Methods</h2><p id="methods-one">Methods paragraph one.</p><p>Methods paragraph two.</p></section>
    <table><tbody><tr><td>Cell A</td><td>Cell B</td></tr></tbody></table>
    </div></div></article>
    </main></body></html>
    """#

    @MainActor
    private func click(_ selector: String, in webView: WKWebView) async throws -> Bool {
        let result = try await webView.evaluateJavaScript("""
        (() => {
            const target = document.querySelector(\(Self.literal(selector)));
            const rect = target.getClientRects()[0];
            const x = rect.left + Math.min(6, rect.width / 2);
            const y = rect.top + rect.height / 2;
            const event = new MouseEvent('click', { clientX: x, clientY: y, bubbles: true, cancelable: true, button: 0 });
            (document.elementFromPoint(x, y) || target).dispatchEvent(event);
            return event.defaultPrevented;
        })()
        """)
        return try XCTUnwrap(result as? Bool)
    }

    @MainActor
    private func hover(_ selector: String, in webView: WKWebView) async throws {
        _ = try await webView.evaluateJavaScript("""
        (() => {
            const target = document.querySelector(\(Self.literal(selector)));
            const rect = target.getClientRects()[0];
            const x = rect.left + Math.min(6, rect.width / 2);
            const y = rect.top + rect.height / 2;
            (document.elementFromPoint(x, y) || target).dispatchEvent(
                new MouseEvent('mousemove', { clientX: x, clientY: y, bubbles: true })
            );
            return true;
        })()
        """)
    }

    @MainActor
    private func press(_ key: [String: Any], in webView: WKWebView) async throws {
        let data = try JSONSerialization.data(withJSONObject: key)
        let options = try XCTUnwrap(String(data: data, encoding: .utf8))
        _ = try await webView.evaluateJavaScript("""
        (() => {
            window.dispatchEvent(new KeyboardEvent('keydown', Object.assign({ bubbles: true, cancelable: true }, \(options))));
            return true;
        })()
        """)
    }

    @MainActor
    private func editState(in webView: WKWebView) async throws -> [String: Any] {
        try await jsonObject("window.__rpRegionEditState()", in: webView)
    }

    @MainActor
    private func jsonObject(_ script: String, in webView: WKWebView) async throws -> [String: Any] {
        let result = try await webView.evaluateJavaScript(script)
        let json = try XCTUnwrap(result as? String)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while condition() == false {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for the page")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private static func literal(_ value: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [value])
        return String(String(data: data, encoding: .utf8)!.dropFirst().dropLast())
    }
}

@MainActor
private final class RegionEditRecorder {
    var updates: [HTMLRegionEditUpdate] = []
    var exitRequests = 0

    func record(_ event: HTMLRegionEditEvent) {
        switch event {
        case let .updated(update):
            updates.append(update)
        case .exitRequested:
            exitRequests += 1
        }
    }

    func waitForUpdates(_ count: Int) async throws {
        let deadline = Date().addingTimeInterval(5)
        while updates.count < count {
            guard Date() < deadline else {
                XCTFail("Expected \(count) region updates, got \(updates.count)")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

private final class RegionNavigationObserver: NSObject, WKNavigationDelegate {
    let loaded: XCTestExpectation

    init(loaded: XCTestExpectation) {
        self.loaded = loaded
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded.fulfill()
    }
}
