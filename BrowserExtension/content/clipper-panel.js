// The clipping panel shown on the page. It lives in a shadow root so page styles cannot
// reach it, and everything it adds to the page carries the UI attribute so snapshots skip it.
(() => {
  if (globalThis.FreddieClipperPanel) return;

  const core = globalThis.FreddieClipperCore;
  const UI = core.UI_ATTRIBUTE;
  const HIGHLIGHT_NAME = "freddie-clip-selection";
  const FOLDER_KEY = "freddie.folderID";
  const t = (key, ...substitutions) => chrome.i18n.getMessage(key, substitutions.map(String)) || key;

  let state = null;

  chrome.runtime.onMessage.addListener((message) => {
    if (message?.type !== "freddie:toggle") return;
    if (!state) {
      open(message.mode);
    } else if (message.mode && state.modes.includes(message.mode)) {
      setMode(message.mode);
    } else {
      close();
    }
  });

  // Lifecycle

  function open(requestedMode) {
    const metadata = core.readMetadata();
    const modes = [];
    if (metadata.arxivID) modes.push("arxiv");
    if (metadata.isPDF || metadata.pdfURL) modes.push("pdf");
    if (!metadata.isPDF) modes.push("article", "selection", "page");

    state = {
      metadata,
      modes,
      mode: null,
      article: metadata.isPDF ? null : core.findArticle(),
      articleTrail: [],
      ranges: selectionRanges(),
      title: metadata.isPDF ? "" : metadata.title,
      folders: [],
      folderID: "",
      phase: "edit",
      message: "",
      result: null,
      frame: 0
    };

    buildPanel();
    const initial = modes.includes(requestedMode) ? requestedMode
      : (state.ranges.length && modes.includes("selection") ? "selection" : modes[0]);
    setMode(initial);
    loadFolders();

    document.addEventListener("selectionchange", onSelectionChange);
    window.addEventListener("keydown", onKeyDown, true);
    window.addEventListener("scroll", scheduleOverlay, { capture: true, passive: true });
    window.addEventListener("resize", scheduleOverlay, { passive: true });
  }

  function close() {
    if (!state) return;
    cancelAnimationFrame(state.frame);
    state.host.remove();
    state.overlay.remove();
    state.highlightStyle?.remove();
    globalThis.CSS?.highlights?.delete(HIGHLIGHT_NAME);
    document.removeEventListener("selectionchange", onSelectionChange);
    window.removeEventListener("keydown", onKeyDown, true);
    window.removeEventListener("scroll", scheduleOverlay, true);
    window.removeEventListener("resize", scheduleOverlay);
    state = null;
  }

  // Selection

  function selectionRanges() {
    const selection = document.getSelection();
    const ranges = [];
    for (let index = 0; index < (selection?.rangeCount || 0); index += 1) {
      const range = selection.getRangeAt(index);
      if (range.collapsed || (state?.host && range.intersectsNode(state.host))) continue;
      if (!range.toString().trim() && !range.cloneContents().querySelector("img")) continue;
      ranges.push(range.cloneRange());
    }
    return ranges;
  }

  function onSelectionChange() {
    // Clicking into the panel collapses the page selection; keep the last real one.
    const ranges = selectionRanges();
    if (!ranges.length) return;
    state.ranges = ranges;
    if (state.mode === "selection") updateModeDetails();
  }

  function showSelectionHighlight(visible) {
    const highlights = globalThis.CSS?.highlights;
    if (!highlights || typeof Highlight === "undefined") return;
    if (!visible || !state.ranges.length) {
      highlights.delete(HIGHLIGHT_NAME);
      return;
    }
    if (!state.highlightStyle) {
      state.highlightStyle = document.createElement("style");
      state.highlightStyle.setAttribute(UI, "");
      state.highlightStyle.textContent = `::highlight(${HIGHLIGHT_NAME}) { background-color: rgba(215, 55, 63, 0.24); }`;
      document.documentElement.append(state.highlightStyle);
    }
    highlights.set(HIGHLIGHT_NAME, new Highlight(...state.ranges));
  }

  // Article region

  // Wrappers within 2px of what they wrap are one step, as in Freddie's region editor;
  // otherwise a key press could change nothing visible.
  function sameBox(a, b) {
    const first = a.getBoundingClientRect();
    const second = b.getBoundingClientRect();
    return ["top", "left", "bottom", "right"].every((edge) => Math.abs(first[edge] - second[edge]) <= 2);
  }

  function adjustArticle(direction) {
    if (!state.article) return;
    const start = state.article;
    if (direction === "up") {
      let next = start;
      do {
        const parent = next.parentElement;
        if (!parent || parent === document.body || parent === document.documentElement) break;
        next = parent;
      } while (sameBox(next, start));
      if (next === start || sameBox(next, start)) return;
      state.articleTrail.push(start);
      state.article = next;
    } else if (state.articleTrail.length) {
      state.article = state.articleTrail.pop();
    } else {
      let next = start;
      do {
        const child = [...next.children]
          .filter((element) => element.getClientRects().length && core.textLength(element))
          .sort((a, b) => core.textLength(b) - core.textLength(a))[0];
        if (!child) break;
        next = child;
      } while (sameBox(next, start));
      if (next === start || sameBox(next, start)) return;
      state.article = next;
    }
    const rect = state.article.getBoundingClientRect();
    if (rect.bottom < 0 || rect.top > innerHeight) {
      state.article.scrollIntoView({ block: "start", behavior: "smooth" });
    }
    scheduleOverlay();
  }

  function scheduleOverlay() {
    if (!state) return;
    cancelAnimationFrame(state.frame);
    state.frame = requestAnimationFrame(updateOverlay);
  }

  function updateOverlay() {
    if (!state) return;
    const finished = state.phase === "saved" || state.phase === "exists";
    const target = state.mode === "article" && !finished ? state.article : null;
    if (!target || !target.isConnected) {
      state.overlay.style.display = "none";
      return;
    }
    const rect = target.getBoundingClientRect();
    Object.assign(state.overlay.style, {
      display: "block",
      top: `${rect.top - 6}px`,
      left: `${rect.left - 6}px`,
      width: `${rect.width + 12}px`,
      height: `${rect.height + 12}px`
    });
  }

  // Panel

  function buildPanel() {
    const overlay = document.createElement("div");
    overlay.setAttribute(UI, "");
    overlay.style.cssText = [
      "position: fixed", "display: none", "pointer-events: none", "z-index: 2147483646",
      "border-radius: 8px", "border: 2px solid #d7373f",
      "box-shadow: 0 0 0 200vmax rgba(20, 20, 24, 0.32)",
      "transition: top .16s ease, left .16s ease, width .16s ease, height .16s ease"
    ].join(";");
    document.documentElement.append(overlay);

    const host = document.createElement("div");
    host.setAttribute(UI, "");
    host.style.cssText = "position: fixed; top: 16px; right: 16px; z-index: 2147483647;";
    const root = host.attachShadow({ mode: "open" });
    root.innerHTML = `
      <style>${PANEL_CSS}</style>
      <div class="panel" role="dialog" aria-label="${escapeHTML(t("actionTitle"))}">
        <div class="header">
          <span class="brand">${BRAND_ICON}<span>Freddie</span></span>
          <span class="subtitle">${escapeHTML(t("panelTitle"))}</span>
          <button class="close" type="button" title="${escapeHTML(t("close"))}" aria-label="${escapeHTML(t("close"))}">${CLOSE_ICON}</button>
        </div>
        <div class="editor">
          <div class="modes" role="tablist"></div>
          <p class="hint"></p>
          <label class="field"><span>${escapeHTML(t("labelTitle"))}</span><input class="title" type="text" spellcheck="false"></label>
          <p class="meta"></p>
          <label class="field"><span>${escapeHTML(t("labelFolder"))}</span><select class="folder"></select></label>
        </div>
        <div class="status" role="status" aria-live="polite"></div>
        <div class="footer"></div>
        <p class="shortcuts">${escapeHTML(t("shortcutsHint"))}</p>
      </div>`;
    document.documentElement.append(host);

    state.host = host;
    state.overlay = overlay;
    state.root = root;
    state.panel = root.querySelector(".panel");

    root.querySelector(".close").addEventListener("click", close);
    const title = root.querySelector(".title");
    title.value = state.title;
    title.addEventListener("input", () => { state.title = title.value; });
    root.querySelector(".folder").addEventListener("change", (event) => {
      state.folderID = event.target.value;
      chrome.storage.local.set({ [FOLDER_KEY]: state.folderID }).catch(() => {});
    });

    const modes = root.querySelector(".modes");
    for (const mode of state.modes) {
      const button = document.createElement("button");
      button.type = "button";
      button.dataset.mode = mode;
      button.setAttribute("role", "tab");
      button.textContent = t(MODE_LABELS[mode]);
      button.addEventListener("click", () => setMode(mode));
      modes.append(button);
    }
    modes.hidden = state.modes.length < 2;
    renderMeta();
    renderFolders();
  }

  const MODE_LABELS = {
    arxiv: "modeArxiv",
    pdf: "modePDF",
    article: "modeArticle",
    selection: "modeSelection",
    page: "modePage"
  };

  function setMode(mode) {
    state.mode = mode;
    for (const button of state.root.querySelectorAll(".modes button")) {
      const selected = button.dataset.mode === mode;
      button.classList.toggle("selected", selected);
      button.setAttribute("aria-selected", String(selected));
    }
    const title = state.root.querySelector(".title");
    title.closest(".field").hidden = mode === "arxiv";
    title.placeholder = mode === "pdf" && state.metadata.isPDF ? t("titlePlaceholderPDF") : t("titlePlaceholder");
    if (state.phase === "error") setPhase("edit");
    updateModeDetails();
  }

  function updateModeDetails() {
    const hint = state.root.querySelector(".hint");
    switch (state.mode) {
      case "arxiv":
        hint.textContent = t("hintArxiv", state.metadata.arxivID);
        break;
      case "pdf":
        hint.textContent = t("hintPDF", shortURL(state.metadata.isPDF ? location.href : state.metadata.pdfURL));
        break;
      case "article":
        hint.textContent = t(state.article ? "hintArticle" : "hintArticleMissing");
        break;
      case "selection":
        hint.textContent = t(state.ranges.length ? "hintSelection" : "hintSelectionEmpty");
        break;
      default:
        hint.textContent = t("hintPage");
    }
    showSelectionHighlight(state.mode === "selection");
    renderFooter();
    scheduleOverlay();
  }

  function renderMeta() {
    const { authors, siteName, doi, publishedDate } = state.metadata;
    const parts = [];
    if (authors.length) parts.push(authors.length > 3 ? `${authors.slice(0, 3).join(", ")} …` : authors.join(", "));
    if (publishedDate) parts.push(String(publishedDate).slice(0, 10));
    if (siteName) parts.push(siteName);
    if (doi) parts.push(`DOI ${doi}`);
    const meta = state.root.querySelector(".meta");
    meta.textContent = parts.join(" · ");
    meta.hidden = !parts.length;
  }

  function renderFolders() {
    const select = state.root.querySelector(".folder");
    select.replaceChildren(new Option(t("folderUnfiled"), ""));
    for (const folder of state.folders) select.append(new Option(folder.name, folder.id));
    if (!state.folders.some((folder) => folder.id === state.folderID)) state.folderID = "";
    select.value = state.folderID;
  }

  function canSave() {
    switch (state.mode) {
      case "article": return Boolean(state.article);
      case "selection": return state.ranges.length > 0;
      default: return true;
    }
  }

  function setPhase(phase, message = "") {
    state.phase = phase;
    state.message = message;
    state.panel.dataset.phase = phase;
    state.root.querySelector(".shortcuts").hidden = phase !== "edit" && phase !== "error";
    renderFooter();
    scheduleOverlay();
  }

  function renderFooter() {
    const status = state.root.querySelector(".status");
    const footer = state.root.querySelector(".footer");
    const button = (label, action, primary = false, disabled = false) => {
      const element = document.createElement("button");
      element.type = "button";
      element.textContent = label;
      element.className = primary ? "primary" : "secondary";
      element.disabled = disabled;
      element.addEventListener("click", action);
      return element;
    };

    status.className = "status";
    status.replaceChildren();
    switch (state.phase) {
      case "saving":
      case "connecting":
        status.classList.add("busy");
        status.append(spinner(), document.createTextNode(state.message || t("saving")));
        footer.replaceChildren(button(t("cancel"), close), button(t("save"), () => {}, true, true));
        break;
      case "saved":
        status.classList.add("success");
        status.innerHTML = `${CHECK_ICON}<span><strong></strong><em></em></span>`;
        status.querySelector("strong").textContent = t("saved");
        status.querySelector("em").textContent = state.result.title;
        footer.replaceChildren(button(t("done"), close), button(t("openInFreddie"), openInFreddie, true));
        break;
      case "exists":
        status.classList.add("notice");
        status.innerHTML = "<span><strong></strong><em></em></span>";
        status.querySelector("strong").textContent = t("exists");
        status.querySelector("em").textContent = state.result.title;
        footer.replaceChildren(
          button(t("saveAnyway"), () => save(true), false, state.mode === "arxiv"),
          button(t("openInFreddie"), openInFreddie, true)
        );
        break;
      case "offline":
        status.classList.add("error");
        status.textContent = t("offline");
        footer.replaceChildren(button(t("retry"), retryConnection), button(t("launch"), launchFreddie, true));
        break;
      case "error":
        status.classList.add("error");
        status.textContent = state.message;
        footer.replaceChildren(button(t("cancel"), close), button(t("save"), () => save(false), true, !canSave()));
        break;
      default:
        footer.replaceChildren(button(t("cancel"), close), button(t("save"), () => save(false), true, !canSave()));
    }
  }

  // Talking to Freddie

  async function api(method, path, body) {
    try {
      return await chrome.runtime.sendMessage({ type: "freddie:api", method, path, body });
    } catch (error) {
      // The extension was reloaded or updated under this page.
      return { ok: false, status: 0, data: { error: String(error) } };
    }
  }

  async function loadFolders() {
    const [response, stored] = await Promise.all([
      api("GET", "/folders"),
      chrome.storage.local.get(FOLDER_KEY).catch(() => ({}))
    ]);
    if (!state) return;
    if (response.offline) {
      setPhase("offline");
      return;
    }
    state.folders = response.data?.folders || [];
    state.folderID = stored[FOLDER_KEY] || "";
    renderFolders();
  }

  async function buildPayload() {
    const { metadata } = state;
    const title = state.title.trim();
    const details = {
      authors: metadata.authors,
      doi: metadata.doi,
      abstract: metadata.abstract,
      publishedDate: metadata.publishedDate
    };
    switch (state.mode) {
      case "arxiv":
        return { kind: "arxiv", url: location.href };
      case "pdf": {
        const pdfURL = metadata.isPDF ? location.href : metadata.pdfURL;
        setPhase("saving", t("fetchingPDF"));
        // Fetched here to carry the reader's sign-in; Freddie downloads it otherwise.
        const pdfBase64 = await core.fetchPDF(pdfURL).catch(() => null);
        return { kind: "pdf", url: location.href, title, pdfURL, pdfBase64, metadata: details };
      }
      case "article":
        return state.article && { kind: "html", url: location.href, title, extraction: "article", html: core.snapshotElement(state.article, title), metadata: details };
      case "selection":
        return state.ranges.length && { kind: "html", url: location.href, title, extraction: "selection", html: core.snapshotSelection(state.ranges, title), metadata: details };
      default:
        return { kind: "html", url: location.href, title, extraction: "page", html: core.snapshotPage(title), metadata: details };
    }
  }

  async function save(allowDuplicate) {
    if (!state || state.phase === "saving") return;
    setPhase("saving");
    let payload;
    try {
      payload = await buildPayload();
    } catch (error) {
      setPhase("error", t("saveFailed", error.message || error));
      return;
    }
    if (!payload) {
      setPhase("error", t("nothingToClip"));
      return;
    }
    setPhase("saving");
    const response = await api("POST", "/save", { ...payload, folderID: state.folderID || null, allowDuplicate });
    if (!state) return;
    if (response.offline) {
      setPhase("offline");
    } else if (!response.ok) {
      setPhase("error", t("saveFailed", response.data?.error || `HTTP ${response.status}`));
    } else {
      state.result = response.data;
      setPhase(response.data.status === "exists" ? "exists" : "saved");
    }
  }

  function openInFreddie() {
    // A link the browser opens lets macOS bring Freddie forward; Freddie cannot come
    // forward on its own while the browser is the active app.
    if (state?.result) location.href = `readpaper://paper/${state.result.paperID}`;
    close();
  }

  async function retryConnection() {
    setPhase("connecting", t("connecting"));
    for (let attempt = 0; attempt < 20 && state; attempt += 1) {
      const response = await api("GET", "/ping");
      if (!state) return;
      if (!response.offline) {
        setPhase("edit");
        loadFolders();
        return;
      }
      await new Promise((resolve) => setTimeout(resolve, 1000));
    }
    if (state) setPhase("offline");
  }

  function launchFreddie() {
    // Freddie registers readpaper://; a link it does not recognize only launches it.
    location.href = "readpaper://clipper";
    retryConnection();
  }

  // Keyboard

  function onKeyDown(event) {
    const target = event.composedPath()[0];
    const inPanel = target instanceof Node && (state.host.contains(target) || state.root.contains(target));
    const editing = target instanceof HTMLElement
      && (target.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(target.tagName));
    if (event.key === "Escape") {
      event.preventDefault();
      event.stopPropagation();
      close();
    } else if (event.key === "Enter" && (inPanel || !editing) && target.tagName !== "BUTTON" && target.tagName !== "SELECT") {
      if (state.phase !== "edit" && state.phase !== "error") return;
      event.preventDefault();
      event.stopPropagation();
      save(false);
    } else if ((event.key === "ArrowUp" || event.key === "ArrowDown") && state.mode === "article" && !editing) {
      event.preventDefault();
      event.stopPropagation();
      adjustArticle(event.key === "ArrowUp" ? "up" : "down");
    }
  }

  // Helpers

  function shortURL(value) {
    try {
      const url = new URL(value);
      const name = url.pathname.split("/").filter(Boolean).pop() || "";
      return name ? `${url.hostname} › ${decodeURIComponent(name)}` : url.hostname;
    } catch {
      return value || "";
    }
  }

  function escapeHTML(value) {
    return String(value).replace(/[&<>"]/g, (character) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[character]);
  }

  function spinner() {
    const element = document.createElement("span");
    element.className = "spinner";
    return element;
  }

  const BRAND_ICON = `<svg viewBox="0 0 20 20" aria-hidden="true"><rect x="3" y="2" width="14" height="16" rx="3" fill="#fff" stroke="currentColor" stroke-opacity=".25"/><path d="M6 7h7M6 10h5" stroke="currentColor" stroke-opacity=".35" stroke-width="1.4" stroke-linecap="round"/><path d="M5 15.5c3-2.6 6.2-1 8.6-4.6l1.6 1.2c-2.4 3.8-6.4 2.8-9.2 5z" fill="#d7373f"/></svg>`;
  const CLOSE_ICON = `<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M4 4l8 8M12 4l-8 8" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/></svg>`;
  const CHECK_ICON = `<svg class="check" viewBox="0 0 20 20" aria-hidden="true"><circle cx="10" cy="10" r="9" fill="#2f9e5b"/><path d="M6 10.4l2.6 2.6L14.2 7.4" fill="none" stroke="#fff" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg>`;

  const PANEL_CSS = `
    :host { all: initial; }
    .panel {
      --accent: #d7373f;
      --text: #1d1d1f;
      --muted: #6e6e73;
      --field: rgba(255, 255, 255, 0.72);
      --hairline: rgba(0, 0, 0, 0.12);
      --surface: rgba(248, 248, 250, 0.9);
      box-sizing: border-box;
      width: 344px;
      padding: 14px 14px 10px;
      border-radius: 16px;
      border: 0.5px solid var(--hairline);
      background: var(--surface);
      backdrop-filter: blur(28px) saturate(180%);
      -webkit-backdrop-filter: blur(28px) saturate(180%);
      box-shadow: 0 18px 50px rgba(0, 0, 0, 0.22), 0 2px 8px rgba(0, 0, 0, 0.08);
      color: var(--text);
      font: 13px/1.4 -apple-system, BlinkMacSystemFont, "PingFang SC", "Helvetica Neue", system-ui, sans-serif;
      -webkit-font-smoothing: antialiased;
    }
    @media (prefers-color-scheme: dark) {
      .panel {
        --text: #f5f5f7;
        --muted: #a1a1a6;
        --field: rgba(255, 255, 255, 0.08);
        --hairline: rgba(255, 255, 255, 0.14);
        --surface: rgba(40, 40, 44, 0.9);
      }
    }
    * { box-sizing: border-box; }
    [hidden] { display: none !important; }
    .header { display: flex; align-items: center; gap: 6px; margin-bottom: 12px; }
    .brand { display: inline-flex; align-items: center; gap: 6px; font-weight: 600; font-size: 14px; }
    .brand svg { width: 20px; height: 20px; color: var(--text); }
    .subtitle { color: var(--muted); font-size: 13px; }
    .close {
      margin-left: auto; width: 24px; height: 24px; padding: 4px; border: 0; border-radius: 12px;
      background: transparent; color: var(--muted); cursor: pointer;
    }
    .close:hover { background: var(--hairline); color: var(--text); }
    .close svg { width: 16px; height: 16px; display: block; }
    .modes {
      display: flex; padding: 2px; gap: 2px; margin-bottom: 8px;
      border-radius: 9px; background: var(--hairline);
    }
    .modes button {
      flex: 1 1 0; min-width: 0; padding: 5px 4px; border: 0; border-radius: 7px;
      background: transparent; color: var(--text); font: inherit; font-size: 12px; font-weight: 500;
      white-space: nowrap; overflow: hidden; text-overflow: ellipsis; cursor: pointer;
    }
    .modes button:hover:not(.selected) { background: var(--field); }
    .modes button.selected { background: var(--accent); color: #fff; box-shadow: 0 1px 2px rgba(0, 0, 0, 0.18); }
    .hint { margin: 0 0 12px; color: var(--muted); font-size: 12px; min-height: 17px; }
    .field { display: grid; grid-template-columns: 52px 1fr; align-items: center; gap: 8px; margin-bottom: 8px; }
    .field > span { color: var(--muted); font-size: 12px; }
    input, select {
      width: 100%; min-width: 0; height: 28px; padding: 0 8px; border-radius: 7px;
      border: 0.5px solid var(--hairline); background: var(--field); color: var(--text);
      font: inherit; outline: none;
    }
    input:focus, select:focus { border-color: var(--accent); box-shadow: 0 0 0 3px rgba(215, 55, 63, 0.18); }
    .meta {
      margin: -2px 0 10px 60px; color: var(--muted); font-size: 11.5px;
      overflow: hidden; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical;
    }
    .status { display: flex; align-items: flex-start; gap: 8px; font-size: 12.5px; }
    .status:empty { display: none; }
    .status.busy { color: var(--muted); align-items: center; margin: 4px 0 2px; }
    .status.error { color: #c4302b; margin: 2px 0 4px; }
    .status.success, .status.notice { margin: 2px 0 6px; }
    .status strong { display: block; font-weight: 600; }
    .status em { display: block; font-style: normal; color: var(--muted); margin-top: 2px;
      overflow: hidden; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; }
    .check { width: 20px; height: 20px; flex: none; }
    .panel[data-phase="saved"] .editor, .panel[data-phase="exists"] .editor { display: none; }
    .spinner {
      width: 14px; height: 14px; flex: none; border-radius: 50%;
      border: 2px solid var(--hairline); border-top-color: var(--accent);
      animation: spin 0.8s linear infinite;
    }
    @keyframes spin { to { transform: rotate(360deg); } }
    .footer { display: flex; justify-content: flex-end; gap: 8px; margin-top: 12px; }
    .footer button {
      height: 28px; padding: 0 14px; border-radius: 7px; font: inherit; font-weight: 500; cursor: pointer;
      border: 0.5px solid var(--hairline);
    }
    .footer .secondary { background: var(--field); color: var(--text); }
    .footer .primary { background: var(--accent); border-color: transparent; color: #fff; }
    .footer .primary:hover:not(:disabled) { filter: brightness(1.06); }
    .footer button:disabled { opacity: 0.45; cursor: default; }
    .shortcuts { margin: 8px 0 0; text-align: right; color: var(--muted); font-size: 11px; opacity: 0.8; }
  `;

  globalThis.FreddieClipperPanel = { open, close };
})();
