import SwiftUI
import WebKit

#if os(macOS)
import AppKit
private typealias PlatformHTMLViewRepresentable = NSViewRepresentable
#else
import UIKit
private typealias PlatformHTMLViewRepresentable = UIViewRepresentable
#endif

enum HTMLReaderTypography {
    static let fontSizeUserDefaultsKey = "ReadPaper.Reader.HTMLFontSize"
    static let defaultFontSize: Double = 17
    static let fontSizeRange: ClosedRange<Double> = 13...28

    static func clampFontSize(_ value: Double) -> Double {
        min(max(value, fontSizeRange.lowerBound), fontSizeRange.upperBound)
    }

    static func css(fontSize: Double) -> String {
        let clampedFontSize = Int(clampFontSize(fontSize).rounded())
        return """
        :root { --rp-reader-font-size: \(clampedFontSize)px; }
        body.rp-readability-body .rp-readability-content {
            font-size: var(--rp-reader-font-size) !important;
        }
        body.rp-readability-body .rp-readability-content p.rp-readability-prose-paragraph,
        body.rp-readability-body .rp-readability-content [data-rp-source='true'],
        body.rp-readability-body .rp-readability-content .rp-translation-block {
            font-size: var(--rp-reader-font-size) !important;
        }
        body.rp-readability-body .rp-readability-title,
        body.rp-readability-body .rp-readability-title + .rp-translation-block {
            font-size: calc(var(--rp-reader-font-size) * 1.9) !important;
        }
        body.rp-readability-body .rp-readability-byline,
        body.rp-readability-body .rp-readability-excerpt,
        body.rp-readability-body .rp-readability-byline + .rp-translation-block,
        body.rp-readability-body .rp-readability-excerpt + .rp-translation-block {
            font-size: calc(var(--rp-reader-font-size) * 0.95) !important;
        }
        body:not(.rp-readability-body) {
            font-size: var(--rp-reader-font-size);
        }
        """
    }
}

private extension PDFDisplayAppearance {
    var htmlReaderCSS: String {
        switch self {
        case .defaultMode:
            return """
            :root { color-scheme: light; }
            html,
            body,
            body.rp-readability-body,
            body.rp-readability-body .rp-readability-shell,
            body.rp-readability-body .rp-readability-header,
            body.rp-readability-body .rp-readability-content,
            body:not(.rp-readability-body) {
                background: transparent !important;
                background-color: transparent !important;
            }
            """
        case .paper:
            return """
            :root { color-scheme: light; }
            body.rp-readability-body {
                --rp-reader-text: #2b261f;
                --rp-reader-muted: #726752;
                --rp-reader-link: #285f86;
                --rp-reader-translation: #24533d;
            }
            html,
            body {
                background: transparent !important;
            }
            body {
                color: #2b261f !important;
            }
            body.rp-readability-body {
                background: transparent !important;
            }
            body.rp-readability-body .rp-readability-shell,
            body.rp-readability-body .rp-readability-header,
            body.rp-readability-body .rp-readability-content {
                color: #2b261f !important;
            }
            body.rp-readability-body .rp-readability-title,
            body.rp-readability-body .rp-readability-content h1,
            body.rp-readability-body .rp-readability-content h2,
            body.rp-readability-body .rp-readability-content h3,
            body.rp-readability-body .rp-readability-content h4,
            body.rp-readability-body .rp-readability-content h5,
            body.rp-readability-body .rp-readability-content h6 {
                color: #211b14 !important;
                font-family: "New York", "Iowan Old Style", "Songti SC", "STSong", Georgia, serif !important;
            }
            body.rp-readability-body .rp-readability-byline,
            body.rp-readability-body .rp-readability-excerpt {
                color: #726752 !important;
            }
            body.rp-readability-body .rp-readability-content a,
            body:not(.rp-readability-body) a {
                color: #285f86 !important;
            }
            body.rp-readability-body .rp-readability-content p.rp-readability-prose-paragraph,
            body.rp-readability-body .rp-readability-content [data-rp-source='true'] {
                color: inherit !important;
            }
            body.rp-readability-body .rp-translation-block,
            body:not(.rp-readability-body) .rp-translation-block {
                color: #24533d !important;
            }
            body.rp-readability-body code,
            body.rp-readability-body pre {
                background: rgba(91, 67, 31, 0.10) !important;
                color: #2b261f !important;
            }
            body.rp-readability-body blockquote {
                border-color: rgba(87, 68, 37, 0.28) !important;
                color: #4d4436 !important;
            }
            body.rp-readability-body table,
            body.rp-readability-body th,
            body.rp-readability-body td {
                border-color: rgba(87, 68, 37, 0.24) !important;
            }
            body.rp-readability-body img,
            body.rp-readability-body video,
            body.rp-readability-body canvas,
            body.rp-readability-body svg {
                filter: sepia(0.08) saturate(0.96);
            }
            body.rp-readability-body .rp-note-anchor-target,
            body:not(.rp-readability-body) .rp-note-anchor-target {
                outline-color: rgba(36, 83, 61, 0.42) !important;
                background: rgba(36, 83, 61, 0.10) !important;
            }
            body:not(.rp-readability-body) {
                background: transparent !important;
                color: #2b261f !important;
            }
            """
        }
    }
}

struct HTMLReaderView: PlatformHTMLViewRepresentable {
    var fileURL: URL
    var attachmentID: UUID? = nil
    var displayMode: TranslationDisplayMode
    var displayAppearance: PDFDisplayAppearance = .defaultMode
    var fontSize: Double = HTMLReaderTypography.defaultFontSize
    var reloadToken: Int
    var initialScrollRatio: Double
    @Binding var scrollRatio: Double
    var segmentUpdate: HTMLTranslationSegmentUpdate?
    var noteNavigationRequest: NoteNavigationRequest? = nil
    var selectionAssistantHistoryAnchors: [SelectionAssistantHistoryAnchor] = []
    var selectionHighlightResetToken: Int = 0
    var nativeSelectionClearToken: Int = 0
    var onNoteSelectionChanged: ((NoteSelectionContext?) -> Void)? = nil
    var onSelectionAssistantDismissed: (() -> Void)? = nil
    var findRequest: DocumentFindRequest? = nil
    var onFindStatusChanged: ((DocumentFindStatus) -> Void)? = nil
    var sidenotes: [HTMLSidenote] = []
    var sidenoteLabels = HTMLSidenoteLabels()
    var renderSidenoteMarkdown: (String) -> String = HTMLSidenote.plainTextHTML
    var sidenoteFocusRequest: SidenoteFocusRequest? = nil
    var onSidenoteEvent: ((HTMLSidenoteEvent) -> Void)? = nil
    var onSidenoteFocusHandled: ((SidenoteFocusRequest) -> Void)? = nil

    #if os(macOS)
    func makeNSView(context: Context) -> WKWebView {
        makeView(context: context)
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        updateView(view, context: context)
    }
    #else
    func makeUIView(context: Context) -> WKWebView {
        makeView(context: context)
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        updateView(view, context: context)
    }
    #endif

    private func makeView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(context.coordinator, name: Coordinator.scrollMessageHandlerName)
        configuration.userContentController.add(context.coordinator, name: Coordinator.selectionMessageHandlerName)
        configuration.userContentController.add(context.coordinator, name: Coordinator.selectionResetMessageHandlerName)
        configuration.userContentController.add(context.coordinator, name: Coordinator.sidenoteMessageHandlerName)
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: Coordinator.mediaPreparationScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
        if !HTMLTeXRendering.userScript.isEmpty {
            configuration.userContentController.addUserScript(
                WKUserScript(
                    source: HTMLTeXRendering.userScript,
                    injectionTime: .atDocumentEnd,
                    forMainFrameOnly: true
                )
            )
        }
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: Coordinator.instrumentationScript,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
        )
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: Coordinator.sidenoteScript,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
        )
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: Coordinator.findScript,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
        )
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        applyHostDisplayAppearance(displayAppearance, to: view)
        return view
    }

    private func updateView(_ view: WKWebView, context: Context) {
        context.coordinator.attachmentID = attachmentID
        context.coordinator.displayMode = displayMode
        context.coordinator.displayAppearance = displayAppearance
        context.coordinator.fontSize = HTMLReaderTypography.clampFontSize(fontSize)
        context.coordinator.scrollRatio = $scrollRatio
        context.coordinator.onNoteSelectionChanged = onNoteSelectionChanged
        context.coordinator.onSelectionAssistantDismissed = onSelectionAssistantDismissed
        context.coordinator.selectionAssistantHistoryAnchors = selectionAssistantHistoryAnchors
        context.coordinator.findRequest = findRequest
        context.coordinator.onFindStatusChanged = onFindStatusChanged
        context.coordinator.sidenotes = sidenotes
        context.coordinator.sidenoteLabels = sidenoteLabels
        context.coordinator.renderSidenoteMarkdown = renderSidenoteMarkdown
        context.coordinator.sidenoteFocusRequest = sidenoteFocusRequest
        context.coordinator.onSidenoteEvent = onSidenoteEvent
        context.coordinator.onSidenoteFocusHandled = onSidenoteFocusHandled
        applyHostDisplayAppearance(displayAppearance, to: view)
        context.coordinator.clearSelectionHighlightIfNeeded(
            resetToken: selectionHighlightResetToken,
            in: view
        )
        context.coordinator.clearNativeSelectionIfNeeded(
            clearToken: nativeSelectionClearToken,
            in: view
        )

        let readAccessURL = fileURL.deletingLastPathComponent()
        if context.coordinator.loadedURL != fileURL {
            context.coordinator.requestLoad(
                fileURL: fileURL,
                readAccessURL: readAccessURL,
                reloadToken: reloadToken,
                preserveScrollPosition: false,
                targetScrollRatio: initialScrollRatio,
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
        context.coordinator.applyReaderTypography(to: view)
        context.coordinator.applyDisplayAppearance(to: view)
        context.coordinator.applySegmentUpdateIfNeeded(segmentUpdate, to: view)
        context.coordinator.applySelectionAssistantHistoryAnchors(to: view)
        context.coordinator.applySidenotes(to: view)
        context.coordinator.applySidenoteFocusIfNeeded(to: view)
        context.coordinator.applyNoteNavigationIfNeeded(noteNavigationRequest, to: view)
        context.coordinator.applyFindRequestIfNeeded(to: view)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            scrollRatio: $scrollRatio,
            onNoteSelectionChanged: onNoteSelectionChanged,
            onSelectionAssistantDismissed: onSelectionAssistantDismissed
        )
    }

    private func applyHostDisplayAppearance(_: PDFDisplayAppearance, to webView: WKWebView) {
        #if os(macOS)
        webView.appearance = NSAppearance(named: .aqua)
        webView.wantsLayer = true
        webView.setValue(false, forKey: "drawsBackground")
        webView.layer?.backgroundColor = NSColor.clear.cgColor
        if #available(macOS 12.0, *) {
            webView.underPageBackgroundColor = .clear
        }
        webView.enclosingScrollView?.drawsBackground = false
        #else
        webView.overrideUserInterfaceStyle = .light
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        #endif
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
        static let selectionResetMessageHandlerName = "rpSelectionReset"
        static let sidenoteMessageHandlerName = "rpSidenote"
        static let nativeSelectionClearScript = """
        (() => {
            const selection = window.getSelection();
            if (selection) { selection.removeAllRanges(); }
        })();
        """
        static let mediaPreparationScript = """
        (() => {
            if (window.__rpMediaPreparationInstalled) { return; }
            window.__rpMediaPreparationInstalled = true;

            const tuneImage = image => {
                if (!(image instanceof HTMLImageElement)) { return; }
                if (!image.hasAttribute('loading')) {
                    image.setAttribute('loading', 'lazy');
                }
                if (!image.hasAttribute('decoding')) {
                    image.setAttribute('decoding', 'async');
                }
            };

            const tuneMedia = media => {
                if (!(media instanceof HTMLMediaElement)) { return; }
                if ((media.getAttribute('preload') || '').toLowerCase() !== 'none') {
                    media.setAttribute('preload', 'none');
                }
            };

            const tuneNode = node => {
                if (!node || node.nodeType !== Node.ELEMENT_NODE) { return; }
                const element = node;
                if (element.tagName === 'IMG') {
                    tuneImage(element);
                } else if (element.tagName === 'VIDEO' || element.tagName === 'AUDIO') {
                    tuneMedia(element);
                }

                if (!element.querySelectorAll) { return; }
                element.querySelectorAll('img').forEach(tuneImage);
                element.querySelectorAll('video, audio').forEach(tuneMedia);
            };

            const pauseAllMedia = () => {
                document.querySelectorAll('video, audio').forEach(media => {
                    try {
                        media.pause();
                    } catch {}
                });
            };

            const installObserver = () => {
                const root = document.documentElement;
                if (!root) {
                    requestAnimationFrame(installObserver);
                    return;
                }

                tuneNode(root);
                const observer = new MutationObserver(mutations => {
                    mutations.forEach(mutation => {
                        mutation.addedNodes.forEach(tuneNode);
                        if (mutation.type === 'attributes') {
                            tuneNode(mutation.target);
                        }
                    });
                });
                observer.observe(root, {
                    childList: true,
                    subtree: true,
                    attributes: true,
                    attributeFilter: ['src', 'srcset', 'poster']
                });
            };

            document.addEventListener('DOMContentLoaded', () => tuneNode(document.documentElement), { once: true });
            document.addEventListener('visibilitychange', () => {
                if (document.hidden) {
                    pauseAllMedia();
                }
            });
            window.addEventListener('pagehide', pauseAllMedia);
            installObserver();
        })();
        """
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

            // Typeset TeX is reader-only DOM; anchors must match the saved document.
            const renderedMathSelector = '.\(HTMLTeXRendering.wrapperClass)';
            const isRenderedMathElement = element =>
                !!(element && element.matches && element.matches(renderedMathSelector));

            const translationDisplayCSS = `
                html[data-rp-display-mode='original'] .rp-translation-block { display: none !important; }
                html[data-rp-display-mode='translated'] [data-rp-source='true'] { display: none !important; }
                .rp-translation-block {
                    color: #1f4d3a;
                    display: block !important;
                    position: static !important;
                    clear: both;
                    height: auto !important;
                    min-height: 0 !important;
                    max-height: none !important;
                    overflow: visible !important;
                    white-space: normal !important;
                    word-break: break-word;
                    line-height: 1.55 !important;
                    margin-top: 0.25em;
                    box-sizing: border-box;
                }
                html[data-rp-display-mode='bilingual'] .rp-readability-content [data-rp-source='true'] {
                    margin-bottom: 0.25em !important;
                }
                .rp-readability-content [data-rp-source='true'] + .rp-translation-block {
                    font-size: inherit !important;
                    line-height: inherit !important;
                    margin-left: 0 !important;
                    margin-right: 0 !important;
                    margin-top: 0 !important;
                    margin-bottom: 1.1em !important;
                }
                .rp-translation-block:is(h1, h2, h3, h4, h5, h6) {
                    line-height: 1.45 !important;
                    margin-top: 0.35em !important;
                    margin-bottom: 0.75em !important;
                }
            `.trim();

            const readabilityLayoutRepairCSS = `
                \(HTMLLocalizer.readableProseLayoutCSS)
                \(HTMLLocalizer.readableProseColorCSS)
                body.rp-readability-body .rp-readability-content #readability-page-1 :not(svg, svg *, math, math *) {
                    position: static !important;
                    inset: auto !important;
                    transform: none !important;
                    translate: none !important;
                    rotate: none !important;
                    scale: none !important;
                }
                body.rp-readability-body .rp-readability-content #readability-page-1 :is(ul, ol) {
                    position: relative !important;
                }
                body.rp-readability-body .rp-readability-content #readability-page-1 :is(article, section, main, header, footer, aside, div) {
                    height: auto !important;
                    min-height: 0 !important;
                    max-height: none !important;
                    overflow: visible !important;
                }
                html[data-rp-page-padding-repair='true'] .rp-readability-content > #readability-page-1.page {
                    padding: 32px 28px 56px !important;
                    box-sizing: border-box;
                }
                @media (max-width: 720px) {
                    html[data-rp-page-padding-repair='true'] .rp-readability-content > #readability-page-1.page {
                        padding: 24px 18px 48px !important;
                    }
                }
            `.trim();

            const ensureTranslationDisplayStyle = () => {
                let style = document.getElementById('rp-translation-display-style');
                if (!style) {
                    style = document.createElement('style');
                    style.id = 'rp-translation-display-style';
                    (document.head || document.documentElement).appendChild(style);
                }
                if (style.textContent !== translationDisplayCSS) {
                    style.textContent = translationDisplayCSS;
                }
            };

            const ensureReadabilityLayoutRepairStyle = () => {
                let style = document.getElementById('rp-readability-layout-repair-style');
                if (!style) {
                    style = document.createElement('style');
                    style.id = 'rp-readability-layout-repair-style';
                    (document.head || document.documentElement).appendChild(style);
                }
                if (style.textContent !== readabilityLayoutRepairCSS) {
                    style.textContent = readabilityLayoutRepairCSS;
                }
            };

            const updateReadabilityLayoutRepair = () => {
                const style = document.getElementById('rp-readability-style');
                const css = style?.textContent || '';
                const hasOldPagePaddingReset =
                    /\\.rp-readability-content\\s+\\.page\\s*,\\s*\\.rp-readability-content\\s+\\.available-content\\s*\\{[^}]*padding\\s*:\\s*0\\s*!important/i.test(css);
                const hasReadabilityPage = !!document.querySelector('.rp-readability-content > #readability-page-1.page');

                if (hasOldPagePaddingReset && hasReadabilityPage) {
                    document.documentElement.setAttribute('data-rp-page-padding-repair', 'true');
                    ensureReadabilityLayoutRepairStyle();
                } else {
                    document.documentElement.removeAttribute('data-rp-page-padding-repair');
                }
            };

            const originalChildren = parent =>
                Array.from(parent?.children || []).filter(child =>
                    !isTranslationElement(child) && !isRenderedMathElement(child)
                );

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
                const renderedMath = closestMatching(element, renderedMathSelector);
                if (renderedMath) {
                    element = renderedMath.parentElement;
                }
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

            ensureTranslationDisplayStyle();
            ensureReadabilityLayoutRepairStyle();
            updateReadabilityLayoutRepair();

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

            if (!document.getElementById('rp-selection-assistant-highlight-style')) {
                const style = document.createElement('style');
                style.id = 'rp-selection-assistant-highlight-style';
                style.textContent = `
                    ::highlight(rp-assistant-selection) {
                        background-color: rgba(0, 122, 255, 0.24);
                        color: inherit;
                    }
                `;
                (document.head || document.documentElement).appendChild(style);
            }

            const preserveAssistantSelectionHighlight = range => {
                if (!range || !window.CSS?.highlights || typeof Highlight === 'undefined') { return; }
                try {
                    CSS.highlights.set('rp-assistant-selection', new Highlight(range.cloneRange()));
                } catch {}
            };

            window.__rpClearSelectionAssistantHighlight = () => {
                try { CSS.highlights?.delete('rp-assistant-selection'); } catch {}
            };

            if (!document.getElementById('rp-selection-assistant-history-style')) {
                const style = document.createElement('style');
                style.id = 'rp-selection-assistant-history-style';
                style.textContent = `
                    ::highlight(rp-assistant-history) {
                        background-color: rgba(0, 122, 255, 0.10);
                        text-decoration: underline rgba(0, 122, 255, 0.52) 1px;
                    }
                    .rp-assistant-history-fallback {
                        background: rgba(0, 122, 255, 0.055);
                        box-shadow: inset 0 -1px rgba(0, 122, 255, 0.42);
                        cursor: pointer;
                    }
                `;
                (document.head || document.documentElement).appendChild(style);
            }

            var assistantHistoryRanges = [];
            let assistantHistorySelectionGraceMilliseconds = 700;
            var assistantHistorySelectionGraceUntil = 0;
            const normalizedTextMap = (element, includeTranslations = false) => {
                const walker = document.createTreeWalker(
                    element,
                    NodeFilter.SHOW_TEXT,
                    {
                        acceptNode: node => {
                            const parent = node.parentElement;
                            if (!parent || (!includeTranslations && isTranslationElement(parent))) {
                                return NodeFilter.FILTER_REJECT;
                            }
                            return NodeFilter.FILTER_ACCEPT;
                        }
                    }
                );
                let text = '';
                const positions = [];
                let pendingSpace = null;
                while (walker.nextNode()) {
                    const node = walker.currentNode;
                    const value = node.nodeValue || '';
                    for (let offset = 0; offset < value.length; offset += 1) {
                        const character = value[offset];
                        if (/\\s/.test(character)) {
                            if (text && text[text.length - 1] !== ' ') {
                                pendingSpace = { node, offset };
                            }
                            continue;
                        }
                        if (pendingSpace) {
                            text += ' ';
                            positions.push(pendingSpace);
                            pendingSpace = null;
                        }
                        text += character;
                        positions.push({ node, offset });
                    }
                }
                return { text: text.trim(), positions };
            };

            const quoteRangeIn = (target, quote, includeTranslations = false) => {
                const normalizedQuote = normalizeText(quote);
                if (!target || !normalizedQuote) { return null; }
                const mapped = normalizedTextMap(target, includeTranslations);
                const start = mapped.text.indexOf(normalizedQuote);
                const end = start + normalizedQuote.length - 1;
                if (start < 0 || !mapped.positions[start] || !mapped.positions[end]) { return null; }
                const range = document.createRange();
                range.setStart(mapped.positions[start].node, mapped.positions[start].offset);
                range.setEnd(mapped.positions[end].node, mapped.positions[end].offset + 1);
                return range;
            };
            window.__rpQuoteRangeIn = quoteRangeIn;

            const isInSidenoteLayer = event => !!event.target?.closest?.('.rp-sidenote-layer');

            const assistantHistoryEntryAtPoint = (x, y) => {
                for (const item of assistantHistoryRanges) {
                    const containsPoint = Array.from(item.range.getClientRects()).some(rect =>
                        x >= rect.left && x <= rect.right && y >= rect.top && y <= rect.bottom
                    );
                    if (containsPoint) { return item; }
                }
                const fallback = document.elementFromPoint(x, y)?.closest?.('.rp-assistant-history-fallback');
                if (!fallback) { return null; }
                return assistantHistoryRanges.find(item => item.target === fallback) || null;
            };
            window.__rpAssistantHistoryEntryAtPoint = assistantHistoryEntryAtPoint;

            window.__rpSetSelectionAssistantHistory = entries => {
                try { CSS.highlights?.delete('rp-assistant-history'); } catch {}
                document.querySelectorAll('.rp-assistant-history-fallback').forEach(element =>
                    element.classList.remove('rp-assistant-history-fallback')
                );
                assistantHistoryRanges = [];
                const ranges = [];

                for (const entry of Array.isArray(entries) ? entries : []) {
                    const target = window.__rpResolveNoteAnchor(entry.htmlSelector);
                    const quote = normalizeText(entry.quote);
                    if (!target || !quote) { continue; }
                    const range = quoteRangeIn(target, quote);
                    if (range) {
                        ranges.push(range);
                        assistantHistoryRanges.push({ entry, range, target });
                    } else {
                        target.classList.add('rp-assistant-history-fallback');
                        const range = document.createRange();
                        range.selectNodeContents(target);
                        assistantHistoryRanges.push({ entry, range, target });
                    }
                }

                if (window.CSS?.highlights && typeof Highlight !== 'undefined' && ranges.length > 0) {
                    try { CSS.highlights.set('rp-assistant-history', new Highlight(...ranges)); } catch {}
                } else {
                    assistantHistoryRanges.forEach(item => item.target.classList.add('rp-assistant-history-fallback'));
                }
            };

            document.addEventListener('pointerdown', event => {
                if (event.button !== 0 || isInSidenoteLayer(event)) { return; }
                if (assistantHistoryEntryAtPoint(event.clientX, event.clientY)) {
                    assistantHistorySelectionGraceUntil = Date.now() + assistantHistorySelectionGraceMilliseconds;
                    return;
                }
                window.__rpClearSelectionAssistantHighlight();
                window.webkit.messageHandlers.rpSelectionReset.postMessage(null);
            }, true);

            document.addEventListener('click', event => {
                if (isInSidenoteLayer(event)) { return; }
                const item = assistantHistoryEntryAtPoint(event.clientX, event.clientY);
                if (!item) { return; }
                assistantHistorySelectionGraceUntil = Date.now() + assistantHistorySelectionGraceMilliseconds;
                event.preventDefault();
                event.stopPropagation();
                window.webkit.messageHandlers.rpSelection.postMessage({
                    quote: item.entry.quote,
                    selector: item.entry.htmlSelector,
                    localContext: normalizeText(item.target.textContent).slice(0, 8000)
                });
            }, true);

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
                    if (Date.now() < assistantHistorySelectionGraceUntil) { return; }
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

                if (selection.rangeCount > 0) {
                    preserveAssistantSelectionHighlight(selection.getRangeAt(0));
                }

                const semanticSelector = '[data-rp-segment-id],p,h1,h2,h3,h4,h5,h6,figcaption,blockquote,li';
                const candidates = Array.from(document.querySelectorAll(semanticSelector))
                    .filter(element => !isTranslationElement(element));
                const contextIndex = candidates.indexOf(anchorElement);
                const contextElements = contextIndex >= 0
                    ? candidates.slice(Math.max(0, contextIndex - 1), Math.min(candidates.length, contextIndex + 2))
                    : [anchorElement];
                const localContext = contextElements
                    .filter(Boolean)
                    .map(element => normalizeText(element.textContent))
                    .filter(Boolean)
                    .join('\\n\\n')
                    .slice(0, 8000);

                window.webkit.messageHandlers.rpSelection.postMessage({ quote, selector, localContext });
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

        /// In-document find support. Swift owns matching (shared with PDF find);
        /// this script only snapshots visible text nodes and paints matches with
        /// the CSS Custom Highlight API so the DOM, and therefore note anchors,
        /// stay untouched.
        static let findScript = """
        (() => {
            if (window.__rpFindInstalled) { return; }
            window.__rpFindInstalled = true;

            const skippedSelector = 'script,style,noscript,template,textarea,select,annotation,annotation-xml';
            const blockSelector = [
                'address', 'article', 'aside', 'blockquote', 'body', 'caption', 'dd', 'details', 'div', 'dl', 'dt',
                'figcaption', 'figure', 'footer', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'header', 'li', 'main', 'nav',
                'ol', 'p', 'pre', 'section', 'summary', 'table', 'td', 'th', 'tr', 'ul', '.rp-translation-block'
            ].join(',');
            let nodes = [];
            let ranges = [];
            let currentIndex = -1;

            const supportsHighlights = () =>
                !!(window.CSS && CSS.highlights && typeof Highlight !== 'undefined');

            if (!document.getElementById('rp-find-style')) {
                const style = document.createElement('style');
                style.id = 'rp-find-style';
                style.textContent = `
                    ::highlight(rp-find) {
                        background-color: rgba(255, 204, 0, 0.42);
                        color: inherit;
                    }
                    ::highlight(rp-find-current) {
                        background-color: rgba(255, 149, 0, 0.78);
                        color: inherit;
                    }
                `;
                (document.head || document.documentElement).appendChild(style);
            }

            const isVisible = (element, cache) => {
                if (cache.has(element)) { return cache.get(element); }
                let visible = element.getClientRects().length > 0;
                if (visible) {
                    const style = window.getComputedStyle(element);
                    visible = style.visibility !== 'hidden' && style.visibility !== 'collapse';
                }
                cache.set(element, visible);
                return visible;
            };

            window.__rpFindCollect = () => {
                nodes = [];
                ranges = [];
                currentIndex = -1;
                const segments = [];
                const breaks = [];
                const root = document.body;
                if (!root) { return JSON.stringify({ segments, breaks }); }

                const visibility = new Map();
                const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
                    acceptNode: node => {
                        const parent = node.parentElement;
                        if (!node.data || !parent || parent.closest(skippedSelector)) {
                            return NodeFilter.FILTER_REJECT;
                        }
                        return isVisible(parent, visibility) ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT;
                    }
                });

                let lastBlock = null;
                while (walker.nextNode()) {
                    const node = walker.currentNode;
                    const block = node.parentElement.closest(blockSelector);
                    breaks.push(nodes.length > 0 && block !== lastBlock);
                    lastBlock = block;
                    nodes.push(node);
                    segments.push(node.data);
                }
                return JSON.stringify({ segments, breaks });
            };

            const paint = () => {
                if (!supportsHighlights()) { return; }
                try {
                    const all = new Highlight();
                    ranges.forEach((range, index) => {
                        if (range && index !== currentIndex) { all.add(range); }
                    });
                    CSS.highlights.set('rp-find', all);
                    const current = ranges[currentIndex];
                    if (current) {
                        const highlight = new Highlight(current);
                        highlight.priority = 1;
                        CSS.highlights.set('rp-find-current', highlight);
                    } else {
                        CSS.highlights.delete('rp-find-current');
                    }
                } catch {}
            };

            const reveal = range => {
                if (!range) { return; }
                const rect = range.getBoundingClientRect();
                if (!rect || (rect.width === 0 && rect.height === 0)) {
                    range.startContainer.parentElement?.scrollIntoView({ block: 'center', inline: 'nearest' });
                } else {
                    const margin = window.innerHeight * 0.15;
                    if (rect.top < margin || rect.bottom > window.innerHeight - margin) {
                        window.scrollTo({ top: window.scrollY + rect.top - window.innerHeight / 3, behavior: 'auto' });
                    }
                }
                if (!supportsHighlights()) {
                    const element = range.startContainer.parentElement;
                    element?.classList.add('rp-note-anchor-target');
                    window.setTimeout(() => element?.classList.remove('rp-note-anchor-target'), 1400);
                }
            };

            const firstIndexFromViewport = () => {
                for (let index = 0; index < ranges.length; index += 1) {
                    const range = ranges[index];
                    if (range && range.getBoundingClientRect().bottom >= 0) { return index; }
                }
                return ranges.findIndex(Boolean);
            };

            window.__rpFindSetMatches = (matches, mode, preferredIndex) => {
                ranges = matches.map(match => {
                    const start = nodes[match[0]];
                    const end = nodes[match[2]];
                    if (!start || !end || !start.isConnected || !end.isConnected) { return null; }
                    try {
                        const range = document.createRange();
                        range.setStart(start, Math.min(match[1], start.length));
                        range.setEnd(end, Math.min(match[3], end.length));
                        return range;
                    } catch {
                        return null;
                    }
                });
                if (ranges.length === 0) {
                    currentIndex = -1;
                } else if (mode === 'keep') {
                    currentIndex = Math.min(Math.max(0, preferredIndex), ranges.length - 1);
                } else {
                    currentIndex = firstIndexFromViewport();
                    reveal(ranges[currentIndex]);
                }
                paint();
                return String(currentIndex);
            };

            window.__rpFindFocus = index => {
                if (index < 0 || index >= ranges.length) { return; }
                currentIndex = index;
                paint();
                reveal(ranges[currentIndex]);
            };

            window.__rpFindClear = () => {
                nodes = [];
                ranges = [];
                currentIndex = -1;
                try {
                    CSS.highlights?.delete('rp-find');
                    CSS.highlights?.delete('rp-find-current');
                } catch {}
            };
        })();
        """

        /// Margin notes ("sidenotes"). Cards live in a layer appended to
        /// `<html>`, outside `<body>`, so `rp-anchor:` paths, find, and the
        /// saved document stay untouched; quotes are painted with the CSS
        /// Custom Highlight API. Wide readers move the reading column left and
        /// align each note with its anchor; narrow readers open a note as a
        /// popover when its highlighted quote is clicked.
        static let sidenoteScript = """
        (() => {
            if (window.__rpSidenotesInstalled) { return; }
            window.__rpSidenotesInstalled = true;

            const columnGap = 36;
            const minColumnWidth = 200;
            const maxColumnWidth = 280;
            const minTextWidth = 480;
            const edgeInset = 16;
            const cardSpacing = 10;
            const popoverWidth = 340;
            const updateDelayMilliseconds = 350;
            const pendingDraftTimeoutMilliseconds = 5000;

            const cards = new Map();
            const updateTimers = new Map();
            let labels = {};
            let layer = null;
            let mode = 'none';
            let modeKey = null;
            let columnWidth = 0;
            let editingID = null;
            let openID = null;
            let activeID = null;
            let layoutFrame = null;

            const post = payload => {
                try { window.webkit?.messageHandlers?.rpSidenote?.postMessage(payload); } catch {}
            };

            const ensureStyle = () => {
                if (document.getElementById('rp-sidenote-style')) { return; }
                const style = document.createElement('style');
                style.id = 'rp-sidenote-style';
                style.textContent = `
                    html[data-rp-sidenote-reserved] body {
                        padding-right: calc(
                            var(--rp-sidenote-base-padding, 0px) + var(--rp-sidenote-reserve, 0px)
                        ) !important;
                    }
                    ::highlight(rp-note) {
                        background-color: rgba(230, 170, 60, 0.14);
                        text-decoration: underline rgba(196, 128, 32, 0.62) 1.5px;
                    }
                    ::highlight(rp-note-active) {
                        background-color: rgba(230, 170, 60, 0.32);
                    }
                    .rp-sidenote-layer {
                        position: absolute;
                        top: 0;
                        left: 0;
                        width: 0;
                        height: 0;
                        z-index: 20;
                    }
                    .rp-sidenote {
                        position: absolute;
                        box-sizing: border-box;
                        margin: 0;
                        padding: 6px 26px 8px 26px;
                        border-radius: 8px;
                        font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", "PingFang SC", sans-serif;
                        font-size: calc(var(--rp-reader-font-size, 17px) * 0.8);
                        line-height: 1.55;
                        color: #6e6a64;
                        text-align: left;
                        cursor: text;
                        -webkit-font-smoothing: antialiased;
                    }
                    .rp-sidenote.is-hidden,
                    html:not([data-rp-sidenotes='margin']) .rp-sidenote:not(.is-open) {
                        display: none;
                    }
                    .rp-sidenote:hover,
                    .rp-sidenote.is-active {
                        background: rgba(120, 96, 60, 0.06);
                    }
                    .rp-sidenote.is-editing {
                        background: rgba(255, 255, 255, 0.94);
                        box-shadow: 0 0 0 1px rgba(0, 0, 0, 0.08), 0 4px 14px rgba(0, 0, 0, 0.06);
                        color: #2f2b26;
                    }
                    .rp-sidenote.is-open {
                        background: #fffdf8;
                        box-shadow: 0 0 0 1px rgba(0, 0, 0, 0.08), 0 10px 30px rgba(0, 0, 0, 0.16);
                        color: #3a3530;
                    }
                    .rp-sidenote.is-flash {
                        animation: rp-sidenote-flash 0.9s ease;
                    }
                    @keyframes rp-sidenote-flash {
                        from { background: rgba(214, 150, 40, 0.24); }
                    }
                    .rp-sidenote-number {
                        position: absolute;
                        left: 8px;
                        top: 6px;
                        font-size: 0.85em;
                        font-weight: 600;
                        color: #b5782a;
                        font-variant-numeric: tabular-nums;
                        user-select: none;
                        -webkit-user-select: none;
                    }
                    .rp-sidenote-delete {
                        position: absolute;
                        top: 4px;
                        right: 4px;
                        width: 20px;
                        height: 20px;
                        padding: 0;
                        border: 0;
                        border-radius: 5px;
                        background: transparent;
                        color: inherit;
                        font: 15px/20px -apple-system, sans-serif;
                        opacity: 0;
                        cursor: pointer;
                    }
                    .rp-sidenote:hover .rp-sidenote-delete,
                    .rp-sidenote.is-editing .rp-sidenote-delete,
                    .rp-sidenote.is-open .rp-sidenote-delete {
                        opacity: 0.55;
                    }
                    .rp-sidenote .rp-sidenote-delete:hover {
                        opacity: 1;
                        background: rgba(0, 0, 0, 0.06);
                    }
                    .rp-sidenote-body[hidden],
                    .rp-sidenote-editor[hidden] {
                        display: none;
                    }
                    .rp-sidenote-body > :first-child { margin-top: 0; }
                    .rp-sidenote-body > :last-child { margin-bottom: 0; }
                    .rp-sidenote-body :is(p, ul, blockquote, pre) {
                        margin: 0 0 0.5em;
                    }
                    .rp-sidenote-body :is(h1, h2, h3, h4, h5, h6) {
                        margin: 0 0 0.35em;
                        font-size: 1em;
                        font-weight: 600;
                        color: #4a453f;
                    }
                    .rp-sidenote-body ul { padding-left: 1.1em; }
                    .rp-sidenote-body blockquote {
                        margin-left: 0;
                        padding-left: 0.7em;
                        border-left: 2px solid rgba(0, 0, 0, 0.12);
                    }
                    .rp-sidenote-body code {
                        font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
                        font-size: 0.92em;
                        background: rgba(0, 0, 0, 0.05);
                        border-radius: 3px;
                        padding: 0 0.2em;
                    }
                    .rp-sidenote-body pre {
                        white-space: pre-wrap;
                        background: rgba(0, 0, 0, 0.04);
                        border-radius: 5px;
                        padding: 0.4em 0.5em;
                    }
                    .rp-sidenote-body pre code { background: none; padding: 0; }
                    .rp-sidenote-body a { color: #285f86; }
                    .rp-sidenote-body.is-empty { font-style: italic; opacity: 0.7; }
                    .rp-sidenote-body.is-pending { white-space: pre-wrap; }
                    .rp-sidenote-editor {
                        display: block;
                        box-sizing: border-box;
                        width: 100%;
                        min-height: 1.55em;
                        margin: 0;
                        padding: 0;
                        border: 0;
                        outline: none;
                        resize: none;
                        overflow: hidden;
                        background: transparent;
                        color: inherit;
                        font: inherit;
                        line-height: inherit;
                    }
                    html[data-rp-reader-appearance='paper'] .rp-sidenote {
                        font-family: "New York", "Iowan Old Style", "Songti SC", "STSong", Georgia, serif;
                        color: #726752;
                    }
                    html[data-rp-reader-appearance='paper'] .rp-sidenote:is(.is-editing, .is-open) {
                        background: #fbf6ea;
                        color: #2b261f;
                    }
                `;
                (document.head || document.documentElement).appendChild(style);
            };

            const ensureLayer = () => {
                if (layer && layer.isConnected) { return layer; }
                layer = document.createElement('div');
                layer.className = 'rp-sidenote-layer';
                document.documentElement.appendChild(layer);
                cards.forEach(entry => layer.appendChild(entry.card));
                return layer;
            };

            const translationBlockFor = target => {
                const segmentID = target?.getAttribute?.('data-rp-segment-id');
                if (!segmentID) { return null; }
                return document.querySelector(
                    `.rp-translation-block[data-rp-source-segment-id="${CSS.escape(segmentID)}"]`
                );
            };

            // Inline anchors (links, emphasis) do not show where the text column ends.
            const textBlockFor = element => {
                let current = element;
                while (current && current !== document.body &&
                       getComputedStyle(current).display.startsWith('inline')) {
                    current = current.parentElement;
                }
                return current;
            };

            const resolveAnchor = entry => {
                const target = window.__rpResolveNoteAnchor?.(entry.note.htmlSelector) || null;
                const quoteRangeIn = window.__rpQuoteRangeIn;
                entry.target = target;
                entry.block = textBlockFor(target);
                entry.range = null;
                if (!target || !quoteRangeIn || !entry.note.quote) { return; }
                entry.range = quoteRangeIn(target, entry.note.quote);
                if (!entry.range) {
                    const translation = translationBlockFor(target);
                    if (translation) {
                        entry.range = quoteRangeIn(translation, entry.note.quote, true);
                    }
                }
            };

            const anchorNeedsResolution = entry =>
                !entry.target || !entry.target.isConnected ||
                (entry.note.quote && (!entry.range || entry.range.collapsed));

            const firstVisibleRect = rects => {
                for (const rect of rects) {
                    if (rect.width > 0 || rect.height > 0) { return rect; }
                }
                return null;
            };

            const anchorRects = entry => {
                const fromRange = entry.range ? Array.from(entry.range.getClientRects()) : [];
                if (firstVisibleRect(fromRange)) { return fromRange.filter(rect => rect.width > 0 || rect.height > 0); }
                for (const element of [entry.target, translationBlockFor(entry.target)]) {
                    const rect = element ? firstVisibleRect(element.getClientRects()) : null;
                    if (rect) { return [rect]; }
                }
                return [];
            };

            const paintHighlights = () => {
                if (!window.CSS?.highlights || typeof Highlight === 'undefined') { return; }
                try {
                    const ranges = Array.from(cards.values()).map(entry => entry.range).filter(Boolean);
                    if (ranges.length > 0) {
                        CSS.highlights.set('rp-note', new Highlight(...ranges));
                    } else {
                        CSS.highlights.delete('rp-note');
                    }
                    const activeRange = activeID ? cards.get(activeID)?.range : null;
                    if (activeRange) {
                        const highlight = new Highlight(activeRange);
                        highlight.priority = 1;
                        CSS.highlights.set('rp-note-active', highlight);
                    } else {
                        CSS.highlights.delete('rp-note-active');
                    }
                } catch {}
            };

            const setActive = id => {
                if (activeID === id) { return; }
                cards.get(activeID)?.card.classList.remove('is-active');
                activeID = id;
                cards.get(id)?.card.classList.add('is-active');
                paintHighlights();
            };

            const renderBody = entry => {
                const { note, body } = entry;
                const isDraftPending = entry.draft !== null &&
                    entry.draft !== note.markdown &&
                    Date.now() - entry.draftCommittedAt < pendingDraftTimeoutMilliseconds;
                if (isDraftPending) {
                    body.classList.add('is-pending');
                    body.classList.remove('is-empty');
                    body.textContent = entry.draft;
                    entry.renderedHTML = null;
                    return;
                }
                entry.draft = null;
                body.classList.remove('is-pending');
                const isEmpty = !note.markdown.trim();
                body.classList.toggle('is-empty', isEmpty);
                if (isEmpty) {
                    body.textContent = labels.placeholder || '';
                    entry.renderedHTML = null;
                } else if (entry.renderedHTML !== note.html) {
                    body.innerHTML = note.html;
                    entry.renderedHTML = note.html;
                }
            };

            const autosize = editor => {
                editor.style.height = 'auto';
                editor.style.height = `${editor.scrollHeight}px`;
            };

            const flushUpdate = (id, isFinal) => {
                clearTimeout(updateTimers.get(id));
                updateTimers.delete(id);
                const entry = cards.get(id);
                if (!entry || entry.draft === null) { return; }
                post({ action: isFinal ? 'commit' : 'update', id, body: entry.draft });
            };

            const scheduleUpdate = id => {
                clearTimeout(updateTimers.get(id));
                updateTimers.set(id, setTimeout(() => flushUpdate(id, false), updateDelayMilliseconds));
            };

            const beginEditing = id => {
                const entry = cards.get(id);
                if (!entry) { return false; }
                if (editingID && editingID !== id) { finishEditing(editingID); }
                if (editingID !== id) {
                    editingID = id;
                    entry.card.classList.add('is-editing');
                    entry.editor.value = entry.draft ?? entry.note.markdown;
                    entry.body.hidden = true;
                    entry.editor.hidden = false;
                }
                entry.editor.placeholder = labels.editorPlaceholder || '';
                autosize(entry.editor);
                setActive(id);
                if (document.activeElement !== entry.editor) {
                    entry.editor.focus({ preventScroll: true });
                    const end = entry.editor.value.length;
                    entry.editor.setSelectionRange(end, end);
                }
                layout();
                return true;
            };

            const finishEditing = id => {
                if (editingID !== id) { return; }
                const entry = cards.get(id);
                editingID = null;
                if (!entry) { return; }
                if (entry.draft !== null) {
                    entry.draftCommittedAt = Date.now();
                    flushUpdate(id, true);
                }
                entry.card.classList.remove('is-editing');
                entry.editor.hidden = true;
                entry.body.hidden = false;
                if (document.activeElement === entry.editor) { entry.editor.blur(); }
                renderBody(entry);
                setActive(openID);
                scheduleLayout();
            };

            const openPopover = id => {
                if (openID && openID !== id) { closePopover(); }
                openID = id;
                setActive(id);
                layout();
            };

            const closePopover = () => {
                if (!openID) { return; }
                const id = openID;
                openID = null;
                finishEditing(id);
                setActive(null);
                scheduleLayout();
            };

            const flash = entry => {
                entry.card.classList.remove('is-flash');
                void entry.card.offsetWidth;
                entry.card.classList.add('is-flash');
                window.setTimeout(() => entry.card.classList.remove('is-flash'), 900);
            };

            const makeEntry = id => {
                const card = document.createElement('aside');
                card.className = 'rp-sidenote';
                card.dataset.noteId = id;
                const number = document.createElement('span');
                number.className = 'rp-sidenote-number';
                const remove = document.createElement('button');
                remove.type = 'button';
                remove.className = 'rp-sidenote-delete';
                remove.textContent = '×';
                const body = document.createElement('div');
                body.className = 'rp-sidenote-body';
                const editor = document.createElement('textarea');
                editor.className = 'rp-sidenote-editor';
                editor.rows = 1;
                editor.hidden = true;
                card.append(number, remove, body, editor);

                const entry = {
                    id, card, number, remove, body, editor,
                    note: null, target: null, block: null, range: null,
                    draft: null, draftCommittedAt: 0, renderedHTML: null
                };

                card.addEventListener('mouseenter', () => setActive(id));
                card.addEventListener('mouseleave', () => setActive(editingID || openID));
                card.addEventListener('click', event => {
                    if (event.target.closest('a, .rp-sidenote-delete')) { return; }
                    beginEditing(id);
                });
                remove.addEventListener('click', event => {
                    event.stopPropagation();
                    post({ action: 'delete', id });
                });
                editor.addEventListener('input', () => {
                    entry.draft = editor.value;
                    autosize(editor);
                    scheduleUpdate(id);
                    scheduleLayout();
                });
                editor.addEventListener('keydown', event => {
                    if (event.key === 'Escape' || (event.key === 'Enter' && (event.metaKey || event.ctrlKey))) {
                        event.preventDefault();
                        if (openID === id) {
                            closePopover();
                        } else {
                            finishEditing(id);
                        }
                    }
                });
                editor.addEventListener('blur', () => {
                    if (editingID !== id) { return; }
                    // Switching windows blurs the editor too; keep editing and just save.
                    if (!document.hasFocus()) {
                        flushUpdate(id, true);
                        return;
                    }
                    finishEditing(id);
                });
                return entry;
            };

            const textRightEdge = anchored => {
                let right = -Infinity;
                for (const entry of anchored) {
                    for (const element of [entry.block, translationBlockFor(entry.target)]) {
                        const rect = element?.getBoundingClientRect();
                        if (rect && rect.width > 0) { right = Math.max(right, rect.right); }
                    }
                }
                if (right > -Infinity) { return right; }
                return (document.querySelector('.rp-readability-shell') || document.body).getBoundingClientRect().right;
            };

            const setReserve = value => {
                const root = document.documentElement;
                const reserve = Math.max(0, Math.round(value));
                root.style.setProperty('--rp-sidenote-reserve', `${reserve}px`);
                if (reserve > 0) {
                    root.setAttribute('data-rp-sidenote-reserved', 'true');
                } else {
                    root.removeAttribute('data-rp-sidenote-reserved');
                }
                return reserve;
            };

            // Finds the smallest right padding on <body> that leaves room for the
            // note column beside the text. Pages that already have room are not
            // changed; pages that cap or center their body only give up the width
            // that is missing. Depending on the page, the text moves 1:1 (left
            // aligned), 1:2 (centered), or only past some threshold (capped
            // content-box body), so each step rescales by the observed shift and
            // grows the step while nothing moves. Returns false when the text
            // column would get too narrow.
            const solveReserve = (anchored, viewportWidth) => {
                setReserve(0);
                document.documentElement.style.setProperty(
                    '--rp-sidenote-base-padding',
                    getComputedStyle(document.body).paddingRight
                );
                const required = columnWidth + columnGap + edgeInset;
                const maximumReserve = viewportWidth * 0.6;
                const deficit = () => required - (viewportWidth - textRightEdge(anchored));
                let reserve = 0;
                let missing = deficit();
                let shiftPerPixel = 1;
                for (let attempt = 0; attempt < 8; attempt += 1) {
                    if (missing <= 0.5 && (missing > -2 || reserve === 0)) { break; }
                    const target = Math.min(maximumReserve, Math.max(0, reserve + missing / shiftPerPixel));
                    const nextReserve = setReserve(target);
                    if (nextReserve === reserve) { break; }
                    const nextMissing = deficit();
                    const moved = missing - nextMissing;
                    const change = nextReserve - reserve;
                    shiftPerPixel = Math.abs(moved) > 0.5 && moved / change > 0
                        ? moved / change
                        : shiftPerPixel / 2;
                    reserve = nextReserve;
                    missing = nextMissing;
                }
                const column = document.querySelector('.rp-readability-shell') || document.body;
                if (missing > 1 || column.getBoundingClientRect().width < minTextWidth) {
                    setReserve(0);
                    return false;
                }
                return true;
            };

            const readingAnchor = () => {
                if (window.scrollY <= 0) { return null; }
                const content = document.querySelector('.rp-readability-shell') || document.body;
                const contentRect = content?.getBoundingClientRect();
                if (!contentRect) { return null; }
                const x = Math.max(1, contentRect.left + Math.min(40, contentRect.width / 2));
                const y = Math.min(120, window.innerHeight / 4);
                const element = document.elementFromPoint(x, y);
                if (!element || element.closest('.rp-sidenote-layer')) { return null; }
                return { element, top: element.getBoundingClientRect().top };
            };

            // Re-measures only when something that moves the text column changed.
            const updateMode = (anchored, viewportWidth) => {
                const root = document.documentElement;
                const nextColumnWidth = Math.round(
                    Math.min(maxColumnWidth, Math.max(minColumnWidth, viewportWidth * 0.24))
                );
                const key = [
                    viewportWidth,
                    nextColumnWidth,
                    root.getAttribute('data-rp-display-mode') || '',
                    anchored.map(entry => entry.id).sort().join(',')
                ].join('|');
                if (key === modeKey) { return; }
                modeKey = key;

                const anchor = readingAnchor();
                columnWidth = nextColumnWidth;
                let nextMode = 'none';
                if (anchored.length > 0) {
                    nextMode = solveReserve(anchored, viewportWidth) ? 'margin' : 'compact';
                } else {
                    setReserve(0);
                }
                if (mode !== nextMode) {
                    mode = nextMode;
                    root.setAttribute('data-rp-sidenotes', nextMode);
                    if (nextMode !== 'compact' && openID) {
                        const id = openID;
                        openID = null;
                        cards.get(id)?.card.classList.remove('is-open');
                    }
                }
                if (anchor && anchor.element.isConnected) {
                    const delta = anchor.element.getBoundingClientRect().top - anchor.top;
                    if (Math.abs(delta) > 1) { window.scrollBy(0, delta); }
                }
            };

            const layout = () => {
                if (layoutFrame !== null) {
                    cancelAnimationFrame(layoutFrame);
                    layoutFrame = null;
                }
                if (!layer || !document.body) { return; }

                let highlightsChanged = false;
                cards.forEach(entry => {
                    if (anchorNeedsResolution(entry)) {
                        const previousRange = entry.range;
                        resolveAnchor(entry);
                        highlightsChanged = highlightsChanged || entry.range !== previousRange;
                    }
                });
                if (highlightsChanged) { paintHighlights(); }

                const viewportWidth = document.documentElement.clientWidth;
                const anchored = Array.from(cards.values()).filter(entry => entry.target);
                updateMode(anchored, viewportWidth);

                const origin = layer.getBoundingClientRect();
                const placed = [];
                cards.forEach(entry => {
                    const rects = entry.target ? anchorRects(entry) : [];
                    if (rects.length > 0) {
                        placed.push({ entry, rects });
                    } else {
                        entry.card.classList.add('is-hidden');
                        entry.card.classList.remove('is-open');
                    }
                });
                placed.sort((a, b) => (a.rects[0].top - b.rects[0].top) || (a.rects[0].left - b.rects[0].left));

                if (mode === 'margin') {
                    const textRight = textRightEdge(anchored);
                    const left = Math.min(textRight + columnGap, viewportWidth - columnWidth - edgeInset) - origin.left;
                    let cursor = -Infinity;
                    placed.forEach(({ entry, rects }, index) => {
                        entry.number.textContent = String(index + 1);
                        entry.card.classList.remove('is-hidden', 'is-open');
                        entry.card.style.width = `${columnWidth}px`;
                        entry.card.style.left = `${left}px`;
                        const top = Math.max(rects[0].top - origin.top - 6, cursor);
                        entry.card.style.top = `${top}px`;
                        cursor = top + entry.card.offsetHeight + cardSpacing;
                    });
                } else {
                    const width = Math.min(popoverWidth, viewportWidth - edgeInset * 2);
                    placed.forEach(({ entry, rects }, index) => {
                        entry.number.textContent = String(index + 1);
                        const isOpen = mode === 'compact' && entry.id === openID;
                        entry.card.classList.toggle('is-hidden', !isOpen);
                        entry.card.classList.toggle('is-open', isOpen);
                        if (!isOpen) { return; }
                        const rect = rects[rects.length - 1];
                        const left = Math.min(Math.max(rect.left, edgeInset), viewportWidth - width - edgeInset);
                        entry.card.style.width = `${width}px`;
                        entry.card.style.left = `${left - origin.left}px`;
                        entry.card.style.top = `${rect.bottom - origin.top + 8}px`;
                    });
                }
            };

            const scheduleLayout = () => {
                if (layoutFrame !== null) { return; }
                layoutFrame = requestAnimationFrame(() => {
                    layoutFrame = null;
                    layout();
                });
            };

            const entryAtPoint = (x, y) => {
                for (const entry of cards.values()) {
                    if (!entry.range) { continue; }
                    const hit = Array.from(entry.range.getClientRects()).some(rect =>
                        x >= rect.left && x <= rect.right && y >= rect.top && y <= rect.bottom
                    );
                    if (hit) { return entry; }
                }
                return null;
            };

            window.__rpSetSidenotes = (notes, nextLabels) => {
                labels = nextLabels || {};
                ensureStyle();
                ensureLayer();
                const seen = new Set();
                for (const note of Array.isArray(notes) ? notes : []) {
                    seen.add(note.id);
                    let entry = cards.get(note.id);
                    if (!entry) {
                        entry = makeEntry(note.id);
                        cards.set(note.id, entry);
                        layer.appendChild(entry.card);
                    }
                    const anchorChanged = !entry.note ||
                        entry.note.htmlSelector !== note.htmlSelector ||
                        entry.note.quote !== note.quote;
                    entry.note = note;
                    if (anchorChanged) { resolveAnchor(entry); }
                    entry.remove.title = labels.delete || '';
                    entry.remove.setAttribute('aria-label', labels.delete || '');
                    if (editingID === note.id) {
                        entry.editor.placeholder = labels.editorPlaceholder || '';
                    } else {
                        renderBody(entry);
                    }
                }
                for (const [id, entry] of Array.from(cards.entries())) {
                    if (seen.has(id)) { continue; }
                    clearTimeout(updateTimers.get(id));
                    updateTimers.delete(id);
                    if (editingID === id) { editingID = null; }
                    if (openID === id) { openID = null; }
                    if (activeID === id) { activeID = null; }
                    entry.card.remove();
                    cards.delete(id);
                }
                paintHighlights();
                layout();
            };

            window.__rpFocusSidenote = id => {
                const entry = cards.get(id);
                if (!entry) { return false; }
                layout();
                if (!entry.target) { return false; }
                if (mode === 'compact') { openPopover(id); }
                beginEditing(id);
                const rect = entry.card.getBoundingClientRect();
                if (rect.top < 0 || rect.bottom > window.innerHeight) {
                    entry.card.scrollIntoView({ block: 'nearest' });
                }
                return true;
            };

            // Lays out synchronously, then reports positions; used by tests.
            window.__rpSidenoteState = () => (layout(), {
                mode,
                editingID,
                openID,
                cards: Array.from(cards.values()).map(entry => {
                    const rect = entry.card.getBoundingClientRect();
                    const anchor = entry.target ? anchorRects(entry)[0] : null;
                    return {
                        id: entry.id,
                        number: entry.number.textContent,
                        visible: rect.width > 0 && rect.height > 0,
                        hasRange: !!entry.range,
                        left: rect.left,
                        top: rect.top,
                        bottom: rect.bottom,
                        anchorTop: anchor ? anchor.top : null,
                        text: entry.body.textContent,
                        html: entry.body.innerHTML
                    };
                })
            });

            window.__rpLayoutSidenotes = scheduleLayout;

            document.addEventListener('click', event => {
                if (event.button !== 0 || event.target?.closest?.('.rp-sidenote-layer')) { return; }
                const selection = window.getSelection();
                if (selection && !selection.isCollapsed) { return; }
                const entry = entryAtPoint(event.clientX, event.clientY);
                if (mode === 'compact') {
                    if (entry) {
                        openPopover(entry.id);
                    } else {
                        closePopover();
                    }
                } else if (mode === 'margin' && entry) {
                    flash(entry);
                }
            });
            document.addEventListener('keydown', event => {
                if (event.key === 'Escape' && openID && !editingID) { closePopover(); }
            });
            window.addEventListener('resize', scheduleLayout);
            window.addEventListener('load', scheduleLayout);
            document.fonts?.ready?.then(scheduleLayout);
            if (typeof ResizeObserver !== 'undefined' && document.body) {
                new ResizeObserver(scheduleLayout).observe(document.body);
            }
            new MutationObserver(scheduleLayout).observe(document.documentElement, {
                attributes: true,
                attributeFilter: ['data-rp-display-mode']
            });
        })();
        """

        var loadedURL: URL?
        var loadedReloadToken: Int?
        var attachmentID: UUID?
        var displayMode: TranslationDisplayMode = .bilingual
        var displayAppearance: PDFDisplayAppearance = .defaultMode
        var fontSize: Double = HTMLReaderTypography.defaultFontSize
        var scrollRatio: Binding<Double>
        var onNoteSelectionChanged: ((NoteSelectionContext?) -> Void)?
        var onSelectionAssistantDismissed: (() -> Void)?
        var selectionAssistantHistoryAnchors: [SelectionAssistantHistoryAnchor] = []
        var sidenotes: [HTMLSidenote] = []
        var sidenoteLabels = HTMLSidenoteLabels()
        var renderSidenoteMarkdown: (String) -> String = HTMLSidenote.plainTextHTML
        var sidenoteFocusRequest: SidenoteFocusRequest?
        var onSidenoteEvent: ((HTMLSidenoteEvent) -> Void)?
        var onSidenoteFocusHandled: ((SidenoteFocusRequest) -> Void)?
        private var appliedSidenotes: [HTMLSidenote]?
        private var appliedSidenoteLabels: HTMLSidenoteLabels?
        private var renderedSidenoteHTML: [UUID: (markdown: String, html: String)] = [:]
        private var lastHandledSidenoteFocusID: UUID?
        private var currentRequest: LoadRequest?
        private var pendingRequest: LoadRequest?
        private var pendingScrollRatio: Double?
        private var pendingSegmentUpdates: [HTMLTranslationSegmentUpdate] = []
        private var lastAppliedSegmentSequence: Int?
        private var pendingNoteNavigationRequest: NoteNavigationRequest?
        private var lastAppliedNoteNavigationID: UUID?
        private var lastPublishedNoteSelection: NoteSelectionContext?
        private var lastSelectionHighlightResetToken = 0
        private var lastNativeSelectionClearToken = 0
        private var lastSelectionAssistantHistorySignature: String?
        private var isLoading = false
        private var isDocumentReady = false
        var findRequest: DocumentFindRequest?
        var onFindStatusChanged: ((DocumentFindStatus) -> Void)?
        private var findText: DocumentSearchSegmentedText?
        private var findTextGeneration = 0
        private var isCollectingFindText = false
        private var findTextDisplayMode: TranslationDisplayMode?
        private var appliedFindRequest: DocumentFindRequest?
        private var findResultsNeedRefresh = false
        private var findMatchCount = 0
        private var currentFindMatchIndex: Int?
        private var lastPublishedFindStatus: DocumentFindStatus?

        init(
            scrollRatio: Binding<Double>,
            onNoteSelectionChanged: ((NoteSelectionContext?) -> Void)?,
            onSelectionAssistantDismissed: (() -> Void)?
        ) {
            self.scrollRatio = scrollRatio
            self.onNoteSelectionChanged = onNoteSelectionChanged
            self.onSelectionAssistantDismissed = onSelectionAssistantDismissed
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
            lastSelectionAssistantHistorySignature = nil
            appliedSidenotes = nil
            isLoading = false
            isDocumentReady = false
            invalidateFindText(keepingPosition: false)
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
            lastSelectionAssistantHistorySignature = nil
            appliedSidenotes = nil
            invalidateFindText(keepingPosition: request.preserveScrollPosition)
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

        func applyReaderTypography(to webView: WKWebView) {
            runJavaScript(
                """
                (() => {
                    const css = `
                        \(HTMLReaderTypography.css(fontSize: fontSize))
                    `.trim();
                    let style = document.getElementById('rp-reader-typography-style');
                    if (!style) {
                        style = document.createElement('style');
                        style.id = 'rp-reader-typography-style';
                        (document.head || document.documentElement).appendChild(style);
                    }
                    if (style.textContent !== css) {
                        style.textContent = css;
                    }
                })();
                """,
                in: webView
            )
        }

        func applyDisplayAppearance(to webView: WKWebView) {
            guard let appearanceValue = javaScriptStringLiteral(displayAppearance.rawValue),
                  let cssValue = javaScriptStringLiteral(displayAppearance.htmlReaderCSS) else {
                return
            }

            runJavaScript(
                """
                (() => {
                    const appearance = \(appearanceValue);
                    const css = \(cssValue);
                    document.documentElement.setAttribute('data-rp-reader-appearance', appearance);

                    const styleID = 'rp-reader-appearance-style';
                    let style = document.getElementById(styleID);
                    if (!css) {
                        if (style) {
                            style.remove();
                        }
                        return;
                    }

                    if (!style) {
                        style = document.createElement('style');
                        style.id = styleID;
                        (document.head || document.documentElement).appendChild(style);
                    }
                    if (style.textContent !== css) {
                        style.textContent = css;
                    }
                })();
                """,
                in: webView
            )
        }

        @MainActor
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isDocumentReady = true
            applyDisplayMode(to: webView)
            applyReaderTypography(to: webView)
            applyDisplayAppearance(to: webView)
            applySelectionAssistantHistoryAnchors(to: webView)
            applySidenotes(to: webView)
            restoreScrollRatioIfNeeded(in: webView)
            flushPendingSegmentUpdates(in: webView)
            flushPendingNoteNavigationIfNeeded(in: webView)
            applySidenoteFocusIfNeeded(to: webView)
            finishLoadIfNeeded(in: webView)
            applyFindRequestIfNeeded(to: webView)
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
            #if os(macOS)
            NSWorkspace.shared.open(url)
            #else
            UIApplication.shared.open(url)
            #endif
            decisionHandler(.cancel)
        }

        @MainActor
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
            case Self.scrollMessageHandlerName:
                handleScrollMessage(message)
            case Self.selectionMessageHandlerName:
                handleSelectionMessage(message)
            case Self.selectionResetMessageHandlerName:
                publishNoteSelection(nil)
                onSelectionAssistantDismissed?()
            case Self.sidenoteMessageHandlerName:
                handleSidenoteMessage(message)
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
                document.querySelectorAll(\(translationSelector)).forEach(node => window.__rpRenderTeX?.(node));
                window.__rpLayoutSidenotes?.();
            })();
            """
            runJavaScript(script, in: webView)
            lastAppliedSegmentSequence = update.sequence
            invalidateFindText(keepingPosition: true)
        }

        func applyFindRequestIfNeeded(to webView: WKWebView) {
            guard let request = findRequest, DocumentSearchQuery(request.query).isEmpty == false else {
                clearFind(in: webView)
                return
            }
            guard isDocumentReady, isLoading == false else {
                publishFindStatus(.searching(request))
                return
            }
            if findTextDisplayMode != displayMode {
                findTextDisplayMode = displayMode
                invalidateFindText(keepingPosition: true)
            }
            guard let findText else {
                collectFindText(in: webView)
                publishFindStatus(.searching(request))
                return
            }

            let isNewSearch = findResultsNeedRefresh ||
                appliedFindRequest?.query != request.query ||
                appliedFindRequest?.options != request.options
            if isNewSearch {
                let isRefresh = findResultsNeedRefresh &&
                    appliedFindRequest?.query == request.query &&
                    appliedFindRequest?.options == request.options
                findResultsNeedRefresh = false
                appliedFindRequest = request
                showFindMatches(
                    findText.matches(of: request.query, options: request.options),
                    for: request,
                    keepingCurrentMatch: isRefresh,
                    in: webView
                )
            } else if appliedFindRequest?.navigationToken != request.navigationToken {
                appliedFindRequest = request
                guard findMatchCount > 0 else { return }
                let step = request.navigationDirection == .forward ? 1 : -1
                let current = currentFindMatchIndex ?? (step > 0 ? -1 : 0)
                let nextIndex = (current + step + findMatchCount) % findMatchCount
                currentFindMatchIndex = nextIndex
                runJavaScript("window.__rpFindFocus?.(\(nextIndex));", in: webView)
                publishFindResults(for: request)
            }
        }

        private func showFindMatches(
            _ matches: [DocumentSearchSegmentedText.SegmentMatch],
            for request: DocumentFindRequest,
            keepingCurrentMatch: Bool,
            in webView: WKWebView
        ) {
            findMatchCount = matches.count
            let payload = matches.map { [$0.start.segment, $0.start.offset, $0.end.segment, $0.end.offset] }
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let json = String(data: data, encoding: .utf8) else {
                return
            }
            let mode = keepingCurrentMatch ? "keep" : "viewport"
            let preferredIndex = currentFindMatchIndex ?? 0
            let generation = findTextGeneration
            let script = "window.__rpFindSetMatches ? window.__rpFindSetMatches(\(json), '\(mode)', \(preferredIndex)) : '-1';"
            webView.evaluateJavaScript(script) { [weak self] result, _ in
                let index = (result as? String).flatMap(Int.init) ?? -1
                Task { @MainActor in
                    guard let self,
                          generation == self.findTextGeneration,
                          self.appliedFindRequest?.query == request.query,
                          self.appliedFindRequest?.options == request.options
                    else {
                        return
                    }
                    self.currentFindMatchIndex = index >= 0 ? index : nil
                    self.publishFindResults(for: request)
                }
            }
        }

        private func collectFindText(in webView: WKWebView) {
            guard isCollectingFindText == false else { return }
            isCollectingFindText = true
            let generation = findTextGeneration
            webView.evaluateJavaScript("window.__rpFindCollect ? window.__rpFindCollect() : null") { [weak self, weak webView] result, _ in
                let json = result as? String
                Task { @MainActor in
                    let findText = await Task.detached(priority: .userInitiated) {
                        Self.makeFindText(fromJSON: json)
                    }.value
                    guard let self, let webView, generation == self.findTextGeneration else { return }
                    self.isCollectingFindText = false
                    self.findText = findText
                    self.applyFindRequestIfNeeded(to: webView)
                }
            }
        }

        private nonisolated static func makeFindText(fromJSON json: String?) -> DocumentSearchSegmentedText {
            struct Snapshot: Decodable {
                var segments: [String]
                var breaks: [Bool]
            }
            guard let data = json?.data(using: .utf8),
                  let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else {
                return DocumentSearchSegmentedText(segments: [], breaksBefore: [])
            }
            return DocumentSearchSegmentedText(segments: snapshot.segments, breaksBefore: snapshot.breaks)
        }

        private func invalidateFindText(keepingPosition: Bool) {
            findTextGeneration += 1
            findText = nil
            isCollectingFindText = false
            // Re-run the same search on the new text without jumping away from
            // the reader's position (e.g. while translation blocks stream in);
            // a different document starts a fresh search from the viewport.
            if keepingPosition == false {
                appliedFindRequest = nil
                currentFindMatchIndex = nil
            }
            findResultsNeedRefresh = appliedFindRequest != nil
        }

        private func clearFind(in webView: WKWebView) {
            guard appliedFindRequest != nil || findText != nil || isCollectingFindText else { return }
            findTextGeneration += 1
            findText = nil
            isCollectingFindText = false
            appliedFindRequest = nil
            findResultsNeedRefresh = false
            findMatchCount = 0
            currentFindMatchIndex = nil
            lastPublishedFindStatus = nil
            runJavaScript("window.__rpFindClear?.();", in: webView)
        }

        private func publishFindResults(for request: DocumentFindRequest) {
            publishFindStatus(DocumentFindStatus(
                query: request.query,
                options: request.options,
                matchCount: findMatchCount,
                currentIndex: currentFindMatchIndex,
                isSearching: false
            ))
        }

        private func publishFindStatus(_ status: DocumentFindStatus) {
            guard lastPublishedFindStatus != status else { return }
            lastPublishedFindStatus = status
            // Defer so SwiftUI state is not mutated during a view update.
            Task { @MainActor [weak self] in
                self?.onFindStatusChanged?(status)
            }
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

        func applySelectionAssistantHistoryAnchors(to webView: WKWebView) {
            guard isDocumentReady, isLoading == false else { return }
            let matchingAnchors = selectionAssistantHistoryAnchors.filter {
                $0.attachmentID == nil || $0.attachmentID == attachmentID
            }
            guard let data = try? JSONEncoder().encode(matchingAnchors),
                  let json = String(data: data, encoding: .utf8) else { return }
            let signature = Hashing.sha256Hex(json)
            guard signature != lastSelectionAssistantHistorySignature else { return }
            runJavaScript(
                "window.__rpSetSelectionAssistantHistory?.(\(json));",
                in: webView
            )
            lastSelectionAssistantHistorySignature = signature
        }

        func applySidenotes(to webView: WKWebView) {
            guard isDocumentReady, isLoading == false else { return }
            guard appliedSidenotes != sidenotes || appliedSidenoteLabels != sidenoteLabels else { return }

            struct Payload: Encodable {
                let id: String
                let quote: String
                let htmlSelector: String
                let markdown: String
                let html: String
            }
            let payload = sidenotes.map { sidenote in
                Payload(
                    id: sidenote.id.uuidString,
                    quote: sidenote.quote,
                    htmlSelector: sidenote.htmlSelector,
                    markdown: sidenote.markdown,
                    html: renderedHTML(for: sidenote)
                )
            }
            renderedSidenoteHTML = renderedSidenoteHTML.filter { id, _ in
                sidenotes.contains { $0.id == id }
            }
            let encoder = JSONEncoder()
            guard let notesData = try? encoder.encode(payload),
                  let labelsData = try? encoder.encode(sidenoteLabels),
                  let notesJSON = String(data: notesData, encoding: .utf8),
                  let labelsJSON = String(data: labelsData, encoding: .utf8) else {
                return
            }
            runJavaScript("window.__rpSetSidenotes?.(\(notesJSON), \(labelsJSON));", in: webView)
            appliedSidenotes = sidenotes
            appliedSidenoteLabels = sidenoteLabels
        }

        func applySidenoteFocusIfNeeded(to webView: WKWebView) {
            guard let request = sidenoteFocusRequest,
                  request.id != lastHandledSidenoteFocusID,
                  isDocumentReady,
                  isLoading == false,
                  appliedSidenotes?.contains(where: { $0.id == request.noteID }) == true,
                  let idLiteral = javaScriptStringLiteral(request.noteID.uuidString) else {
                return
            }
            lastHandledSidenoteFocusID = request.id
            runJavaScript("window.__rpFocusSidenote?.(\(idLiteral));", in: webView)
            // Defer so SwiftUI state is not mutated during a view update.
            Task { @MainActor [weak self] in
                self?.onSidenoteFocusHandled?(request)
            }
        }

        private func renderedHTML(for sidenote: HTMLSidenote) -> String {
            if let cached = renderedSidenoteHTML[sidenote.id], cached.markdown == sidenote.markdown {
                return cached.html
            }
            let html = renderSidenoteMarkdown(sidenote.markdown)
            renderedSidenoteHTML[sidenote.id] = (sidenote.markdown, html)
            return html
        }

        private func handleSidenoteMessage(_ message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let action = body["action"] as? String,
                  let noteID = (body["id"] as? String).flatMap(UUID.init(uuidString:)) else {
                return
            }
            switch action {
            case "update", "commit":
                guard let text = body["body"] as? String else { return }
                onSidenoteEvent?(.bodyChanged(noteID: noteID, body: text, isFinal: action == "commit"))
            case "delete":
                onSidenoteEvent?(.deleteRequested(noteID: noteID))
            default:
                return
            }
        }

        func clearSelectionHighlightIfNeeded(resetToken: Int, in webView: WKWebView) {
            guard resetToken != lastSelectionHighlightResetToken else { return }
            lastSelectionHighlightResetToken = resetToken
            runJavaScript("window.__rpClearSelectionAssistantHighlight?.();", in: webView)
        }

        func clearNativeSelectionIfNeeded(clearToken: Int, in webView: WKWebView) {
            guard clearToken != lastNativeSelectionClearToken else { return }
            lastNativeSelectionClearToken = clearToken
            runJavaScript(Self.nativeSelectionClearScript, in: webView)
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
                htmlSelector: body["selector"] as? String,
                localContext: body["localContext"] as? String
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
