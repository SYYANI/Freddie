import Foundation

/// In-reader editing of an imported page's regions: hovering outlines the block under the
/// pointer, ↑/↓ grow or shrink the outline to the parent or child block, and a click hides
/// the region (or restores a hidden one, which edit mode shows faded).
///
/// The script only toggles `HTMLRegionVisibility.hiddenAttribute` on existing elements and
/// draws its outline in a layer outside `<body>`, so `rp-anchor:` paths stay valid. Each
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
        const renderedMathSelector = '.\(HTMLTeXRendering.wrapperClass)';
        const readerLayerSelector = '.rp-sidenote-layer, .rp-region-edit-layer';
        const rootSelector = '.rp-readability-shell, .rp-readability-content, #readability-page-1';
        const nonVisualSelector = 'script, style, link, meta, title, base, template, noscript';
        const textInputSelector = 'input, textarea, select, [contenteditable=""], [contenteditable="true"]';
        const signatureChildLimit = 16;
        const badgeHeight = 22;

        let enabled = false;
        let labels = {};
        let layer = null;
        let box = null;
        let actionLabel = null;
        let tagLabel = null;
        let roots = new Set();
        let chain = [];
        let selected = null;
        let pointer = null;
        let frame = null;
        let undoStack = [];
        let redoStack = [];

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
            box = document.createElement('div');
            box.className = 'rp-region-edit-box';
            const badge = document.createElement('div');
            badge.className = 'rp-region-edit-badge';
            actionLabel = document.createElement('span');
            tagLabel = document.createElement('span');
            tagLabel.className = 'rp-region-edit-tag';
            badge.append(actionLabel, tagLabel);
            box.appendChild(badge);
            layer.appendChild(box);
            document.documentElement.appendChild(layer);
        };

        const pathFor = element => window.__rpBuildNoteAnchor?.(element) || null;
        const childrenFor = element => window.__rpOriginalChildren?.(element) || [];
        const tagFor = element => (element.localName || '').toLowerCase();
        const isHidden = element => element?.getAttribute?.(hiddenAttribute) === 'true';

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
            (element.getClientRects().length > 0 || element.matches('[data-rp-source="true"]'));

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

        // Table parts are skipped too: hiding one cell or row would only break the table.
        const isBlockLike = element => {
            const display = getComputedStyle(element).display;
            return display !== 'none' && display !== 'contents' &&
                !display.startsWith('inline') && !display.startsWith('table-');
        };

        const outermostHiddenIndex = list => {
            for (let index = list.length - 1; index >= 0; index -= 1) {
                if (isHidden(list[index])) { return index; }
            }
            return -1;
        };

        // Inside a hidden region only the region itself (to restore it) or an ancestor can be picked.
        const candidatesIn = list => list.slice(Math.max(0, outermostHiddenIndex(list)));

        const defaultTargetIn = list => {
            const hiddenIndex = outermostHiddenIndex(list);
            if (hiddenIndex >= 0) { return list[hiddenIndex]; }
            return list.find(isBlockLike) || list[list.length - 1] || null;
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

        const render = () => {
            if (!box) { return; }
            const bounds = enabled && selected?.isConnected ? regionBounds(selected) : null;
            if (!bounds) {
                box.classList.remove('is-visible');
                return;
            }
            const inset = 3;
            const origin = layer.getBoundingClientRect();
            const top = bounds.top - inset;
            const height = bounds.bottom - bounds.top + inset * 2;
            box.style.left = `${bounds.left - inset - origin.left}px`;
            box.style.top = `${top - origin.top}px`;
            box.style.width = `${bounds.right - bounds.left + inset * 2}px`;
            box.style.height = `${height}px`;
            const restoring = isHidden(selected);
            box.classList.toggle('is-restore', restoring);
            box.classList.add('is-visible');
            actionLabel.textContent = (restoring ? labels.restore : labels.hide) || '';
            tagLabel.textContent = tagFor(selected);
            // Above the outline when there is room; otherwise inside it, kept on screen.
            const badgeTop = top >= badgeHeight + 6
                ? -(badgeHeight + 4)
                : Math.min(Math.max(4, 8 - top), Math.max(4, height - badgeHeight - 4));
            box.firstChild.style.top = `${badgeTop}px`;
        };

        const updateFromPoint = (x, y) => {
            pointer = { x, y };
            chain = chainFor(editableElementFor(document.elementFromPoint(x, y)));
            // Keep a grown or shrunk outline while the pointer stays inside it.
            if (!selected || !candidatesIn(chain).includes(selected)) {
                selected = defaultTargetIn(chain);
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
            chain = [];
            selected = null;
            render();
        };

        // Grows (+1) or shrinks (-1) the outline; false when nothing is outlined.
        const adjust = step => {
            flushScrollUpdate();
            const candidates = candidatesIn(chain);
            if (!selected || candidates.length === 0) { return false; }
            const index = Math.max(0, candidates.indexOf(selected));
            selected = candidates[Math.min(candidates.length - 1, Math.max(0, index + step))];
            render();
            return true;
        };

        const hiddenRegionCount = () => document.querySelectorAll(hiddenSelector).length;

        const report = changes => post({
            type: 'update',
            documentURL: location.href,
            changes,
            hiddenRegionCount: hiddenRegionCount(),
            canUndo: undoStack.length > 0,
            canRedo: redoStack.length > 0
        });

        // `edits` are `{ element, hidden }` targets; `history` is 'edit', 'undo', or 'redo'.
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
            render();
            window.__rpLayoutSidenotes?.();
        };

        const toggle = element => {
            // Only elements with an anchor path can be saved.
            if (!element || !pathFor(element)) { return; }
            apply([{ element, hidden: !isHidden(element) }], 'edit');
        };

        const undo = () => {
            const edits = undoStack.pop();
            if (edits) { apply(edits, 'undo'); }
        };

        const redo = () => {
            const edits = redoStack.pop();
            if (edits) { apply(edits, 'redo'); }
        };

        const restoreAll = () => {
            const edits = Array.from(document.querySelectorAll(hiddenSelector))
                .map(element => ({ element, hidden: false }));
            apply(edits, 'edit');
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
            clearSelection();
            if (enabled) {
                roots = computeRoots();
                window.getSelection()?.removeAllRanges();
                report([]);
            }
            window.__rpLayoutSidenotes?.();
        };

        window.__rpRegionEditPerform = action => {
            if (!enabled) { return; }
            if (action === 'undo') {
                undo();
            } else if (action === 'redo') {
                redo();
            } else if (action === 'restoreAll') {
                restoreAll();
            }
        };

        // Used by tests.
        window.__rpRegionEditState = () => {
            flushScrollUpdate();
            return JSON.stringify({
                enabled,
                selectedPath: selected ? pathFor(selected) : null,
                selectedTag: selected ? tagFor(selected) : null,
                restoring: !!selected && isHidden(selected),
                outlineVisible: !!box && box.classList.contains('is-visible'),
                action: actionLabel ? actionLabel.textContent : '',
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

        // Window capture runs before the reader's document listeners (selection, notes, links).
        // Hit testing on a laid-out page is cheap, so the outline follows the pointer directly.
        window.addEventListener('mousemove', event => {
            if (enabled) { updateFromPoint(event.clientX, event.clientY); }
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
            if (event.button !== 0) { return; }
            updateFromPoint(event.clientX, event.clientY);
            toggle(selected);
        }, true);

        window.addEventListener('keydown', event => {
            if (!enabled || isReaderChrome(event) || event.target?.closest?.(textInputSelector)) { return; }
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
                toggle(selected);
            }
        }, true);

        window.addEventListener('scroll', () => {
            if (enabled) { scheduleScrollUpdate(); }
        }, { passive: true });
        window.addEventListener('resize', () => {
            if (!enabled) { return; }
            roots = computeRoots();
            render();
            scheduleScrollUpdate();
        });
        document.documentElement.addEventListener('mouseleave', () => {
            if (enabled) { clearSelection(); }
        });
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
    .rp-region-edit-box {
        position: absolute;
        display: none;
        box-sizing: border-box;
        border: 2px solid rgba(214, 69, 48, 0.92);
        border-radius: 6px;
        background: rgba(214, 69, 48, 0.08);
        pointer-events: none;
    }
    .rp-region-edit-box.is-visible { display: block; }
    .rp-region-edit-box.is-restore {
        border-color: rgba(36, 138, 84, 0.95);
        background: rgba(36, 138, 84, 0.1);
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
        font: 600 11px/18px -apple-system, BlinkMacSystemFont, "Helvetica Neue", "PingFang SC", sans-serif;
        color: #fff;
        background: rgba(214, 69, 48, 0.95);
        box-shadow: 0 2px 6px rgba(0, 0, 0, 0.18);
    }
    .rp-region-edit-box.is-restore .rp-region-edit-badge { background: rgba(36, 138, 84, 0.95); }
    .rp-region-edit-tag {
        font: 500 10.5px/18px ui-monospace, SFMono-Regular, Menlo, monospace;
        opacity: 0.85;
    }
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
}

/// State the page reports after entering edit mode and after every edit.
struct HTMLRegionEditUpdate: Decodable, Equatable, Sendable {
    /// The page that made the edits; `changes` only apply to that file.
    var documentURL: String?
    var changes: [HTMLRegionChange]
    var hiddenRegionCount: Int
    var canUndo: Bool
    var canRedo: Bool
}

enum HTMLRegionEditEvent: Equatable, Sendable {
    case updated(HTMLRegionEditUpdate)
    /// Escape was pressed in the page.
    case exitRequested
}

struct HTMLRegionEditCommand: Equatable, Identifiable {
    enum Action: String {
        case undo
        case redo
        case restoreAll
    }

    let id: UUID
    var action: Action

    init(id: UUID = UUID(), action: Action) {
        self.id = id
        self.action = action
    }
}
