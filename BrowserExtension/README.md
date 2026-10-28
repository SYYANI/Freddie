# Freddie Clipper

A browser extension that saves what you are reading into the Freddie library, in the spirit of
the Zotero Connector and the Evernote Web Clipper. It captures the page as you see it — signed
in, after scripts have run — so it works on pages that Freddie's "Add by URL" cannot fetch.

## Install (Chrome, Edge, Arc, Brave)

1. Open `chrome://extensions` (or `edge://extensions`) and turn on **Developer mode**.
2. Click **Load unpacked** and choose this `BrowserExtension` folder in the repository.
3. Optionally pin the extension. The default shortcut is ⌥⇧F.

After changing the extension's files, click the reload button on the extensions page and reload
the pages you clip from.

## Use

Click the toolbar button, press ⌥⇧F, or right-click a page or selection. A panel appears in the
top-right corner:

| Mode      | Saves                                                                                   |
|-----------|-----------------------------------------------------------------------------------------|
| arXiv     | On arxiv.org: imports the paper by ID (PDF, HTML and metadata), like Add by arXiv ID.   |
| PDF       | The PDF the tab shows, or the one the page declares in `citation_pdf_url`, fetched with your sign-in. |
| Article   | The highlighted region, simplified with Readability. ↑ / ↓ widen or narrow it.          |
| Selection | Exactly the selected text and images.                                                   |
| Full Page | The whole page in its own layout.                                                       |

Edit the title, pick a folder (remembered for next time), and press Return or **Save**. Saving
a page that is already in the library offers **Open in Freddie** or **Save Again**; a PDF of a
page you clipped earlier (or the other way round) joins the same paper.

Author, DOI, date and abstract come from the page's `citation_*`, Dublin Core, Open Graph and
JSON-LD metadata.

## How it talks to Freddie

Freddie listens on `http://127.0.0.1:23240` while it runs (`BrowserClipperServer.swift`).
The cross-platform Freddie (`FreddieGeneral`, Electron) serves the same API on the same port
(`electron/main/clipperServer.ts`), so this extension works with either app; if both run,
whichever started first receives the clips.
The background service worker makes every request, since a page's own scripts may not reach
the loopback address:

| Request          | Body / result                                                              |
|------------------|----------------------------------------------------------------------------|
| `GET /ping`      | `{ "app": "Freddie", "version", "api": 1 }`                                 |
| `GET /folders`   | `{ "folders": [{ "id", "name" }] }`                                         |
| `POST /save`     | A clip (see `BrowserClip` in `BrowserClipImporter.swift`) → `{ "status": "saved" \| "exists", "paperID", "title" }` |

Every request must carry `X-Freddie-Clipper: 1`, a `Host` of `127.0.0.1:23240` or
`localhost:23240`, and, if it has an `Origin`, an extension origin. Web pages cannot send the
custom header without a CORS preflight the server never approves, and the host check stops DNS
rebinding.

**Open in Freddie** opens `readpaper://paper/{paperID}`. It has to be a link the browser opens:
since macOS 14 an app in the background cannot bring itself forward, so a request to the server
could select the paper but not show it. The browser asks once per site before opening the link.
Likewise, if Freddie is not running, **Open Freddie** opens `readpaper://clipper` to launch it
and then waits for the server.

## Files

- `manifest.json`, `background.js`: Manifest V3 extension; the worker injects the panel and
  forwards API calls.
- `content/clipper-core.js`: metadata, article detection and the DOM snapshot (lazy images,
  CSS-in-JS rules, absolute URLs, form values, canvases).
- `content/clipper-panel.js`: the in-page panel, in a shadow root.
- `_locales/en`, `_locales/zh_CN`: strings.

Not yet supported: Safari (needs a Safari Web Extension target in the Xcode project), Firefox
packaging, and PDFs larger than about 45 MB that the browser alone can download (Freddie then
downloads them itself, without your sign-in).
