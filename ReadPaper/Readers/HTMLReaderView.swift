import SwiftUI
import WebKit

struct HTMLReaderView: NSViewRepresentable {
    var fileURL: URL?
    var displayMode: TranslationDisplayMode
    var reloadToken: Int

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.displayMode = displayMode
        guard let fileURL else {
            view.loadHTMLString(emptyHTML, baseURL: nil)
            context.coordinator.loadedURL = nil
            context.coordinator.loadedReloadToken = nil
            return
        }

        if context.coordinator.loadedURL != fileURL || context.coordinator.loadedReloadToken != reloadToken {
            let readAccessURL = fileURL.deletingLastPathComponent()
            view.loadFileURL(fileURL, allowingReadAccessTo: readAccessURL)
            context.coordinator.loadedURL = fileURL
            context.coordinator.loadedReloadToken = reloadToken
            return
        }

        context.coordinator.applyDisplayMode(to: view)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedURL: URL?
        var loadedReloadToken: Int?
        var displayMode: TranslationDisplayMode = .bilingual

        func applyDisplayMode(to webView: WKWebView) {
            let script = "document.documentElement.setAttribute('data-rp-display-mode', '\(displayMode.rawValue)');"
            webView.evaluateJavaScript(script)
        }

        @MainActor
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            applyDisplayMode(to: webView)
        }

        @MainActor
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            guard navigationAction.navigationType == .linkActivated,
                  let url = navigationAction.request.url,
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                decisionHandler(.allow)
                return
            }
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        }
    }

    private var emptyHTML: String {
        """
        <html>
        <body style="font: -apple-system-body; padding: 24px;">
        <p>No HTML paper is available for this item.</p>
        </body>
        </html>
        """
    }
}
