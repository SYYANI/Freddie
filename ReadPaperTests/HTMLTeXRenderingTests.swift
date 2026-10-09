import SwiftUI
import WebKit
import XCTest
@testable import ReadPaper

final class HTMLTeXRenderingTests: XCTestCase {
    func testUserScriptBundlesTemml() {
        XCTAssertTrue(HTMLTeXRendering.userScript.contains("__rpRenderTeX"))
        XCTAssertTrue(HTMLTeXRendering.userScript.contains("data:font/woff2;base64,"))
    }

    @MainActor
    func testRendersTeXDelimitersWithoutShiftingNoteAnchorPaths() async throws {
        let html = #"""
        <html><head><meta charset="UTF-8"></head><body style="font: 17px -apple-system; line-height: 1.65; padding: 20px">
        <p data-rp-segment-id="s1" data-rp-source="true">The agent \(\pi_{\theta}\) produces <em>actions</em> \(a_t\).</p>
        <p data-rp-segment-id="s2" data-rp-source="true">\[a_{t+1} \sim \pi_{\theta}(\cdot \mid \mathcal{H}_{&lt;t}, o_t)\]</p>
        <pre>\(kept as code\)</pre>
        <p>It costs $5 and $10, \(\badcommand{\) stays as text.</p>
        <p><math><mi>x</mi></math></p>
        </body></html>
        """#
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let coordinator = HTMLReaderView.Coordinator(
            scrollRatio: .constant(0), onNoteSelectionChanged: nil, onSelectionAssistantDismissed: nil
        )
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 700), configuration: configuration)
        let loaded = expectation(description: "TeX document loaded")
        let observer = TeXNavigationObserver(loaded: loaded)
        webView.navigationDelegate = observer
        webView.loadHTMLString(html, baseURL: nil)
        await fulfillment(of: [loaded], timeout: 15)
        _ = try await webView.evaluateJavaScript(HTMLTeXRendering.userScript)
        _ = try await webView.evaluateJavaScript(HTMLReaderView.Coordinator.instrumentationScript)

        let state = try await jsonObject(
            """
            JSON.stringify({
                inline: document.querySelectorAll('[data-rp-segment-id="s1"] > .rp-tex-math > math').length,
                display: document.querySelectorAll('[data-rp-segment-id="s2"] > .rp-tex-math-display > math[display="block"]').length,
                styled: !!document.getElementById('rp-tex-math-style'),
                pre: document.querySelector('pre').textContent,
                prose: document.querySelectorAll('body > p')[2].textContent,
                anchoredTag: window.__rpResolveNoteAnchor('rp-anchor:0/0')?.tagName || null
            })
            """,
            in: webView
        )
        XCTAssertEqual(state["inline"] as? Int, 2)
        XCTAssertEqual(state["display"] as? Int, 1)
        XCTAssertEqual(state["styled"] as? Bool, true)
        XCTAssertEqual(state["pre"] as? String, #"\(kept as code\)"#)
        XCTAssertEqual(state["prose"] as? String, #"It costs $5 and $10, \(\badcommand{\) stays as text."#)
        XCTAssertEqual(state["anchoredTag"] as? String, "EM", "Rendered math must not shift rp-anchor element indices")

        coordinator.webView(webView, didFinish: nil)
        coordinator.applySegmentUpdateIfNeeded(
            HTMLTranslationSegmentUpdate(
                sequence: 1,
                processedSegments: 1,
                totalSegments: 2,
                segmentID: "s1",
                translatedHTML: #"<p class="rp-translation-block" data-rp-source-segment-id="s1">智能体 \(\pi_{\theta}\) 产生动作。</p>"#
            ),
            to: webView
        )
        let translatedMathCount = try await webView.evaluateJavaScript(
            "document.querySelectorAll('.rp-translation-block .rp-tex-math math').length"
        ) as? Int
        XCTAssertEqual(translatedMathCount, 1)
    }

    @MainActor
    private func jsonObject(_ script: String, in webView: WKWebView) async throws -> [String: Any] {
        let result = try await webView.evaluateJavaScript(script)
        let json = try XCTUnwrap(result as? String)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }
}

private final class TeXNavigationObserver: NSObject, WKNavigationDelegate {
    let loaded: XCTestExpectation

    init(loaded: XCTestExpectation) {
        self.loaded = loaded
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded.fulfill()
    }
}
