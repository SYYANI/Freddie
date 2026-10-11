import Foundation

/// In-reader editing of an imported page's regions: hovering outlines the block under the
/// pointer, ↑/↓ grow or shrink the outline to the parent or child block, a click hides the
/// region (or restores a hidden one, which edit mode shows faded), and a Shift-click applies
/// the last click's change to every region in between.
///
/// The script only toggles `HTMLRegionVisibility.hiddenAttribute` on existing elements and
/// draws its outlines in a layer outside `<body>`, so `rp-anchor:` paths stay valid. Each
/// edit is reported as `HTMLRegionChange` values that the host applies to `paper.html`.
/// It relies on `__rpBuildNoteAnchor` and `__rpOriginalChildren` from the reader's
/// instrumentation script, so region paths and note anchors follow the same rules.
enum HTMLRegionEditing {
    static let messageHandlerName = "rpRegionEdit"

    static let script = """
    (() => {
        if (window.__rpRegionEditInstalled) { return; }
        window.__rpRegionEditInstalled = true;

        const css = \(javaScriptStringLiteral(stylesheet));
        const hiddenAttribute = '\(HTMLRegionVisibility.hiddenAttribute)';
        const editingAttribute = '\(HTMLRegionVisibility.editingAttribute)';
        const hiddenSelector = `[${hiddenAttribute}="true"]`;
        const translationSelector = '.rp-translation-block,[data-rp-translation="true"]';
        const sourceSelector = '[data-rp-source="true"]';
        const renderedMathSelector = '.\(HTMLTeXRendering.wrapperClass)';
        const readerLayerSelector = '.rp-sidenote-layer, .rp-region-edit-layer';
        const rootSelector = '.rp-readability-shell, .rp-readability-content, #readability-page-1';
        const nonVisualSelector = 'script, style, link, meta, title, base, template, noscript';
        const uncountedSelector = `${translationSelector}, ${nonVisualSelector}, annotation, annotation-xml`;
        const textInputSelector = 'input, textarea, select, [contenteditable=""], [contenteditable="true"]';
        const imageSelector = 'img, picture, svg, canvas';
        const mediaSelector = 'video, audio, iframe, embed, object';
        const signatureChildLimit = 16;
        const badgeHeight = 22;
        const outlineInset = 3;
        // A wrapper this close to the box of what it wraps adds no visible step.
        const sameBoundsTolerance = 2;
        const summaryLength = 80;

        let enabled = false;
        let labels = {};
        let layer = null;
        let box = null;
        let parentBox = null;
        let actionLabel = null;
        let kindLabel = null;
        let roots = new Set();
        // Outline steps under the pointer, innermost first; see `levelsFor`.
        let levels = [];
        let selected = null;
        let pointer = null;
        let frame = null;
        let flashTimer = null;
        let undoStack = [];
        let redoStack = [];
        // The last single edit: Shift-clicking another region applies its change to everything between.
        let rangeAnchor = null;
        let shiftHeld = false;
        let rangeCache = null;
        // Bumped when hidden regions or the layout change, which invalidates `rangeCache`.
        let generation = 0;
        let textLengths = new WeakMap();

        const post = payload => {
            try { window.webkit?.messageHandlers?.\(messageHandlerName)?.postMessage(JSON.stringify(payload)); } catch {}
        };

        const ensureStyle = () => {
            if (document.getElementById('rp-region-edit-style')) { return; }
            const style = document.createElement('style');
            style.id = 'rp-region-edit-style';
            style.textContent = css;
            (document.head || document.documentElement).appendChild(style);
        };

        const ensureLayer = () => {
            if (layer && layer.isConnected) { return; }
            layer = document.createElement('div');
            layer.className = 'rp-region-edit-layer';
            parentBox = document.createElement('div');
            parentBox.className = 'rp-region-edit-parent';
            box = document.createElement('div');
            box.className = 'rp-region-edit-box';
            const badge = document.createElement('div');
            badge.className = 'rp-region-edit-badge';
            actionLabel = document.createElement('span');
            actionLabel.className = 'rp-region-edit-action';
            kindLabel = document.createElement('span');
            badge.append(actionLabel, kindLabel);
            box.appendChild(badge);
            layer.append(parentBox, box);
            document.documentElement.appendChild(layer);
        };

        const pathFor = element => window.__rpBuildNoteAnchor?.(element) || null;
        const childrenFor = element => window.__rpOriginalChildren?.(element) || [];
        const tagFor = element => (element.localName || '').toLowerCase();
        const isHidden = element => element?.getAttribute?.(hiddenAttribute) === 'true';
        const hiddenRegionCount = () => document.querySelectorAll(hiddenSelector).length;

        // Must match `HTMLAnchorPath.signature(of:)`.
        const signatureFor = element => {
            const children = childrenFor(element);
            return [
                tagFor(element),
                element.getAttribute('id') || '',
                String(children.length),
                children.slice(0, signatureChildLimit).map(tagFor).join(',')
            ].join('|');
        };

        // Sources count even when the translated display mode hides them.
        const isVisualChild = element =>
            !element.matches(nonVisualSelector) &&
            (element.getClientRects().length > 0 || element.matches(sourceSelector));

        // Wrappers spanning the whole article cannot be hidden: <body>, the Readability
        // shell, and any element that is the only visible child of one of them.
        const computeRoots = () => {
            const result = new Set([document.documentElement, document.body].filter(Boolean));
            document.querySelectorAll(rootSelector).forEach(element => result.add(element));
            for (const root of Array.from(result)) {
                let current = root;
                for (;;) {
                    const visible = childrenFor(current).filter(isVisualChild);
                    if (visible.length !== 1) { break; }
                    current = visible[0];
                    result.add(current);
                }
            }
            return result;
        };

        // Maps reader-only DOM (typeset TeX, translation blocks) to the saved element it shows.
        const editableElementFor = node => {
            let element = node?.nodeType === Node.ELEMENT_NODE ? node : node?.parentElement;
            if (!element || element.closest(readerLayerSelector)) { return null; }
            const math = element.closest(renderedMathSelector);
            if (math) { element = math.parentElement; }
            const translation = element?.closest(translationSelector);
            if (translation) {
                const segmentID = translation.getAttribute('data-rp-source-segment-id');
                const source = segmentID
                    ? document.querySelector(`[data-rp-segment-id="${CSS.escape(segmentID)}"]`)
                    : null;
                element = source || translation.parentElement;
            }
            return element || null;
        };

        // Innermost first, up to (not including) the first root.
        const chainFor = element => {
            const result = [];
            for (let current = element; current && !roots.has(current); current = current.parentElement) {
                result.push(current);
            }
            return result;
        };

        // 'block', 'inline', or null when an element cannot be outlined: it has no box, or it is
        // a table part, since hiding one cell or row would only break the table. Sources are
        // blocks even when the translated display mode shows only their translation.
        const layoutOf = element => {
            if (element.matches(sourceSelector)) { return 'block'; }
            const display = getComputedStyle(element).display;
            if (display === 'none' || display === 'contents' || display.startsWith('table-')) { return null; }
            return display.startsWith('inline') ? 'inline' : 'block';
        };

        const outermostHiddenIndex = list => {
            for (let index = list.length - 1; index >= 0; index -= 1) {
                if (isHidden(list[index])) { return index; }
            }
            return -1;
        };

        // Inside a hidden region only the region itself (to restore it) or an ancestor can be picked.
        const candidatesIn = list => {
            const hiddenIndex = outermostHiddenIndex(list);
            return list.slice(Math.max(0, hiddenIndex))
                .filter((element, index) => (hiddenIndex >= 0 && index === 0) || layoutOf(element) !== null);
        };

        const visibleRects = element =>
            Array.from(element?.getClientRects() || []).filter(rect => rect.width > 0 || rect.height > 0);

        // A translated source and its translation block form one region.
        const regionBounds = element => {
            const rects = visibleRects(element);
            const segmentID = element.getAttribute('data-rp-segment-id');
            if (segmentID) {
                document.querySelectorAll(`.rp-translation-block[data-rp-source-segment-id="${CSS.escape(segmentID)}"]`)
                    .forEach(block => rects.push(...visibleRects(block)));
            }
            if (rects.length === 0) { return null; }
            return rects.reduce((bounds, rect) => ({
                left: Math.min(bounds.left, rect.left),
                top: Math.min(bounds.top, rect.top),
                right: Math.max(bounds.right, rect.right),
                bottom: Math.max(bounds.bottom, rect.bottom)
            }), { left: Infinity, top: Infinity, right: -Infinity, bottom: -Infinity });
        };

        const unionBounds = elements => elements.map(regionBounds).filter(Boolean).reduce((bounds, rect) => bounds ? {
            left: Math.min(bounds.left, rect.left),
            top: Math.min(bounds.top, rect.top),
            right: Math.max(bounds.right, rect.right),
            bottom: Math.max(bounds.bottom, rect.bottom)
        } : rect, null);

        const sameBounds = (a, b) => !!a && !!b &&
            ['left', 'top', 'right', 'bottom'].every(edge => Math.abs(a[edge] - b[edge]) <= sameBoundsTolerance);

        // Outline steps, innermost first. A wrapper as large as what it wraps adds no visible
        // step, so it joins that level and, being outermost, is what gets hidden: no empty
        // margins stay behind. A hidden region is a level of its own, since a click restores
        // exactly that element.
        const levelsFor = list => {
            const result = [];
            let previousBounds = null;
            for (const element of candidatesIn(list)) {
                const bounds = regionBounds(element);
                // Nothing on screen to outline, such as an empty inline element.
                if (!bounds) { continue; }
                const level = result[result.length - 1];
                if (level && !isHidden(level.element) && sameBounds(previousBounds, bounds)) {
                    level.members.push(element);
                    level.element = element;
                } else {
                    result.push({ element, members: [element] });
                }
                previousBounds = bounds;
            }
            return result;
        };

        const levelIndexOf = element => levels.findIndex(level => level.members.includes(element));

        // The innermost block under the pointer, or the hidden region it is in.
        const defaultLevel = () => {
            if (levels.length === 0) { return null; }
            if (isHidden(levels[0].element)) { return levels[0]; }
            return levels.find(level => level.members.some(element => layoutOf(element) === 'block')) ||
                levels[levels.length - 1];
        };

        // Page text in an element, without translations, so the result is the same in every display mode.
        const textLengthOf = element => {
            let length = textLengths.get(element);
            if (length !== undefined) { return length; }
            length = 0;
            const walker = document.createTreeWalker(element, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, {
                acceptNode: node => node.nodeType === Node.ELEMENT_NODE && node.matches(uncountedSelector)
                    ? NodeFilter.FILTER_REJECT
                    : NodeFilter.FILTER_ACCEPT
            });
            for (let node = walker.nextNode(); node; node = walker.nextNode()) {
                if (node.nodeType === Node.TEXT_NODE) { length += node.nodeValue.replace(/\\s+/g, '').length; }
            }
            textLengths.set(element, length);
            return length;
        };

        // What an element shows, as a key of `labels.kinds`.
        const kindOf = element => {
            const tag = tagFor(element);
            if (element.matches(imageSelector)) { return 'image'; }
            if (element.matches(mediaSelector)) { return 'media'; }
            if (tag === 'math' || element.matches('.ltx_equation, .ltx_equationgroup')) { return 'formula'; }
            if (/^h[1-6]$/.test(tag)) { return 'heading'; }
            if (/^(ul|ol|dl|menu)$/.test(tag)) { return 'list'; }
            if (/^(li|dt|dd)$/.test(tag)) { return 'listItem'; }
            if (tag === 'blockquote') { return 'quote'; }
            if (tag === 'pre' || tag === 'code') { return 'code'; }
            if (tag === 'table' || (tag === 'figure' && element.querySelector('table'))) { return 'table'; }
            // Wrappers without text are named for the picture or player they hold.
            if (textLengthOf(element) === 0) {
                if (element.querySelector(imageSelector)) { return 'image'; }
                if (element.querySelector(mediaSelector)) { return 'media'; }
            }
            if (tag === 'figure' && element.querySelector(imageSelector)) { return 'image'; }
            if (tag === 'p') { return 'paragraph'; }
            if (tag === 'a') { return 'link'; }
            return layoutOf(element) === 'inline' ? 'text' : 'block';
        };

        // A level is named for its innermost member that is more than a plain block.
        const kindLabelFor = element => {
            const level = levels[levelIndexOf(element)];
            const kinds = (level ? level.members : [element]).map(kindOf);
            return labels.kinds?.[kinds.find(kind => kind !== 'block') || 'block'] || '';
        };

        // Looks through `display: contents` wrappers, which have no box of their own.
        const visualChildrenOf = element => childrenFor(element).flatMap(child =>
            !child.matches(sourceSelector) && getComputedStyle(child).display === 'contents'
                ? visualChildrenOf(child)
                : isVisualChild(child) ? [child] : []);

        // The innermost element a region's content starts (or ends) with.
        const contentEdge = (element, fromEnd) => {
            for (let children = visualChildrenOf(element); children.length > 0; children = visualChildrenOf(element)) {
                element = children[fromEnd ? children.length - 1 : 0];
            }
            return element;
        };

        // Tests against the run of content from one element to another, both included. Only
        // visible elements count, so whitespace and reader-only blocks never split a container:
        // one whose content all lies in the run is covered even if the run ends at its last child.
        const runBetween = (first, last) => {
            if (first.compareDocumentPosition(last) & Node.DOCUMENT_POSITION_PRECEDING) { [first, last] = [last, first]; }
            const startsInside = element => element === first || first.contains(element) ||
                (!!(first.compareDocumentPosition(element) & Node.DOCUMENT_POSITION_FOLLOWING) && !element.contains(first));
            const endsInside = element => element === last || last.contains(element) ||
                (!!(last.compareDocumentPosition(element) & Node.DOCUMENT_POSITION_PRECEDING) && !element.contains(last));
            return {
                covers: element => startsInside(contentEdge(element, false)) && endsInside(contentEdge(element, true)),
                touches: element =>
                    !(first.compareDocumentPosition(element) & Node.DOCUMENT_POSITION_PRECEDING && !element.contains(first)) &&
                    !(last.compareDocumentPosition(element) & Node.DOCUMENT_POSITION_FOLLOWING && !last.contains(element))
            };
        };

        // The outermost regions covered by the run between two elements. Wrappers that cannot be
        // hidden, and containers reaching past either end, are entered instead of taken whole.
        const regionsBetween = (first, last) => {
            if (first.contains(last)) { return [first]; }
            if (last.contains(first)) { return [last]; }
            const run = runBetween(first, last);
            const result = [];
            const visit = parent => {
                for (const child of visualChildrenOf(parent)) {
                    if (!run.touches(child)) { continue; }
                    if (!roots.has(child) && layoutOf(child) !== null && run.covers(child)) {
                        result.push(child);
                    } else {
                        visit(child);
                    }
                }
            };
            visit(document.body);
            return result;
        };

        const hiddenRegionsBetween = (first, last) =>
            Array.from(document.querySelectorAll(hiddenSelector)).filter(runBetween(first, last).covers);

        // While Shift is held after a single edit: the regions from that one to the outlined one.
        const rangeTargets = () => {
            const anchor = rangeAnchor?.element;
            if (!shiftHeld || !anchor?.isConnected || !selected || anchor === selected) { return []; }
            if (rangeCache?.anchor !== anchor || rangeCache.end !== selected || rangeCache.generation !== generation) {
                const targets = rangeAnchor.hidden
                    ? regionsBetween(anchor, selected)
                    : hiddenRegionsBetween(anchor, selected);
                rangeCache = { anchor, end: selected, generation, targets };
            }
            return rangeCache.targets;
        };

        // What a click would change, and whether it hides or restores.
        const currentPreview = () => {
            if (!enabled || !selected?.isConnected) { return null; }
            const targets = rangeTargets();
            if (targets.length > 1) { return { targets, hidden: rangeAnchor.hidden, isRange: true }; }
            return { targets: [selected], hidden: !isHidden(selected), isRange: false };
        };

        const place = (element, bounds, origin) => {
            element.style.left = `${bounds.left - outlineInset - origin.left}px`;
            element.style.top = `${bounds.top - outlineInset - origin.top}px`;
            element.style.width = `${bounds.right - bounds.left + outlineInset * 2}px`;
            element.style.height = `${bounds.bottom - bounds.top + outlineInset * 2}px`;
        };

        const render = () => {
            if (!box) { return; }
            const preview = currentPreview();
            const bounds = preview ? unionBounds(preview.targets) : null;
            if (!bounds) {
                box.classList.remove('is-visible');
                parentBox.classList.remove('is-visible');
                return;
            }
            const origin = layer.getBoundingClientRect();
            place(box, bounds, origin);
            const restoring = !preview.hidden;
            box.classList.toggle('is-restore', restoring);
            box.classList.add('is-visible');
            actionLabel.textContent = (restoring ? labels.restore : labels.hide) || '';
            kindLabel.textContent = preview.isRange
                ? (labels.regions || '{count}').replace('{count}', String(preview.targets.length))
                : kindLabelFor(selected);
            // Above the outline when there is room; otherwise inside it, kept on screen.
            const top = bounds.top - outlineInset;
            const height = bounds.bottom - bounds.top + outlineInset * 2;
            const badgeTop = top >= badgeHeight + 6
                ? -(badgeHeight + 4)
                : Math.min(Math.max(4, 8 - top), Math.max(4, height - badgeHeight - 4));
            box.firstChild.style.top = `${badgeTop}px`;
            // Dashed: what ↑ would outline next.
            const index = preview.isRange ? -1 : levelIndexOf(selected);
            const parentBounds = index >= 0 && levels[index + 1] ? regionBounds(levels[index + 1].element) : null;
            parentBox.classList.toggle('is-visible', !!parentBounds);
            if (parentBounds) { place(parentBox, parentBounds, origin); }
        };

        const updateFromPoint = (x, y) => {
            pointer = { x, y };
            levels = levelsFor(chainFor(editableElementFor(document.elementFromPoint(x, y))));
            // Keep a grown or shrunk outline while the pointer stays inside it.
            const index = selected ? levelIndexOf(selected) : -1;
            selected = index >= 0 ? levels[index].element : defaultLevel()?.element || null;
            render();
        };

        // Hidden regions decide which outlines are possible, so edits pick again.
        const refresh = () => {
            if (pointer) {
                updateFromPoint(pointer.x, pointer.y);
                return;
            }
            if (selected?.isConnected) {
                levels = levelsFor(chainFor(selected));
                const index = levelIndexOf(selected);
                selected = index >= 0 ? levels[index].element : levels[0]?.element || null;
            }
            render();
        };

        // Scrolling moves content under a still pointer; re-pick once per frame.
        const flushScrollUpdate = () => {
            if (frame === null) { return; }
            cancelAnimationFrame(frame);
            frame = null;
            if (pointer) { updateFromPoint(pointer.x, pointer.y); }
        };

        const scheduleScrollUpdate = () => {
            if (frame !== null || !pointer) { return; }
            frame = requestAnimationFrame(() => {
                frame = null;
                if (enabled && pointer) { updateFromPoint(pointer.x, pointer.y); }
            });
        };

        const clearSelection = () => {
            if (frame !== null) {
                cancelAnimationFrame(frame);
                frame = null;
            }
            pointer = null;
            levels = [];
            selected = null;
            render();
        };

        // Grows (+1) or shrinks (-1) the outline; false when nothing is outlined.
        const adjust = step => {
            flushScrollUpdate();
            const index = selected ? levelIndexOf(selected) : -1;
            if (index < 0) { return false; }
            selected = levels[Math.min(levels.length - 1, Math.max(0, index + step))].element;
            render();
            return true;
        };

        // A few words of a hidden region for the edit bar's list; an image's description if it has no text.
        const summaryOf = element => {
            let text = '';
            const walker = document.createTreeWalker(element, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, {
                acceptNode: node => node.nodeType === Node.ELEMENT_NODE && node.matches(uncountedSelector)
                    ? NodeFilter.FILTER_REJECT
                    : NodeFilter.FILTER_ACCEPT
            });
            for (let node = walker.nextNode(); node && text.length < summaryLength * 2; node = walker.nextNode()) {
                if (node.nodeType === Node.TEXT_NODE) { text += node.nodeValue; }
            }
            text = text.replace(/\\s+/g, ' ').trim();
            if (!text) {
                const image = element.matches('img[alt]') ? element : element.querySelector('img[alt]');
                text = (image?.getAttribute('alt') || '').trim();
            }
            return text.length > summaryLength ? `${text.slice(0, summaryLength - 1).trimEnd()}…` : text;
        };

        const hiddenRegions = () => Array.from(document.querySelectorAll(hiddenSelector)).flatMap(element => {
            const path = pathFor(element);
            return path ? [{ path, kind: labels.kinds?.[kindOf(element)] || '', text: summaryOf(element) }] : [];
        });

        const report = changes => post({
            type: 'update',
            documentURL: location.href,
            changes,
            hiddenRegionCount: hiddenRegionCount(),
            hiddenRegions: hiddenRegions(),
            canUndo: undoStack.length > 0,
            canRedo: redoStack.length > 0
        });

        // `edits` are `{ element, hidden }` targets; `history` is 'edit', 'undo', or 'redo'.
        // One call is one undo step, however many regions it changes.
        const apply = (edits, history) => {
            const effective = edits.filter(edit => edit.element.isConnected && isHidden(edit.element) !== edit.hidden);
            if (effective.length === 0) { return; }
            effective.forEach(({ element, hidden }) => {
                if (hidden) {
                    element.setAttribute(hiddenAttribute, 'true');
                } else {
                    element.removeAttribute(hiddenAttribute);
                }
            });
            generation += 1;
            const inverse = effective.map(({ element, hidden }) => ({ element, hidden: !hidden }));
            if (history === 'undo') {
                redoStack.push(inverse);
            } else {
                undoStack.push(inverse);
                if (history === 'edit') { redoStack = []; }
            }
            report(effective.map(({ element, hidden }) => {
                const path = pathFor(element);
                return path ? { path, signature: signatureFor(element), isHidden: hidden } : null;
            }).filter(Boolean));
            refresh();
            window.__rpLayoutSidenotes?.();
        };

        const toggle = element => {
            // Only elements with an anchor path can be saved.
            if (!element || !pathFor(element)) { return; }
            const hidden = !isHidden(element);
            rangeAnchor = { element, hidden };
            apply([{ element, hidden }], 'edit');
        };

        // Applies what the outline shows: a range while Shift is held, else the outlined region.
        const commit = () => {
            const preview = currentPreview();
            if (!preview) { return; }
            if (preview.isRange) {
                apply(preview.targets.filter(pathFor).map(element => ({ element, hidden: preview.hidden })), 'edit');
            } else {
                toggle(selected);
            }
        };

        const undo = () => {
            const edits = undoStack.pop();
            rangeAnchor = null;
            if (edits) { apply(edits, 'undo'); }
        };

        const redo = () => {
            const edits = redoStack.pop();
            rangeAnchor = null;
            if (edits) { apply(edits, 'redo'); }
        };

        const restoreAll = () => {
            const edits = Array.from(document.querySelectorAll(hiddenSelector))
                .map(element => ({ element, hidden: false }));
            rangeAnchor = null;
            apply(edits, 'edit');
        };

        // Scrolls a hidden region into view and outlines it, ready to restore with a click or Enter.
        const reveal = path => {
            const element = window.__rpResolveNoteAnchor?.(path);
            if (!element || !isHidden(element)) { return; }
            if (frame !== null) {
                cancelAnimationFrame(frame);
                frame = null;
            }
            pointer = null;
            selected = element;
            refresh();
            const bounds = selected ? regionBounds(selected) : null;
            if (bounds) {
                const height = bounds.bottom - bounds.top;
                const top = window.scrollY + bounds.top - Math.max(16, (window.innerHeight - height) / 2);
                window.scrollTo({ top: Math.max(0, top), behavior: 'smooth' });
            }
            box.classList.remove('is-flash');
            void box.offsetWidth;
            box.classList.add('is-flash');
            clearTimeout(flashTimer);
            flashTimer = setTimeout(() => box?.classList.remove('is-flash'), 900);
        };

        // Faded regions appear or collapse when edit mode toggles; keep the text in view still.
        const preserveReadingPosition = mutate => {
            let anchor = null;
            const content = document.querySelector('.rp-readability-shell') || document.body;
            const contentRect = content?.getBoundingClientRect();
            if (window.scrollY > 0 && contentRect && document.caretRangeFromPoint) {
                const range = document.caretRangeFromPoint(
                    contentRect.left + contentRect.width / 2,
                    Math.min(120, window.innerHeight / 4)
                );
                const top = range?.getBoundingClientRect().top;
                if (range && top !== undefined && range.getBoundingClientRect().height > 0) {
                    anchor = { range, top };
                }
            }
            mutate();
            if (!anchor) { return; }
            const rect = anchor.range.getBoundingClientRect();
            if (rect.height === 0) { return; }
            const delta = rect.top - anchor.top;
            if (Math.abs(delta) > 1) { window.scrollBy(0, delta); }
        };

        window.__rpSetRegionEditing = (on, nextLabels) => {
            labels = nextLabels || labels;
            ensureStyle();
            ensureLayer();
            if (!!on === enabled) {
                render();
                return;
            }
            enabled = !!on;
            preserveReadingPosition(() => {
                if (enabled) {
                    document.documentElement.setAttribute(editingAttribute, 'true');
                } else {
                    document.documentElement.removeAttribute(editingAttribute);
                }
            });
            undoStack = [];
            redoStack = [];
            rangeAnchor = null;
            shiftHeld = false;
            generation += 1;
            clearSelection();
            if (enabled) {
                roots = computeRoots();
                textLengths = new WeakMap();
                window.getSelection()?.removeAllRanges();
                report([]);
            }
            window.__rpLayoutSidenotes?.();
        };

        window.__rpRegionEditPerform = (action, argument) => {
            if (!enabled) { return; }
            if (action === 'undo') {
                undo();
            } else if (action === 'redo') {
                redo();
            } else if (action === 'restoreAll') {
                restoreAll();
            } else if (action === 'reveal') {
                reveal(argument);
            }
        };

        // Used by tests.
        window.__rpRegionEditState = () => {
            flushScrollUpdate();
            const preview = currentPreview();
            return JSON.stringify({
                enabled,
                selectedPath: selected ? pathFor(selected) : null,
                selectedTag: selected ? tagFor(selected) : null,
                restoring: !!selected && isHidden(selected),
                outlineVisible: !!box && box.classList.contains('is-visible'),
                parentOutlineVisible: !!parentBox && parentBox.classList.contains('is-visible'),
                action: actionLabel ? actionLabel.textContent : '',
                kind: kindLabel ? kindLabel.textContent : '',
                rangeCount: preview?.isRange ? preview.targets.length : 0,
                hiddenRegionCount: hiddenRegionCount(),
                canUndo: undoStack.length > 0,
                canRedo: redoStack.length > 0
            });
        };

        const consume = event => {
            event.preventDefault();
            event.stopPropagation();
            event.stopImmediatePropagation();
        };
        const isReaderChrome = event => !!event.target?.closest?.(readerLayerSelector);

        const setShiftHeld = held => {
            if (shiftHeld === held) { return; }
            shiftHeld = held;
            if (enabled) { render(); }
        };

        // Window capture runs before the reader's document listeners (selection, notes, links).
        // Hit testing on a laid-out page is cheap, so the outline follows the pointer directly.
        window.addEventListener('mousemove', event => {
            if (!enabled) { return; }
            shiftHeld = event.shiftKey;
            updateFromPoint(event.clientX, event.clientY);
        }, true);

        window.addEventListener('pointerdown', event => {
            if (!enabled || isReaderChrome(event)) { return; }
            event.stopPropagation();
            event.stopImmediatePropagation();
        }, true);

        ['mousedown', 'mouseup', 'dblclick', 'auxclick'].forEach(type => {
            window.addEventListener(type, event => {
                if (enabled && !isReaderChrome(event)) { consume(event); }
            }, true);
        });

        window.addEventListener('click', event => {
            if (!enabled || isReaderChrome(event)) { return; }
            consume(event);
            // The second click of a double-click would undo the first.
            if (event.button !== 0 || event.detail > 1) { return; }
            shiftHeld = event.shiftKey;
            updateFromPoint(event.clientX, event.clientY);
            commit();
        }, true);

        window.addEventListener('keydown', event => {
            if (!enabled) { return; }
            if (event.key === 'Shift') { setShiftHeld(true); }
            if (isReaderChrome(event) || event.target?.closest?.(textInputSelector)) { return; }
            const key = event.key;
            if (key === 'Escape') {
                consume(event);
                post({ type: 'exit' });
                return;
            }
            if ((event.metaKey || event.ctrlKey) && !event.altKey && key.toLowerCase() === 'z') {
                consume(event);
                if (event.shiftKey) { redo(); } else { undo(); }
                return;
            }
            if (event.metaKey || event.ctrlKey || event.altKey) { return; }
            if ((key === 'ArrowUp' || key === 'ArrowDown') && adjust(key === 'ArrowUp' ? 1 : -1)) {
                consume(event);
                return;
            }
            if (key === 'Enter' && selected) {
                consume(event);
                shiftHeld = event.shiftKey;
                commit();
            }
        }, true);

        window.addEventListener('keyup', event => {
            if (event.key === 'Shift') { setShiftHeld(false); }
        }, true);
        window.addEventListener('blur', () => setShiftHeld(false));

        window.addEventListener('scroll', () => {
            if (enabled) { scheduleScrollUpdate(); }
        }, { passive: true });
        window.addEventListener('resize', () => {
            if (!enabled) { return; }
            roots = computeRoots();
            generation += 1;
            refresh();
            scheduleScrollUpdate();
        });
        document.documentElement.addEventListener('mouseleave', () => {
            if (enabled) { clearSelection(); }
        });

        // Lets the reader show that a page has hidden regions before anyone edits it.
        post({ type: 'loaded', documentURL: location.href, hiddenRegionCount: hiddenRegionCount() });
    })();
    """

    private static let stylesheet = """
    \(HTMLRegionVisibility.hiddenRegionCSS)
    html[\(HTMLRegionVisibility.editingAttribute)='true'] body,
    html[\(HTMLRegionVisibility.editingAttribute)='true'] body * {
        cursor: default !important;
        -webkit-user-select: none !important;
        user-select: none !important;
    }
    html[\(HTMLRegionVisibility.editingAttribute)='true'] [\(HTMLRegionVisibility.hiddenAttribute)='true'],
    html[\(HTMLRegionVisibility.editingAttribute)='true'] [\(HTMLRegionVisibility.hiddenAttribute)='true'] + .rp-translation-block {
        opacity: 0.4 !important;
        outline: 1px dashed rgba(196, 64, 43, 0.6) !important;
        outline-offset: 2px !important;
        background-image: repeating-linear-gradient(
            135deg, rgba(196, 64, 43, 0.08) 0 6px, transparent 6px 12px
        ) !important;
    }
    html[\(HTMLRegionVisibility.editingAttribute)='true'] [\(HTMLRegionVisibility.hiddenAttribute)='true'] [\(HTMLRegionVisibility.hiddenAttribute)='true'],
    html[\(HTMLRegionVisibility.editingAttribute)='true'] [\(HTMLRegionVisibility.hiddenAttribute)='true'] [\(HTMLRegionVisibility.hiddenAttribute)='true'] + .rp-translation-block {
        opacity: 1 !important;
    }
    .rp-region-edit-layer {
        position: absolute;
        top: 0;
        left: 0;
        width: 0;
        height: 0;
        z-index: 30;
        pointer-events: none;
    }
    .rp-region-edit-box,
    .rp-region-edit-parent {
        position: absolute;
        display: none;
        box-sizing: border-box;
        pointer-events: none;
    }
    .rp-region-edit-box.is-visible,
    .rp-region-edit-parent.is-visible { display: block; }
    .rp-region-edit-box {
        border: 2px solid rgba(214, 69, 48, 0.92);
        border-radius: 6px;
        background: rgba(214, 69, 48, 0.08);
    }
    .rp-region-edit-box.is-restore {
        border-color: rgba(36, 138, 84, 0.95);
        background: rgba(36, 138, 84, 0.1);
    }
    .rp-region-edit-box.is-flash { animation: rp-region-edit-flash 0.9s ease-out; }
    @keyframes rp-region-edit-flash {
        from { box-shadow: 0 0 0 10px rgba(36, 138, 84, 0.35); }
        to { box-shadow: 0 0 0 0 rgba(36, 138, 84, 0); }
    }
    .rp-region-edit-parent {
        border: 1px dashed rgba(214, 69, 48, 0.55);
        border-radius: 7px;
    }
    .rp-region-edit-badge {
        position: absolute;
        left: -2px;
        display: flex;
        gap: 6px;
        align-items: baseline;
        padding: 2px 8px;
        border-radius: 6px;
        white-space: nowrap;
        font: 500 11px/18px -apple-system, BlinkMacSystemFont, "Helvetica Neue", "PingFang SC", sans-serif;
        color: #fff;
        background: rgba(214, 69, 48, 0.95);
        box-shadow: 0 2px 6px rgba(0, 0, 0, 0.18);
    }
    .rp-region-edit-box.is-restore .rp-region-edit-badge { background: rgba(36, 138, 84, 0.95); }
    .rp-region-edit-badge > span:empty { display: none; }
    .rp-region-edit-action { font-weight: 700; }
    """

    private static func javaScriptStringLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let literal = String(data: data, encoding: .utf8) else {
            return "''"
        }
        return literal
    }
}

struct HTMLRegionEditLabels: Codable, Equatable, Sendable {
    var hide = ""
    var restore = ""
    /// Names for what an outline holds, keyed by the page script's kinds
    /// ("paragraph", "heading", "image", "block", …).
    var kinds: [String: String] = [:]
    /// "{count} regions", for an outline that spans several regions.
    var regions = ""
}

/// A hidden region as the edit bar lists it.
struct HTMLHiddenRegion: Decodable, Equatable, Identifiable, Sendable {
    var path: String
    /// What the region shows, already localized.
    var kind: String
    /// Its first words, or an image's description.
    var text: String

    var id: String { path }
}

/// State the page reports after entering edit mode and after every edit.
struct HTMLRegionEditUpdate: Decodable, Equatable, Sendable {
    /// The page that made the edits; `changes` only apply to that file.
    var documentURL: String?
    var changes: [HTMLRegionChange]
    var hiddenRegionCount: Int
    var hiddenRegions: [HTMLHiddenRegion]
    var canUndo: Bool
    var canRedo: Bool
}

enum HTMLRegionEditEvent: Equatable, Sendable {
    /// A page finished loading with this many hidden regions.
    case loaded(documentURL: String?, hiddenRegionCount: Int)
    case updated(HTMLRegionEditUpdate)
    /// Escape was pressed in the page.
    case exitRequested
}

struct HTMLRegionEditCommand: Equatable, Identifiable {
    enum Action: Equatable {
        case undo
        case redo
        case restoreAll
        /// Scrolls to a hidden region and outlines it, ready to restore.
        case reveal(path: String)

        /// The arguments of `__rpRegionEditPerform` in the page script.
        var scriptArguments: [String] {
            switch self {
            case .undo: ["undo"]
            case .redo: ["redo"]
            case .restoreAll: ["restoreAll"]
            case let .reveal(path): ["reveal", path]
            }
        }
    }

    let id: UUID
    var action: Action

    init(id: UUID = UUID(), action: Action) {
        self.id = id
        self.action = action
    }
}
