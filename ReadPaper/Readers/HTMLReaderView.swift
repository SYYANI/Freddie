import SwiftUI
import WebKit

struct HTMLReaderView: NSViewRepresentable {
    var fileURL: URL
    var attachmentID: UUID? = nil
    var displayMode: TranslationDisplayMode
    var reloadToken: Int
    @Binding var scrollRatio: Double
    var segmentUpdate: HTMLTranslationSegmentUpdate?
    var noteNavigationRequest: NoteNavigationRequest? = nil
    var onNoteSelectionChanged: ((NoteSelectionContext?) -> Void)? = nil

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(context.coordinator, name: Coordinator.scrollMessageHandlerName)
        configuration.userContentController.add(context.coordinator, name: Coordinator.selectionMessageHandlerName)
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: Coordinator.instrumentationScript,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
        )
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.attachmentID = attachmentID
        context.coordinator.displayMode = displayMode
        context.coordinator.scrollRatio = $scrollRatio
        context.coordinator.onNoteSelectionChanged = onNoteSelectionChanged

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
        context.coordinator.applyNoteNavigationIfNeeded(noteNavigationRequest, to: view)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            scrollRatio: $scrollRatio,
            onNoteSelectionChanged: onNoteSelectionChanged
        )
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
        static let selectionMessageHandlerName = "rpSelection"
        static let instrumentationScript = """
        (() => {
            if (window.__rpReaderToolsInstalled) { return; }
            window.__rpReaderToolsInstalled = true;

            const translationSelector = '.rp-translation-block,[data-rp-translation="true"]';

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

            const isElementNode = node => node && node.nodeType === Node.ELEMENT_NODE;
            const elementFromNode = node => {
                if (!node) { return null; }
                if (isElementNode(node)) { return node; }
                return node.parentElement || null;
            };

            const isTranslationElement = element =>
                !!(element && element.matches && element.matches(translationSelector));

            const originalChildren = parent =>
                Array.from(parent?.children || []).filter(child => !isTranslationElement(child));

            const normalizeText = text => (text || '').replace(/\\s+/g, ' ').trim();

            const selectorForSegment = segmentID =>
                segmentID ? `[data-rp-segment-id="${segmentID}"]` : null;

            const buildOriginalPathAnchor = element => {
                const segments = [];
                let current = element;
                while (current && current !== document.body) {
                    const parent = current.parentElement;
                    if (!parent) { return null; }
                    const siblings = originalChildren(parent);
                    const index = siblings.indexOf(current);
                    if (index < 0) { return null; }
                    segments.unshift(String(index));
                    current = parent;
                }
                return `rp-anchor:${segments.join('/')}`;
            };

            const resolveOriginalPathAnchor = anchor => {
                if (!anchor || !anchor.startsWith('rp-anchor:')) { return null; }
                const path = anchor.slice('rp-anchor:'.length);
                let current = document.body;
                if (!path) { return current; }

                for (const rawIndex of path.split('/')) {
                    const index = Number.parseInt(rawIndex, 10);
                    if (!Number.isFinite(index)) { return null; }
                    const children = originalChildren(current);
                    current = children[index] || null;
                    if (!current) { return null; }
                }
                return current;
            };

            const closestMatching = (element, selector) => {
                if (!element || !element.closest) { return null; }
                return element.closest(selector);
            };

            const anchorElementForSelection = node => {
                let element = elementFromNode(node);
                if (!element) { return null; }

                const translatedBlock = closestMatching(
                    element,
                    '.rp-translation-block[data-rp-source-segment-id],[data-rp-translation="true"][data-rp-source-segment-id]'
                );
                const translatedSourceID = translatedBlock
                    ? translatedBlock.getAttribute('data-rp-source-segment-id')
                    : null;
                if (translatedSourceID) {
                    return document.querySelector(selectorForSegment(translatedSourceID));
                }

                const sourceSegment = closestMatching(element, '[data-rp-segment-id]');
                if (sourceSegment) {
                    return sourceSegment;
                }

                while (element && isTranslationElement(element)) {
                    element = element.previousElementSibling || element.parentElement;
                }
                return element;
            };

            window.__rpResolveNoteAnchor = anchor => {
                if (!anchor) { return null; }
                if (anchor.startsWith('rp-anchor:')) {
                    return resolveOriginalPathAnchor(anchor);
                }
                try {
                    return document.querySelector(anchor);
                } catch {
                    return null;
                }
            };

            if (!document.getElementById('rp-note-anchor-style')) {
                const style = document.createElement('style');
                style.id = 'rp-note-anchor-style';
                style.textContent = `
                    .rp-note-anchor-target {
                        outline: 2px solid rgba(31, 77, 58, 0.32);
                        background: rgba(31, 77, 58, 0.10);
                        transition: background 0.2s ease;
                    }
                `;
                if (document.head) {
                    document.head.appendChild(style);
                }
            }

            window.__rpScrollToNoteAnchor = anchor => {
                const target = window.__rpResolveNoteAnchor(anchor);
                if (!target) { return false; }
                target.scrollIntoView({ behavior: 'smooth', block: 'center', inline: 'nearest' });
                target.classList.add('rp-note-anchor-target');
                window.setTimeout(() => target.classList.remove('rp-note-anchor-target'), 1400);
                return true;
            };

            let scrollTimer = null;
            window.addEventListener('scroll', () => {
                if (scrollTimer !== null) {
                    clearTimeout(scrollTimer);
                }
                scrollTimer = window.setTimeout(() => {
                    scrollTimer = null;
                    reportScrollRatio();
                }, 120);
            }, { passive: true });

            let selectionTimer = null;
            const reportSelection = () => {
                const selection = window.getSelection();
                const quote = normalizeText(selection ? selection.toString() : '');
                if (!quote) {
                    window.webkit.messageHandlers.rpSelection.postMessage(null);
                    return;
                }

                const anchorElement = anchorElementForSelection(selection.anchorNode || selection.focusNode);
                const segmentID = anchorElement ? anchorElement.getAttribute('data-rp-segment-id') : null;
                const selector = segmentID ? selectorForSegment(segmentID) : buildOriginalPathAnchor(anchorElement);
                if (!selector) {
                    window.webkit.messageHandlers.rpSelection.postMessage(null);
                    return;
                }

                window.webkit.messageHandlers.rpSelection.postMessage({ quote, selector });
            };

            document.addEventListener('selectionchange', () => {
                if (selectionTimer !== null) {
                    clearTimeout(selectionTimer);
                }
                selectionTimer = window.setTimeout(() => {
                    selectionTimer = null;
                    reportSelection();
                }, 80);
            });
        })();
        """

        var loadedURL: URL?
        var loadedReloadToken: Int?
        var attachmentID: UUID?
        var displayMode: TranslationDisplayMode = .bilingual
        var scrollRatio: Binding<Double>
        var onNoteSelectionChanged: ((NoteSelectionContext?) -> Void)?
        private var currentRequest: LoadRequest?
        private var pendingRequest: LoadRequest?
        private var pendingScrollRatio: Double?
        private var pendingSegmentUpdates: [HTMLTranslationSegmentUpdate] = []
        private var lastAppliedSegmentSequence: Int?
        private var pendingNoteNavigationRequest: NoteNavigationRequest?
        private var lastAppliedNoteNavigationID: UUID?
        private var lastPublishedNoteSelection: NoteSelectionContext?
        private var isLoading = false
        private var isDocumentReady = false

        init(
            scrollRatio: Binding<Double>,
            onNoteSelectionChanged: ((NoteSelectionContext?) -> Void)?
        ) {
            self.scrollRatio = scrollRatio
            self.onNoteSelectionChanged = onNoteSelectionChanged
        }

        func resetLoadedState() {
            loadedURL = nil
            loadedReloadToken = nil
            currentRequest = nil
            pendingRequest = nil
            pendingScrollRatio = nil
            pendingSegmentUpdates = []
            lastAppliedSegmentSequence = nil
            pendingNoteNavigationRequest = nil
            lastAppliedNoteNavigationID = nil
            isLoading = false
            isDocumentReady = false
            publishNoteSelection(nil)
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
            publishNoteSelection(nil)

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
            flushPendingNoteNavigationIfNeeded(in: webView)
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
            switch message.name {
            case Self.scrollMessageHandlerName:
                handleScrollMessage(message)
            case Self.selectionMessageHandlerName:
                handleSelectionMessage(message)
            default:
                return
            }
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

        func applyNoteNavigationIfNeeded(_ request: NoteNavigationRequest?, to webView: WKWebView) {
            guard let request,
                  let htmlSelector = request.htmlSelector,
                  request.id != lastAppliedNoteNavigationID else {
                return
            }

            if !isDocumentReady || isLoading {
                pendingNoteNavigationRequest = request
                return
            }

            guard let selectorLiteral = javaScriptStringLiteral(htmlSelector) else {
                return
            }

            let script = """
            (() => {
                const anchor = \(selectorLiteral);
                if (!window.__rpScrollToNoteAnchor) { return "false"; }
                return String(window.__rpScrollToNoteAnchor(anchor));
            })();
            """
            runJavaScript(script, in: webView)
            lastAppliedNoteNavigationID = request.id
        }

        private func flushPendingNoteNavigationIfNeeded(in webView: WKWebView) {
            guard let pendingNoteNavigationRequest else { return }
            self.pendingNoteNavigationRequest = nil
            applyNoteNavigationIfNeeded(pendingNoteNavigationRequest, to: webView)
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

        private func handleScrollMessage(_ message: WKScriptMessage) {
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

        private func handleSelectionMessage(_ message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else {
                publishNoteSelection(nil)
                return
            }

            let selection = NoteSelectionContext(
                attachmentID: attachmentID,
                quote: body["quote"] as? String ?? "",
                htmlSelector: body["selector"] as? String
            )
            guard selection.trimmedQuote != nil, selection.hasAnchor else {
                publishNoteSelection(nil)
                return
            }
            publishNoteSelection(selection)
        }

        private func publishNoteSelection(_ selection: NoteSelectionContext?) {
            guard lastPublishedNoteSelection != selection else { return }
            lastPublishedNoteSelection = selection
            onNoteSelectionChanged?(selection)
        }

        private static func clampedScrollRatio(_ value: Double) -> Double {
            let clamped = min(max(value, 0), 1)
            return (clamped * 1000).rounded() / 1000
        }
    }
}
