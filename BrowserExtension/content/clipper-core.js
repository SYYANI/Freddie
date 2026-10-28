// Reads the page as the reader sees it: metadata, the article region, and a snapshot of
// the rendered DOM that Freddie can save without running the page's scripts.
// Injected again on every click, so everything lives behind one guard.
(() => {
  if (globalThis.FreddieClipperCore) return;

  const UI_ATTRIBUTE = "data-freddie-clipper";

  // Metadata

  function metaContent(names) {
    for (const name of names) {
      for (const element of document.querySelectorAll("meta[name], meta[property]")) {
        const key = (element.getAttribute("name") || element.getAttribute("property") || "").toLowerCase();
        const content = element.getAttribute("content")?.trim();
        if (key === name && content) return content;
      }
    }
    return null;
  }

  function metaContents(name) {
    return [...document.querySelectorAll("meta[name], meta[property]")]
      .filter((element) => (element.getAttribute("name") || element.getAttribute("property") || "").toLowerCase() === name)
      .map((element) => element.getAttribute("content")?.trim())
      .filter(Boolean);
  }

  function jsonLDObjects() {
    const objects = [];
    const visit = (value) => {
      if (Array.isArray(value)) value.forEach(visit);
      else if (value && typeof value === "object") {
        objects.push(value);
        if (value["@graph"]) visit(value["@graph"]);
      }
    };
    for (const script of document.querySelectorAll('script[type="application/ld+json"]')) {
      try { visit(JSON.parse(script.textContent)); } catch { /* malformed blocks are common */ }
    }
    return objects;
  }

  const ARTICLE_TYPES = /Article|Posting|Report|Thesis|Chapter|Book/;

  function jsonLDArticle() {
    return jsonLDObjects().find((object) => {
      const types = [].concat(object["@type"] || []);
      return types.some((type) => ARTICLE_TYPES.test(String(type)));
    });
  }

  function personNames(value) {
    return [].concat(value || [])
      .map((person) => (typeof person === "string" ? person : person?.name))
      .filter((name) => typeof name === "string" && name.trim())
      .map((name) => name.trim());
  }

  function normalizeDOI(value) {
    const match = String(value || "").match(/10\.\d{4,9}\/[^\s"<>]+/);
    return match ? match[0].replace(/[.,;]+$/, "") : null;
  }

  function arxivID() {
    const host = location.hostname.toLowerCase();
    if (!(host === "arxiv.org" || host.endsWith(".arxiv.org"))) return null;
    const match = location.pathname.match(/\/(?:abs|pdf|html)\/([a-z-]+(?:\.[a-z]{2})?\/\d{7}|\d{4}\.\d{4,5})(v\d+)?/i);
    return match ? match[1] + (match[2] || "") : null;
  }

  function readMetadata() {
    const article = jsonLDArticle() || {};
    let authors = metaContents("citation_author");
    if (!authors.length) authors = metaContents("dc.creator");
    if (!authors.length) authors = personNames(article.author);
    if (!authors.length) authors = metaContents("author");
    // citation_author is usually "Last, First"; the library stores "First Last".
    authors = authors.map((name) => {
      const parts = name.split(",").map((part) => part.trim());
      return parts.length === 2 && parts[0] && parts[1] ? `${parts[1]} ${parts[0]}` : name;
    });

    const pdfURL = metaContent(["citation_pdf_url"]);
    return {
      title: metaContent(["citation_title", "dc.title"]) || article.headline || metaContent(["og:title"]) || document.title,
      authors,
      doi: normalizeDOI(metaContent(["citation_doi", "prism.doi", "dc.identifier"]) || article.doi),
      abstract: metaContent(["citation_abstract", "dc.description"]) || (typeof article.abstract === "string" ? article.abstract : null),
      publishedDate: metaContent(["citation_publication_date", "citation_date", "citation_online_date", "dc.date", "article:published_time"])
        || article.datePublished || null,
      siteName: metaContent(["og:site_name", "citation_journal_title", "citation_conference_title"]) || location.hostname,
      pdfURL: pdfURL ? absoluteURL(pdfURL) : null,
      arxivID: arxivID(),
      isPDF: document.contentType === "application/pdf"
    };
  }

  // Article detection, a small cousin of Readability's scoring: block text counts toward
  // its parent and half toward its grandparent; the best container wins.

  const BLOCKS = "p, pre, blockquote, li, td, h2, h3, h4, figcaption, dd";
  const SEMANTIC = '[itemprop="articleBody"], article, [role="main"], main';

  function isVisible(element) {
    return element.getClientRects().length > 0 && getComputedStyle(element).visibility !== "hidden";
  }

  function textLength(element) {
    return (element.innerText || "").replace(/\s+/g, " ").trim().length;
  }

  function linkDensity(element) {
    const total = textLength(element);
    if (!total) return 1;
    let links = 0;
    for (const link of element.querySelectorAll("a")) links += textLength(link);
    return links / total;
  }

  function findArticle() {
    const scores = new Map();
    for (const block of document.body.querySelectorAll(BLOCKS)) {
      if (block.closest(`[${UI_ATTRIBUTE}], nav, header, footer, aside, form`)) continue;
      const length = (block.textContent || "").replace(/\s+/g, " ").trim().length;
      if (length < 25) continue;
      const score = 1 + Math.min(length, 1000) / 100;
      const parent = block.parentElement;
      if (parent) scores.set(parent, (scores.get(parent) || 0) + score);
      const grandparent = parent?.parentElement;
      if (grandparent) scores.set(grandparent, (scores.get(grandparent) || 0) + score / 2);
    }

    let best = null;
    let bestScore = 0;
    for (const [element, score] of scores) {
      if (element === document.body || element === document.documentElement || !isVisible(element)) continue;
      const adjusted = score * (1 - linkDensity(element));
      if (adjusted > bestScore) {
        best = element;
        bestScore = adjusted;
      }
    }
    if (!best) return null;

    // An enclosing <article> or <main> that adds little besides the article keeps its
    // title, byline and figures with it.
    const semantic = best.closest(SEMANTIC);
    if (semantic && semantic !== document.body && textLength(semantic) < textLength(best) * 1.6) {
      best = semantic;
    }
    return textLength(best) >= 200 ? best : null;
  }

  // Snapshot

  function absoluteURL(value) {
    try { return new URL(value, document.baseURI).href; } catch { return value; }
  }

  function absoluteSrcset(value) {
    return value.split(",").map((candidate) => {
      const [url, ...descriptor] = candidate.trim().split(/\s+/);
      return url ? [absoluteURL(url), ...descriptor].join(" ") : "";
    }).filter(Boolean).join(", ");
  }

  function absoluteCSSURLs(css) {
    return css.replace(/url\(\s*(['"]?)([^'")]+)\1\s*\)/g, (match, quote, url) =>
      url.startsWith("data:") ? match : `url(${quote}${absoluteURL(url)}${quote})`);
  }

  const LAZY_SOURCES = ["data-src", "data-original", "data-lazy-src", "data-actualsrc", "data-url", "data-echo", "data-hi-res-src"];

  function isPlaceholder(src) {
    return !src || (src.startsWith("data:") && src.length < 400) || src === "about:blank";
  }

  /// Fixes what only the live page knows: the image actually shown, lazy-loaded sources,
  /// style rules inserted by script, and form values. `original` is null for a selection.
  function fixElement(clone, original) {
    const tag = clone.tagName;
    if (tag === "SCRIPT" || tag === "NOSCRIPT" || clone.hasAttribute(UI_ATTRIBUTE)) {
      clone.remove();
      return;
    }

    for (const name of ["href", "src", "poster", "action", "data"]) {
      const value = clone.getAttribute(name);
      if (value && !/^(javascript|data|blob|mailto|tel):/i.test(value) && !value.startsWith("#")) {
        clone.setAttribute(name, absoluteURL(value));
      }
    }
    if (clone.hasAttribute("srcset")) clone.setAttribute("srcset", absoluteSrcset(clone.getAttribute("srcset")));
    if (clone.hasAttribute("style")) clone.setAttribute("style", absoluteCSSURLs(clone.getAttribute("style")));

    if (tag === "IMG") {
      const shown = original?.currentSrc;
      let src = shown && !isPlaceholder(shown) ? shown : clone.getAttribute("src");
      if (isPlaceholder(src)) {
        const lazy = LAZY_SOURCES.map((name) => clone.getAttribute(name)).find((value) => value && !isPlaceholder(value));
        if (lazy) src = lazy;
      }
      if (src && !isPlaceholder(src)) {
        clone.setAttribute("src", absoluteURL(src));
        if (shown && !isPlaceholder(shown)) {
          clone.removeAttribute("srcset");
          clone.removeAttribute("sizes");
        }
      }
      clone.removeAttribute("loading");
    } else if (tag === "STYLE") {
      // CSS-in-JS libraries leave the element empty and add rules with insertRule.
      // Otherwise keep the source text: cssText drops declarations this browser ignores.
      let css = clone.textContent;
      if (!css.trim() && original?.sheet) {
        try { css = [...original.sheet.cssRules].map((rule) => rule.cssText).join("\n"); } catch { /* unreadable */ }
      }
      clone.textContent = absoluteCSSURLs(css);
    } else if (tag === "INPUT" && original) {
      if (original.type === "checkbox" || original.type === "radio") {
        if (original.checked) clone.setAttribute("checked", "");
      } else if (original.type !== "password") {
        clone.setAttribute("value", original.value);
      }
    } else if (tag === "TEXTAREA" && original) {
      clone.textContent = original.value;
    } else if (tag === "CANVAS" && original) {
      try {
        const image = document.createElement("img");
        image.src = original.toDataURL("image/png");
        image.width = original.width;
        image.height = original.height;
        clone.replaceWith(image);
      } catch { /* a canvas with cross-origin pixels cannot be read */ }
    }
  }

  function cloneWithFixes(original) {
    const clone = original.cloneNode(true);
    const originals = [original, ...original.querySelectorAll("*")];
    const clones = [clone, ...clone.querySelectorAll("*")];
    for (let index = clones.length - 1; index >= 0; index -= 1) {
      fixElement(clones[index], originals[index]);
    }
    return clone;
  }

  function headHTML(title) {
    const head = cloneWithFixes(document.head);
    for (const sheet of document.adoptedStyleSheets || []) {
      try {
        const style = document.createElement("style");
        style.textContent = absoluteCSSURLs([...sheet.cssRules].map((rule) => rule.cssText).join("\n"));
        head.append(style);
      } catch { /* unreadable sheet */ }
    }
    let titleElement = head.querySelector("title");
    if (!titleElement) {
      titleElement = document.createElement("title");
      head.prepend(titleElement);
    }
    titleElement.textContent = title || document.title;
    return '<meta charset="utf-8">' + head.innerHTML;
  }

  function htmlAttributes() {
    const attributes = [...document.documentElement.attributes]
      .filter((attribute) => ["lang", "dir", "class"].includes(attribute.name))
      .map((attribute) => `${attribute.name}="${attribute.value.replace(/&/g, "&amp;").replace(/"/g, "&quot;")}"`);
    return attributes.length ? " " + attributes.join(" ") : "";
  }

  function documentHTML(title, bodyHTML) {
    return `<!DOCTYPE html><html${htmlAttributes()}><head>${headHTML(title)}</head>${bodyHTML}</html>`;
  }

  function snapshotPage(title) {
    return documentHTML(title, cloneWithFixes(document.body).outerHTML);
  }

  function snapshotElement(element, title) {
    return documentHTML(title, `<body>${cloneWithFixes(element).outerHTML}</body>`);
  }

  const BLOCK_TAGS = /^(P|DIV|SECTION|ARTICLE|UL|OL|LI|TABLE|PRE|BLOCKQUOTE|H[1-6]|FIGURE|DL|HR|IMG|PICTURE)$/;

  function snapshotSelection(ranges, title) {
    const container = document.createElement("div");
    for (const range of ranges) {
      const fragment = range.cloneContents();
      const holder = document.createElement("div");
      holder.append(fragment);
      [...holder.querySelectorAll("*")].reverse().forEach((element) => fixElement(element, null));

      // Text cut from inside a paragraph or code block keeps that block around it.
      const ancestor = range.commonAncestorContainer.nodeType === Node.ELEMENT_NODE
        ? range.commonAncestorContainer
        : range.commonAncestorContainer.parentElement;
      const pre = ancestor?.closest("pre");
      const hasBlocks = [...holder.children].some((child) => BLOCK_TAGS.test(child.tagName));
      if (pre) {
        const wrapper = document.createElement("pre");
        wrapper.append(...holder.childNodes);
        container.append(wrapper);
      } else if (!hasBlocks) {
        const wrapper = document.createElement("p");
        wrapper.append(...holder.childNodes);
        container.append(wrapper);
      } else {
        container.append(...holder.childNodes);
      }
    }
    return documentHTML(title, `<body>${container.innerHTML}</body>`);
  }

  async function fetchPDF(url) {
    const response = await fetch(url, { credentials: "include" });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const blob = await response.blob();
    const head = new Uint8Array(await blob.slice(0, 1024).arrayBuffer());
    if (!String.fromCharCode(...head).includes("%PDF-")) throw new Error("not a PDF");
    // Messages to the extension are capped near 64 MB; Freddie downloads larger files itself.
    if (blob.size > 45 * 1024 * 1024) return null;
    return new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onload = () => resolve(String(reader.result).split(",", 2)[1]);
      reader.onerror = () => reject(reader.error);
      reader.readAsDataURL(blob);
    });
  }

  globalThis.FreddieClipperCore = {
    UI_ATTRIBUTE,
    readMetadata,
    findArticle,
    textLength,
    snapshotPage,
    snapshotElement,
    snapshotSelection,
    fetchPDF
  };
})();
