import Foundation

/// App-injected script only: reports the paper's own text on screen once scrolling
/// settles, so past reading can echo it. Translations, hidden regions and typeset math
/// are left out.
enum HTMLReadingFocus {
    static let messageHandlerName = "rpReadingFocus"
    /// Characters reported at most.
    static let textLimit = 4000

    static let script = #"""
    (() => {
        if (window.__rpReadingFocusInstalled) { return; }
        window.__rpReadingFocusInstalled = true;
        const blocks = 'p,li,h1,h2,h3,h4,h5,h6,blockquote,figcaption,dd,dt,td,th,pre';
        const excluded = '.rp-translation-block,[data-rp-translation="true"],[data-rp-region-hidden="true"],nav,script,style,[hidden]';
        let timer = null, last = '';
        const visibleText = () => {
            const height = window.innerHeight;
            const parts = [];
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
                parts.push(text);
                length += text.length + 1;
                if (length > \#(textLimit)) { break; }
            }
            return parts.join('\n').slice(0, \#(textLimit));
        };
        const report = () => {
            timer = null;
            const text = visibleText();
            if (text === last) { return; }
            last = text;
            window.webkit?.messageHandlers?.rpReadingFocus?.postMessage({ documentURL: location.href, text });
        };
        const schedule = () => {
            if (timer) { clearTimeout(timer); }
            timer = setTimeout(report, 500);
        };
        window.addEventListener('scroll', schedule, { passive: true });
        window.addEventListener('resize', schedule, { passive: true });
        schedule();
    })();
    """#
}
