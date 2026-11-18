import Foundation

/// App-injected script only. Reports the paper's own paragraphs on screen once scrolling
/// settles, so past reading can echo them (translations, hidden regions and typeset math
/// are left out), and draws the marks beside paragraphs that have echoes. The marks live
/// in a layer under `<html>`, outside `<body>`, so `rp-anchor` paths, find and selection
/// never see them.
enum HTMLReadingFocus {
    static let messageHandlerName = "rpReadingFocus"
    /// A click on a mark: `{ id, x, y, width, height }` in viewport coordinates.
    static let markMessageHandlerName = "rpEchoMark"
    /// Characters reported at most.
    static let textLimit = 4000

    /// JavaScript that shows `marks` (`[{ id, label, seen }]`), replacing the previous ones.
    static func setMarksScript(_ marks: [[String: Any]]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: marks)) ?? Data("[]".utf8)
        let json = String(decoding: data, as: UTF8.self)
        return "window.__rpSetEchoMarks && window.__rpSetEchoMarks(\(json)); true;"
    }

    static let script = #"""
    (() => {
        if (window.__rpReadingFocusInstalled) { return; }
        window.__rpReadingFocusInstalled = true;
        const blocks = 'p,li,h1,h2,h3,h4,h5,h6,blockquote,figcaption,dd,dt,td,th,pre';
        const excluded = '.rp-translation-block,[data-rp-translation="true"],[data-rp-region-hidden="true"],nav,script,style,[hidden]';
        let timer = null, last = '';
        const visibleBlocks = () => {
            const height = window.innerHeight;
            const found = [];
            let length = 0, seenVisible = false;
            for (const element of document.body?.querySelectorAll(blocks) || []) {
                // The innermost block holds the text; its ancestors would repeat it.
                if (element.querySelector(blocks) || element.closest(excluded)) { continue; }
                const rect = element.getBoundingClientRect();
                if (rect.height === 0 && rect.width === 0) { continue; }
                if (rect.bottom < 0) { continue; }
                if (rect.top > height) { if (seenVisible) { break; } continue; }
                seenVisible = true;
                const clone = element.cloneNode(true);
                clone.querySelectorAll('.rp-tex-math,.rp-translation-block,script,style').forEach(node => node.remove());
                const text = (clone.textContent || '').replace(/\s+/g, ' ').trim();
                if (!text) { continue; }
                const id = window.__rpBuildNoteAnchor?.(element) || ('rp-block:' + found.length);
                found.push({ id, text });
                length += text.length + 1;
                if (length > \#(textLimit)) { break; }
            }
            return found;
        };
        const report = () => {
            timer = null;
            const found = visibleBlocks();
            const text = found.map(block => block.text).join('\n').slice(0, \#(textLimit));
            if (text === last) { return; }
            last = text;
            window.webkit?.messageHandlers?.rpReadingFocus?.postMessage({ documentURL: location.href, text, blocks: found });
        };
        const schedule = () => {
            if (timer) { clearTimeout(timer); }
            timer = setTimeout(report, 500);
        };
        window.addEventListener('scroll', schedule, { passive: true });
        window.addEventListener('resize', schedule, { passive: true });
        schedule();

        // Marks beside paragraphs with echoes: a small ripple in the margin.
        const style = document.createElement('style');
        style.textContent = `
            #rp-echo-layer { position: absolute; left: 0; top: 0; width: 0; height: 0; z-index: 2147482000; pointer-events: none; }
            .rp-echo-mark { position: absolute; width: 18px; height: 18px; margin: 0; padding: 0; border: 0;
                background: transparent; cursor: pointer; pointer-events: auto; opacity: 0.7;
                transition: opacity .18s ease, transform .18s ease; -webkit-user-select: none; user-select: none; }
            .rp-echo-mark::before { content: ''; position: absolute; left: 6px; top: 6px; width: 6px; height: 6px;
                border-radius: 50%; background: rgb(10, 132, 255); }
            .rp-echo-mark::after { content: ''; position: absolute; left: 2px; top: 2px; width: 12px; height: 12px;
                border-radius: 50%; border: 1px solid rgba(10, 132, 255, 0.45); }
            .rp-echo-mark:hover { opacity: 1; transform: scale(1.18); }
            .rp-echo-mark[data-seen="true"] { opacity: 0.3; }
            .rp-echo-mark[data-seen="true"]:hover { opacity: 0.8; }
            @media print { #rp-echo-layer { display: none; } }
        `;
        let layer = null, marks = [];
        const ensureLayer = () => {
            if (layer && layer.isConnected) { return layer; }
            (document.head || document.documentElement).appendChild(style);
            layer = document.createElement('div');
            layer.id = 'rp-echo-layer';
            layer.setAttribute('data-freddie-reader-ui', 'true');
            document.documentElement.appendChild(layer);
            return layer;
        };
        const place = (node, element) => {
            const rect = element.getBoundingClientRect();
            if (rect.width === 0 && rect.height === 0) { node.style.display = 'none'; return; }
            node.style.display = '';
            const lineHeight = parseFloat(getComputedStyle(element).lineHeight) || 20;
            const top = rect.top + window.scrollY + Math.min(rect.height, lineHeight) / 2 - 9;
            // The left margin when there is room, else the right one, else just inside.
            let left = rect.left - 26;
            if (left < 2) {
                left = rect.right + 8 + 18 <= document.documentElement.clientWidth ? rect.right + 8 : rect.left + 2;
            }
            node.style.top = top + 'px';
            node.style.left = (left + window.scrollX) + 'px';
        };
        const layout = () => {
            for (const mark of marks) {
                const element = window.__rpResolveNoteAnchor?.(mark.id);
                if (element) { place(mark.node, element); } else { mark.node.style.display = 'none'; }
            }
        };
        window.__rpSetEchoMarks = list => {
            const target = ensureLayer();
            target.replaceChildren();
            marks = (list || []).map(item => {
                const node = document.createElement('button');
                node.type = 'button';
                node.className = 'rp-echo-mark';
                node.dataset.seen = item.seen ? 'true' : 'false';
                node.title = item.label || '';
                node.setAttribute('aria-label', item.label || '');
                node.addEventListener('mousedown', event => { event.preventDefault(); event.stopPropagation(); });
                node.addEventListener('click', event => {
                    event.preventDefault();
                    event.stopPropagation();
                    const rect = node.getBoundingClientRect();
                    window.webkit?.messageHandlers?.rpEchoMark?.postMessage({
                        id: item.id, x: rect.left, y: rect.top, width: rect.width, height: rect.height
                    });
                });
                target.appendChild(node);
                return { id: item.id, node };
            });
            layout();
        };
        window.addEventListener('resize', layout, { passive: true });
        if (typeof ResizeObserver !== 'undefined' && document.body) {
            new ResizeObserver(() => { if (marks.length) { layout(); } }).observe(document.body);
        }
    })();
    """#
}
