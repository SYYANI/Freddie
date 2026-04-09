import SwiftUI
import WebKit

struct HTMLReaderView: NSViewRepresentable {
    var fileURL: URL?
    var displayMode: TranslationDisplayMode
    var reloadToken: Int
    var segmentUpdate: HTMLTranslationSegmentUpdate?

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
            context.coordinator.resetLoadedState()
            return
        }

        let readAccessURL = fileURL.deletingLastPathComponent()
        if context.coordinator.loadedURL != fileURL {
            context.coordinator.requestLoad(
                fileURL: fileURL,
                readAccessURL: readAccessURL,
                reloadToken: reloadToken,
                preserveScrollPosition: false,
                in: view
            )
            return
        }

        if context.coordinator.loadedReloadToken != reloadToken {
            context.coordinator.requestLoad(
                fileURL: fileURL,
                readAccessURL: readAccessURL,
                reloadToken: reloadToken,
                preserveScrollPosition: true,
                in: view
            )
            return
        }

        context.coordinator.applyDisplayMode(to: view)
        context.coordinator.applySegmentUpdateIfNeeded(segmentUpdate, to: view)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private struct LoadRequest: Equatable {
            let fileURL: URL
            let readAccessURL: URL
            let reloadToken: Int
            let preserveScrollPosition: Bool
        }

        var loadedURL: URL?
        var loadedReloadToken: Int?
        var displayMode: TranslationDisplayMode = .bilingual
        private var currentRequest: LoadRequest?
        private var pendingRequest: LoadRequest?
        private var pendingScrollPosition: CGPoint?
        private var pendingSegmentUpdates: [HTMLTranslationSegmentUpdate] = []
        private var lastAppliedSegmentSequence: Int?
        private var isLoading = false
        private var isDocumentReady = false

        func resetLoadedState() {
            loadedURL = nil
            loadedReloadToken = nil
            currentRequest = nil
            pendingRequest = nil
            pendingScrollPosition = nil
            pendingSegmentUpdates = []
            lastAppliedSegmentSequence = nil
            isLoading = false
            isDocumentReady = false
        }

        func requestLoad(
            fileURL: URL,
            readAccessURL: URL,
            reloadToken: Int,
            preserveScrollPosition: Bool,
            in webView: WKWebView
        ) {
            let request = LoadRequest(
                fileURL: fileURL,
                readAccessURL: readAccessURL,
                reloadToken: reloadToken,
                preserveScrollPosition: preserveScrollPosition
            )

            if loadedURL == request.fileURL, loadedReloadToken == request.reloadToken, !isLoading {
                return
            }
            if currentRequest == request || pendingRequest == request {
                return
            }
            if isLoading {
                pendingRequest = request
                return
            }

            isLoading = true
            isDocumentReady = false
            currentRequest = request
            pendingSegmentUpdates = []
            lastAppliedSegmentSequence = nil

            guard preserveScrollPosition else {
                pendingScrollPosition = nil
                beginLoad(request, in: webView)
                return
            }

            captureScrollPosition(from: webView) { [weak self, weak webView] position in
                Task { @MainActor in
                    guard let self, let webView else { return }
                    self.pendingScrollPosition = position
                    self.beginLoad(request, in: webView)
                }
            }
        }

        func applyDisplayMode(to webView: WKWebView) {
            let script = "document.documentElement.setAttribute('data-rp-display-mode', '\(displayMode.rawValue)');"
            webView.evaluateJavaScript(script)
        }

        @MainActor
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isDocumentReady = true
            applyDisplayMode(to: webView)
            restoreScrollPositionIfNeeded(in: webView)
            flushPendingSegmentUpdates(in: webView)
            finishLoadIfNeeded(in: webView)
        }

        @MainActor
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            finishLoadIfNeeded(in: webView)
        }

        @MainActor
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            finishLoadIfNeeded(in: webView)
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

        private func beginLoad(_ request: LoadRequest, in webView: WKWebView) {
            loadedURL = request.fileURL
            loadedReloadToken = request.reloadToken
            webView.loadFileURL(request.fileURL, allowingReadAccessTo: request.readAccessURL)
        }

        private func captureScrollPosition(from webView: WKWebView, completion: @escaping (CGPoint) -> Void) {
            let script = "[window.scrollX || 0, window.scrollY || 0]"
            webView.evaluateJavaScript(script) { result, _ in
                let position: CGPoint
                if let values = result as? [Double], values.count == 2 {
                    position = CGPoint(x: values[0], y: values[1])
                } else if let values = result as? [NSNumber], values.count == 2 {
                    position = CGPoint(x: values[0].doubleValue, y: values[1].doubleValue)
                } else {
                    position = .zero
                }

                Task { @MainActor in
                    completion(position)
                }
            }
        }

        private func restoreScrollPositionIfNeeded(in webView: WKWebView) {
            guard let position = pendingScrollPosition else { return }
            pendingScrollPosition = nil
            let script = "window.scrollTo(\(position.x), \(position.y));"
            webView.evaluateJavaScript(script)
        }

        private func finishLoadIfNeeded(in webView: WKWebView) {
            isLoading = false
            currentRequest = nil

            guard let pendingRequest else { return }
            self.pendingRequest = nil
            requestLoad(
                fileURL: pendingRequest.fileURL,
                readAccessURL: pendingRequest.readAccessURL,
                reloadToken: pendingRequest.reloadToken,
                preserveScrollPosition: pendingRequest.preserveScrollPosition,
                in: webView
            )
        }

        func applySegmentUpdateIfNeeded(_ update: HTMLTranslationSegmentUpdate?, to webView: WKWebView) {
            guard let update else { return }
            guard update.sequence != lastAppliedSegmentSequence else { return }

            if !isDocumentReady || isLoading {
                if pendingSegmentUpdates.last?.sequence != update.sequence {
                    pendingSegmentUpdates.append(update)
                }
                return
            }

            applySegmentUpdate(update, to: webView)
        }

        private func flushPendingSegmentUpdates(in webView: WKWebView) {
            guard !pendingSegmentUpdates.isEmpty else { return }
            let updates = pendingSegmentUpdates.sorted { $0.sequence < $1.sequence }
            pendingSegmentUpdates.removeAll()
            for update in updates where update.sequence != lastAppliedSegmentSequence {
                applySegmentUpdate(update, to: webView)
            }
        }

        private func applySegmentUpdate(_ update: HTMLTranslationSegmentUpdate, to webView: WKWebView) {
            guard let segmentSelector = javaScriptStringLiteral("[data-rp-segment-id=\"\(update.segmentID)\"]"),
                  let translationSelector = javaScriptStringLiteral(".rp-translation-block[data-rp-source-segment-id=\"\(update.segmentID)\"]"),
                  let translatedHTML = javaScriptStringLiteral(update.translatedHTML) else {
                return
            }

            let script = """
            (() => {
                const source = document.querySelector(\(segmentSelector));
                if (!source) { return false; }
                document.querySelectorAll(\(translationSelector)).forEach(node => node.remove());
                source.insertAdjacentHTML('afterend', \(translatedHTML));
                return true;
            })();
            """
            webView.evaluateJavaScript(script)
            lastAppliedSegmentSequence = update.sequence
        }

        private func javaScriptStringLiteral(_ string: String) -> String? {
            guard let data = try? JSONSerialization.data(withJSONObject: [string]),
                  let json = String(data: data, encoding: .utf8) else {
                return nil
            }
            return String(json.dropFirst().dropLast())
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
