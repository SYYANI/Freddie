import SwiftUI
import WebKit
import XCTest
@testable import ReadPaper

final class HTMLReaderPageScriptTests: XCTestCase {
    @MainActor
    func testReaderRunsItsOwnScriptsButNeverThePagesScripts() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("paper.html")
        try #"""
        <!doctype html><html><head><meta charset="UTF-8">
        <script>window.__pageScriptRan = true; document.documentElement.setAttribute('data-page-script', 'ran');</script>
        </head><body>
        <p id="target">Readable paragraph with \(x^2\) inline math.</p>
        <img src="data:," onerror="window.__pageHandlerRan = true">
        <a id="script-link" href="javascript:window.__pageLinkRan = true">link</a>
        <iframe srcdoc="<script>parent.__frameScriptRan = true;</script>"></iframe>
        </body></html>
        """#.write(to: fileURL, atomically: true, encoding: .utf8)

        var selections: [NoteSelectionContext?] = []
        let coordinator = HTMLReaderView.Coordinator(
            scrollRatio: .constant(0),
            onNoteSelectionChanged: { selections.append($0) },
            onSelectionAssistantDismissed: nil
        )
        let configuration = HTMLReaderView.makeConfiguration(coordinator: coordinator)
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let loaded = expectation(description: "Reader page loaded")
        let observer = PageScriptNavigationObserver(loaded: loaded)
        webView.navigationDelegate = observer
        webView.loadFileURL(fileURL, allowingReadAccessTo: directory)
        await fulfillment(of: [loaded], timeout: 15)
        _ = try await webView.evaluateJavaScript("document.getElementById('script-link').click(); true")
        try await Task.sleep(for: .milliseconds(200))

        let json = try await webView.evaluateJavaScript("""
        JSON.stringify({
            pageScript: !!window.__pageScriptRan || document.documentElement.hasAttribute('data-page-script'),
            pageHandler: !!window.__pageHandlerRan,
            pageLink: !!window.__pageLinkRan,
            frameScript: !!window.__frameScriptRan,
            readerTools: !!window.__rpReaderToolsInstalled,
            find: typeof window.__rpFindCollect === 'function',
            sidenotes: typeof window.__rpSetSidenotes === 'function',
            regions: typeof window.__rpSetRegionEditing === 'function',
            typesetMath: document.querySelectorAll('.rp-tex-math').length
        })
        """) as? String
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(json).utf8)) as? [String: Any])
        XCTAssertEqual(state["pageScript"] as? Bool, false)
        XCTAssertEqual(state["pageHandler"] as? Bool, false)
        XCTAssertEqual(state["pageLink"] as? Bool, false)
        XCTAssertEqual(state["frameScript"] as? Bool, false)
        XCTAssertEqual(state["readerTools"] as? Bool, true)
        XCTAssertEqual(state["find"] as? Bool, true)
        XCTAssertEqual(state["sidenotes"] as? Bool, true)
        XCTAssertEqual(state["regions"] as? Bool, true)
        if !HTMLTeXRendering.userScript.isEmpty {
            XCTAssertEqual(state["typesetMath"] as? Int, 1)
        }

        // Selecting text goes through a reader listener, a timer, and a message handler.
        _ = try await webView.evaluateJavaScript("""
        (() => {
            const range = document.createRange();
            range.selectNodeContents(document.getElementById('target').firstChild);
            const selection = window.getSelection();
            selection.removeAllRanges();
            selection.addRange(range);
            return true;
        })()
        """)
        let deadline = Date().addingTimeInterval(5)
        while selections.compactMap({ $0 }).isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let selection = try XCTUnwrap(selections.compactMap { $0 }.last)
        XCTAssertTrue(selection.quote.hasPrefix("Readable paragraph"))
        XCTAssertEqual(selection.htmlSelector, "rp-anchor:0")
    }

    /// WebKit paints a cross-paragraph selection as a slab reaching the page edges, in the
    /// site's own `::selection` color, under the reader's blue highlight of the same text.
    @MainActor
    func testSelectionIsPaintedOnlyByTheReaderHighlight() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("paper.html")
        try """
        <!doctype html><html><head><meta charset="UTF-8">
        <style>::selection { background: rgba(217, 119, 87, 0.5); }</style>
        </head><body>
        <p id="first">First paragraph of the article.</p>
        <p class="rp-translation-block" data-rp-translation="true">文章的第一段。</p>
        <h2 id="heading">A section heading</h2>
        <p id="last">Last paragraph of the article.</p>
        </body></html>
        """.write(to: fileURL, atomically: true, encoding: .utf8)

        let coordinator = HTMLReaderView.Coordinator(
            scrollRatio: .constant(0),
            onNoteSelectionChanged: { _ in },
            onSelectionAssistantDismissed: nil
        )
        let configuration = HTMLReaderView.makeConfiguration(coordinator: coordinator)
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let loaded = expectation(description: "Reader page loaded")
        let observer = PageScriptNavigationObserver(loaded: loaded)
        webView.navigationDelegate = observer
        webView.loadFileURL(fileURL, allowingReadAccessTo: directory)
        await fulfillment(of: [loaded], timeout: 15)

        func state() async throws -> [String: Any] {
            let json = try await webView.evaluateJavaScript("""
            JSON.stringify({
                highlight: Array.from(CSS.highlights.get('rp-assistant-selection') || [])
                    .map(range => range.toString()).join('|'),
                selection: window.getSelection().rangeCount > 0
                    ? window.getSelection().getRangeAt(0).toString() : '',
                nativePaint: getComputedStyle(document.getElementById('first'), '::selection').backgroundColor,
                sameHighlight: !!window.__firstSelectionHighlight
                    && CSS.highlights.get('rp-assistant-selection') === window.__firstSelectionHighlight
            })
            """) as? String
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(json).utf8)) as? [String: Any])
        }

        _ = try await webView.evaluateJavaScript("""
        (() => {
            const range = document.createRange();
            range.setStart(document.getElementById('first').firstChild, 6);
            range.setEnd(document.getElementById('last').firstChild, 4);
            const selection = window.getSelection();
            selection.removeAllRanges();
            selection.addRange(range);
            return true;
        })()
        """)
        // selectionchange is dispatched asynchronously; the highlight follows it without the
        // report's debounce.
        try await Task.sleep(for: .milliseconds(40))
        var current = try await state()
        let selected = try XCTUnwrap(current["selection"] as? String)
        XCTAssertTrue(selected.hasPrefix("paragraph of the article."))
        XCTAssertEqual(current["highlight"] as? String, selected)
        XCTAssertEqual(current["nativePaint"] as? String, "rgba(0, 0, 0, 0)")

        // Dragging back up shrinks the highlight. WebKit only repaints the text a highlight
        // stops covering when the registered Highlight is changed in place, so it must stay
        // the same object.
        _ = try await webView.evaluateJavaScript("""
        window.__firstSelectionHighlight = CSS.highlights.get('rp-assistant-selection');
        window.getSelection().extend(document.getElementById('first').firstChild, 15);
        true
        """)
        try await Task.sleep(for: .milliseconds(40))
        current = try await state()
        XCTAssertEqual(current["highlight"] as? String, "paragraph")
        XCTAssertEqual(current["sameHighlight"] as? Bool, true)
        _ = try await webView.evaluateJavaScript("""
        window.getSelection().extend(document.getElementById('last').firstChild, 4);
        true
        """)
        try await Task.sleep(for: .milliseconds(40))

        // Dismissing the assistant while the text is still selected keeps it visible.
        _ = try await webView.evaluateJavaScript("window.__rpClearSelectionAssistantHighlight(); true")
        current = try await state()
        XCTAssertEqual(current["highlight"] as? String, selected)

        // Pressing on the page drops the old highlight before the selection collapses.
        _ = try await webView.evaluateJavaScript("""
        document.getElementById('heading').dispatchEvent(
            new PointerEvent('pointerdown', { bubbles: true, button: 0, clientX: 1, clientY: 1 })
        );
        window.getSelection().removeAllRanges();
        true
        """)
        try await Task.sleep(for: .milliseconds(40))
        current = try await state()
        XCTAssertEqual(current["highlight"] as? String, "")
        XCTAssertEqual(current["sameHighlight"] as? Bool, true)
    }
}

private final class PageScriptNavigationObserver: NSObject, WKNavigationDelegate {
    let loaded: XCTestExpectation

    init(loaded: XCTestExpectation) {
        self.loaded = loaded
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded.fulfill()
    }
}
