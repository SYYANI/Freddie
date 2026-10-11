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
