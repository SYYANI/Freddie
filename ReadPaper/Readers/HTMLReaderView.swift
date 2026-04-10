import SwiftUI
import WebKit

struct HTMLReaderView: NSViewRepresentable {
    var fileURL: URL
    var displayMode: TranslationDisplayMode
    var reloadToken: Int
    @Binding var scrollRatio: Double
    var segmentUpdate: HTMLTranslationSegmentUpdate?

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(context.coordinator, name: Coordinator.scrollMessageHandlerName)
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: Coordinator.scrollTrackingScript,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
        )
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.displayMode = displayMode
        context.coordinator.scrollRatio = $scrollRatio
        let readAccessURL = fileURL.deletingLastPathComponent()
        if context.coordinator.loadedURL != fileURL {
            context.coordinator.requestLoad(
                fileURL: fileURL,
                readAccessURL: readAccessURL,
                reloadToken: reloadToken,
                preserveScrollPosition: false,
                targetScrollRatio: scrollRatio,
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
                targetScrollRatio: scrollRatio,
                in: view
            )
            return
        }

        context.coordinator.applyDisplayMode(to: view)
        context.coordinator.applySegmentUpdateIfNeeded(segmentUpdate, to: view)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(scrollRatio: $scrollRatio)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        private struct LoadRequest: Equatable {
            let fileURL: URL
            let readAccessURL: URL
            let reloadToken: Int
            let preserveScrollPosition: Bool
            let targetScrollRatio: Double
        }

        static let scrollMessageHandlerName = "rpScroll"
        static let scrollTrackingScript = """
        (() => {
            if (window.__rpScrollTrackingInstalled) { return; }
            window.__rpScrollTrackingInstalled = true;
            const maxScrollY = () => {
                const documentHeight = Math.max(
                    document.documentElement?.scrollHeight || 0,
                    document.body?.scrollHeight || 0
                );
                return Math.max(0, documentHeight - window.innerHeight);
            };

            const reportScrollRatio = () => {
                const maxY = maxScrollY();
                const ratio = maxY > 0 ? Math.min(1, Math.max(0, window.scrollY / maxY)) : 0;
                window.webkit.messageHandlers.rpScroll.postMessage(ratio);
            };

            let timer = null;
            window.addEventListener('scroll', () => {
                if (timer !== null) {
                    clearTimeout(timer);
                }
                timer = setTimeout(() => {
                    timer = null;
                    reportScrollRatio();
                }, 120);
            }, { passive: true });
        })();
        """

        var loadedURL: URL?
        var loadedReloadToken: Int?
        var displayMode: TranslationDisplayMode = .bilingual
        var scrollRatio: Binding<Double>
        private var currentRequest: LoadRequest?
        private var pendingRequest: LoadRequest?
        private var pendingScrollRatio: Double?
        private var pendingSegmentUpdates: [HTMLTranslationSegmentUpdate] = []
        private var lastAppliedSegmentSequence: Int?
        private var isLoading = false
        private var isDocumentReady = false

        init(scrollRatio: Binding<Double>) {
            self.scrollRatio = scrollRatio
        }

        func resetLoadedState() {
            loadedURL = nil
            loadedReloadToken = nil
            currentRequest = nil
            pendingRequest = nil
            pendingScrollRatio = nil
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
            targetScrollRatio: Double,
            in webView: WKWebView
        ) {
            let request = LoadRequest(
                fileURL: fileURL,
                readAccessURL: readAccessURL,
                reloadToken: reloadToken,
                preserveScrollPosition: preserveScrollPosition,
                targetScrollRatio: Self.clampedScrollRatio(targetScrollRatio)
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
                pendingScrollRatio = request.targetScrollRatio
                beginLoad(request, in: webView)
                return
            }

            captureScrollRatio(from: webView) { [weak self, weak webView] ratio in
                Task { @MainActor in
                    guard let self, let webView else { return }
                    self.pendingScrollRatio = ratio
                    self.beginLoad(request, in: webView)
                }
            }
        }

        func applyDisplayMode(to webView: WKWebView) {
            guard let displayModeValue = javaScriptStringLiteral(displayMode.rawValue) else {
                return
            }
            runJavaScript(
                "document.documentElement.setAttribute('data-rp-display-mode', \(displayModeValue));",
                in: webView
            )
        }

        @MainActor
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isDocumentReady = true
            applyDisplayMode(to: webView)
            restoreScrollRatioIfNeeded(in: webView)
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

        @MainActor
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == Self.scrollMessageHandlerName else { return }

            let reportedValue: Double?
            switch message.body {
            case let number as NSNumber:
                reportedValue = number.doubleValue
            case let string as String:
                reportedValue = Double(string)
            default:
                reportedValue = nil
            }

            guard let reportedValue else { return }
            let normalized = Self.clampedScrollRatio(reportedValue)
            guard normalized != scrollRatio.wrappedValue else { return }
            scrollRatio.wrappedValue = normalized
        }

        private func beginLoad(_ request: LoadRequest, in webView: WKWebView) {
            loadedURL = request.fileURL
            loadedReloadToken = request.reloadToken
            webView.loadFileURL(request.fileURL, allowingReadAccessTo: request.readAccessURL)
        }

        private func captureScrollRatio(from webView: WKWebView, completion: @escaping (Double) -> Void) {
            let script = """
            (() => {
                const documentHeight = Math.max(
                    document.documentElement?.scrollHeight || 0,
                    document.body?.scrollHeight || 0
                );
                const maxY = Math.max(0, documentHeight - window.innerHeight);
                return String(maxY > 0 ? Math.min(1, Math.max(0, window.scrollY / maxY)) : 0);
            })();
            """
            webView.evaluateJavaScript(script) { result, _ in
                let ratio = (result as? String).flatMap(Double.init) ?? 0

                Task { @MainActor in
                    completion(Self.clampedScrollRatio(ratio))
                }
            }
        }

        private func restoreScrollRatioIfNeeded(in webView: WKWebView) {
            guard let scrollRatio = pendingScrollRatio else { return }
            pendingScrollRatio = nil
            runJavaScript(
                """
                (() => {
                    const ratio = \(Self.clampedScrollRatio(scrollRatio));
                    const restore = () => {
                        const documentHeight = Math.max(
                            document.documentElement?.scrollHeight || 0,
                            document.body?.scrollHeight || 0
                        );
                        const maxY = Math.max(0, documentHeight - window.innerHeight);
                        window.scrollTo(0, maxY * ratio);
                    };
                    requestAnimationFrame(() => requestAnimationFrame(restore));
                })();
                """,
                in: webView
            )
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
                targetScrollRatio: pendingRequest.targetScrollRatio,
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
                if (!source) { return; }
                document.querySelectorAll(\(translationSelector)).forEach(node => node.remove());
                source.insertAdjacentHTML('afterend', \(translatedHTML));
            })();
            """
            runJavaScript(script, in: webView)
            lastAppliedSegmentSequence = update.sequence
        }

        private func javaScriptStringLiteral(_ string: String) -> String? {
            guard let data = try? JSONSerialization.data(withJSONObject: [string]),
                  let json = String(data: data, encoding: .utf8) else {
                return nil
            }
            return String(json.dropFirst().dropLast())
        }

        private func runJavaScript(_ script: String, in webView: WKWebView) {
            webView.evaluateJavaScript(script, completionHandler: nil)
        }

        private static func clampedScrollRatio(_ value: Double) -> Double {
            let clamped = min(max(value, 0), 1)
            return (clamped * 1000).rounded() / 1000
        }
    }
}
