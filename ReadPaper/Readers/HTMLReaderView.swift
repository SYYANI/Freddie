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
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: Coordinator.mediaPreparationScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: Coordinator.instrumentationScript,
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
        context.coordinator.applyNoteNavigationIfNeeded(noteNavigationRequest, to: view)
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

            ensureTranslationDisplayStyle();
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
            const normalizedTextMap = element => {
                const walker = document.createTreeWalker(
                    element,
                    NodeFilter.SHOW_TEXT,
                    {
                        acceptNode: node => {
                            const parent = node.parentElement;
                            if (!parent || isTranslationElement(parent)) {
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
                    const mapped = normalizedTextMap(target);
                    const start = mapped.text.indexOf(quote);
                    const end = start + quote.length - 1;
                    if (start >= 0 && mapped.positions[start] && mapped.positions[end]) {
                        const range = document.createRange();
                        range.setStart(mapped.positions[start].node, mapped.positions[start].offset);
                        range.setEnd(mapped.positions[end].node, mapped.positions[end].offset + 1);
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
                if (event.button !== 0) { return; }
                if (assistantHistoryEntryAtPoint(event.clientX, event.clientY)) {
                    assistantHistorySelectionGraceUntil = Date.now() + assistantHistorySelectionGraceMilliseconds;
                    return;
                }
                window.__rpClearSelectionAssistantHighlight();
                window.webkit.messageHandlers.rpSelectionReset.postMessage(null);
            }, true);

            document.addEventListener('click', event => {
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
            lastSelectionAssistantHistorySignature = nil
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
            let clampedFontSize = Int(HTMLReaderTypography.clampFontSize(fontSize).rounded())
            runJavaScript(
                """
                (() => {
                    const css = `
                        :root { --rp-reader-font-size: \(clampedFontSize)px; }
                        body.rp-readability-body .rp-readability-content {
                            font-size: var(--rp-reader-font-size) !important;
                        }
                        body.rp-readability-body .rp-readability-content p.rp-readability-prose-paragraph,
                        body.rp-readability-body .rp-readability-content [data-rp-source='true'],
                        body.rp-readability-body .rp-readability-content .rp-translation-block {
                            font-size: var(--rp-reader-font-size) !important;
                        }
                        body.rp-readability-body .rp-readability-title {
                            font-size: calc(var(--rp-reader-font-size) * 1.9) !important;
                        }
                        body.rp-readability-body .rp-readability-byline,
                        body.rp-readability-body .rp-readability-excerpt {
                            font-size: calc(var(--rp-reader-font-size) * 0.95) !important;
                        }
                        body:not(.rp-readability-body) {
                            font-size: var(--rp-reader-font-size);
                        }
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
