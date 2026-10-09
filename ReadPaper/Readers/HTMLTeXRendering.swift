import Foundation

/// Typesets raw TeX (`\(...\)`, `\[...\]`, `$$...$$`, AMS environments) in the HTML reader.
///
/// Source pages usually typeset TeX with MathJax/KaTeX loaded from external scripts, which
/// `HTMLLocalizer` strips, so the saved `paper.html` only contains the TeX source. Rendering
/// happens in the reader instead of on disk so already-imported papers benefit, and the
/// translation pipeline keeps working on the original text. Temml emits MathML, which WebKit
/// renders natively with the system math font, so no web fonts have to be bundled.
///
/// Each formula is wrapped in a `.rp-tex-math` span. The instrumentation script skips these
/// spans when building `rp-anchor:` paths, so note anchors match the unrendered document.
enum HTMLTeXRendering {
    static let wrapperClass = "rp-tex-math"

    static let userScript: String = {
        guard let temml = resourceText("temml", withExtension: "min.js") else {
            return ""
        }
        return """
        \(temml)
        ;\(rendererScript(css: stylesheet()))
        """
    }()

    static func rendererScript(css: String) -> String {
        """
        (() => {
            if (window.__rpTeXInstalled || typeof temml === 'undefined') { return; }
            window.__rpTeXInstalled = true;

            const css = \(javaScriptStringLiteral(css));
            const wrapperClass = '\(wrapperClass)';
            const ignoredSelector = [
                'script', 'style', 'noscript', 'template', 'textarea', 'pre', 'code', 'kbd', 'samp',
                'option', 'math', 'svg', '[contenteditable]', '.' + wrapperClass, '.rp-sidenote-layer'
            ].join(',');
            const environments = [
                'equation', 'align', 'alignat', 'flalign', 'gather', 'multline', 'eqnarray', 'CD'
            ].flatMap(name => [name, name + '*']);
            // Single `$` is left alone: it is too often a currency sign in prose.
            const delimiters = [
                { left: '$$', right: '$$', display: true },
                { left: '\\\\[', right: '\\\\]', display: true },
                { left: '\\\\(', right: '\\\\)', display: false },
                ...environments.map(name => ({
                    left: `\\\\begin{${name}}`, right: `\\\\end{${name}}`, display: true, keepDelimiters: true
                }))
            ];
            const escapeRegExp = value => value.replace(/[-/\\\\^$*+?.()|[\\]{}]/g, '\\\\$&');
            const leftPattern = new RegExp(delimiters.map(delimiter => escapeRegExp(delimiter.left)).join('|'));
            const macros = Object.create(null);

            const findEndOfMath = (right, text, startIndex) => {
                let braceLevel = 0;
                for (let index = startIndex; index < text.length; index += 1) {
                    if (braceLevel <= 0 && text.startsWith(right, index)) { return index; }
                    const character = text[index];
                    if (character === '\\\\') {
                        index += 1;
                    } else if (character === '{') {
                        braceLevel += 1;
                    } else if (character === '}') {
                        braceLevel -= 1;
                    }
                }
                return -1;
            };

            const splitAtDelimiters = text => {
                const parts = [];
                let rest = text;
                while (rest) {
                    const start = rest.search(leftPattern);
                    if (start < 0) { break; }
                    if (start > 0) {
                        parts.push({ text: rest.slice(0, start) });
                        rest = rest.slice(start);
                    }
                    const delimiter = delimiters.find(candidate => rest.startsWith(candidate.left));
                    const end = findEndOfMath(delimiter.right, rest, delimiter.left.length);
                    if (end < 0) { break; }
                    const raw = rest.slice(0, end + delimiter.right.length);
                    const tex = delimiter.keepDelimiters ? raw : rest.slice(delimiter.left.length, end);
                    parts.push({ tex, raw, display: delimiter.display });
                    rest = rest.slice(raw.length);
                }
                if (rest) { parts.push({ text: rest }); }
                return parts;
            };

            const ensureStyle = () => {
                if (document.getElementById('rp-tex-math-style')) { return; }
                const style = document.createElement('style');
                style.id = 'rp-tex-math-style';
                style.textContent = css;
                (document.head || document.documentElement).appendChild(style);
            };

            const renderedFragment = text => {
                const parts = splitAtDelimiters(text);
                if (!parts.some(part => part.tex !== undefined && part.tex.trim())) { return null; }
                const fragment = document.createDocumentFragment();
                let renderedCount = 0;
                for (const part of parts) {
                    if (part.tex === undefined || !part.tex.trim()) {
                        fragment.appendChild(document.createTextNode(part.text ?? part.raw));
                        continue;
                    }
                    const wrapper = document.createElement('span');
                    wrapper.className = part.display ? `${wrapperClass} ${wrapperClass}-display` : wrapperClass;
                    try {
                        // `temml.render` refuses to run in quirks mode, and saved pages may lack a doctype.
                        wrapper.innerHTML = temml.renderToString(part.tex, {
                            displayMode: part.display,
                            throwOnError: true,
                            macros,
                            trust: false
                        });
                        fragment.appendChild(wrapper);
                        renderedCount += 1;
                    } catch {
                        // Keep the source text so a formula Temml cannot parse stays readable.
                        fragment.appendChild(document.createTextNode(part.raw));
                    }
                }
                return renderedCount > 0 ? fragment : null;
            };

            const renderIn = root => {
                const element = root?.nodeType === Node.ELEMENT_NODE ? root : root?.parentElement;
                if (!element || element.closest(ignoredSelector) || !/\\\\[(\\[]|\\$\\$|\\\\begin\\{/.test(element.textContent || '')) {
                    return 0;
                }

                let renderedCount = 0;
                const visit = parent => {
                    let child = parent.firstChild;
                    while (child) {
                        if (child.nodeType === Node.ELEMENT_NODE) {
                            if (!child.matches(ignoredSelector)) { visit(child); }
                            child = child.nextSibling;
                            continue;
                        }
                        if (child.nodeType !== Node.TEXT_NODE) {
                            child = child.nextSibling;
                            continue;
                        }
                        // Treat adjacent text nodes as one run so a formula split across them still renders.
                        const run = [];
                        while (child && child.nodeType === Node.TEXT_NODE) {
                            run.push(child);
                            child = child.nextSibling;
                        }
                        const fragment = renderedFragment(run.map(node => node.data).join(''));
                        if (!fragment) { continue; }
                        renderedCount += fragment.querySelectorAll('.' + wrapperClass).length;
                        parent.insertBefore(fragment, run[0]);
                        run.forEach(node => node.remove());
                    }
                };

                visit(element);
                if (renderedCount > 0) { ensureStyle(); }
                return renderedCount;
            };

            window.__rpRenderTeX = root => {
                try {
                    return renderIn(root || document.body);
                } catch {
                    return 0;
                }
            };
            window.__rpRenderTeX();
        })();
        """
    }

    private static func stylesheet() -> String {
        var css = resourceText("Temml-Local", withExtension: "css") ?? ""
        if let font = resourceData("Temml", withExtension: "woff2") {
            css = css.replacingOccurrences(
                of: "url('Temml.woff2')",
                with: "url('data:font/woff2;base64,\(font.base64EncodedString())')"
            )
        }
        return css + """

        .\(wrapperClass) math {
            font-family: "STIX Two Math", "STIXTwoMath-Regular", "Cambria Math", math;
        }
        .\(wrapperClass)-display {
            display: block;
            max-width: 100%;
            overflow-x: auto;
            overflow-y: hidden;
            margin: 0.6em 0;
        }
        """
    }

    private static func javaScriptStringLiteral(_ value: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        guard let data = try? encoder.encode(value),
              let literal = String(data: data, encoding: .utf8) else {
            return "''"
        }
        return literal
    }

    private static func resourceText(_ name: String, withExtension fileExtension: String) -> String? {
        resourceData(name, withExtension: fileExtension).map { String(decoding: $0, as: UTF8.self) }
    }

    private static func resourceData(_ name: String, withExtension fileExtension: String) -> Data? {
        let bundle = Bundle(for: BundleToken.self)
        guard let url = bundle.url(forResource: name, withExtension: fileExtension) else {
            return nil
        }
        return try? Data(contentsOf: url)
    }

    private final class BundleToken {}
}
