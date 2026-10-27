import Foundation

/// App-injected script only. It reads the DOM and reuses the reader's stable rp-anchor paths.
enum HTMLDocumentOutline {
    static let messageHandlerName = "rpOutline"
    static let script = #"""
    (() => {
        let headings = [], lastEntries = '', lastCurrent = '', scheduled = false, needsRebuild = true;
        const excluded = '.rp-translation-block,.rp-tex-math,[data-rp-region-hidden="true"],script,style,nav';
        const translationFor = element => {
            const id = element.getAttribute('data-rp-segment-id');
            if (id) {
                const block = document.querySelector('.rp-translation-block[data-rp-source-segment-id="' + CSS.escape(id) + '"]');
                if (block) return block;
            }
            return element.nextElementSibling?.classList.contains('rp-translation-block') ? element.nextElementSibling : null;
        };
        const visibleTarget = heading => {
            if (heading.element.getClientRects().length) return heading.element;
            const translation = translationFor(heading.element);
            return translation?.getClientRects().length ? translation : null;
        };
        const rebuild = () => {
            headings = Array.from(document.querySelectorAll('h1,h2,h3,h4,h5,h6')).filter(element => {
                return !element.closest(excluded) && !element.closest('[hidden]');
            }).map(element => {
                const clone = element.cloneNode(true);
                clone.querySelectorAll('.rp-translation-block,.rp-tex-math,script,style').forEach(node => node.remove());
                const anchor = window.__rpBuildNoteAnchor?.(element);
                const title = (clone.textContent || '').replace(/\s+/g, ' ').trim();
                const translation = translationFor(element)?.textContent?.replace(/\s+/g, ' ').trim() || null;
                return { element, entry: { id: anchor, anchor, title, translation, level: Number(element.tagName.slice(1)) } };
            }).filter(item => item.entry.anchor && item.entry.title && visibleTarget(item));
            // h1 is often a single document title; normalize a document starting at h2 to level 1.
            const minimum = Math.min(6, ...headings.map(item => item.entry.level));
            headings.forEach(item => item.entry.level -= minimum - 1);
        };
        const publish = () => {
            scheduled = false;
            if (needsRebuild) { rebuild(); needsRebuild = false; }
            let current = null;
            for (const heading of headings) {
                const target = visibleTarget(heading);
                if (target && target.getBoundingClientRect().top <= Math.min(120, window.innerHeight * 0.22)) current = heading.entry.id;
            }
            if (!current && headings.length) current = headings[0].entry.id;
            const entries = headings.map(item => item.entry);
            const serialized = JSON.stringify(entries);
            if (serialized === lastEntries && current === lastCurrent) return;
            window.webkit?.messageHandlers?.rpOutline?.postMessage({
                documentURL: location.href, entries: serialized !== lastEntries ? entries : null, currentID: current
            });
            lastEntries = serialized; lastCurrent = current;
        };
        const schedule = rebuild => {
            needsRebuild = needsRebuild || rebuild;
            if (!scheduled) { scheduled = true; requestAnimationFrame(publish); }
        };
        window.addEventListener('scroll', () => schedule(false), { passive: true });
        window.addEventListener('resize', () => schedule(true), { passive: true });
        window.addEventListener('load', () => schedule(true));
        let mutationTimer;
        new MutationObserver(() => {
            clearTimeout(mutationTimer);
            mutationTimer = setTimeout(() => schedule(true), 100);
        }).observe(document.body, { childList: true, subtree: true, characterData: true, attributes: true,
            attributeFilter: ['data-rp-region-hidden', 'data-rp-segment-id', 'class', 'style', 'hidden'] });
        schedule(true);
    })();
    """#
}
