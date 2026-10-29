// Talks to Freddie's local API (BrowserClipperServer in the app) on behalf of the
// in-page panel: a web page's own context may not reach 127.0.0.1, the extension may.

const API = "http://127.0.0.1:23240";
const API_HEADER = "X-Freddie-Clipper";
const API_VERSION = "1";

chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.create({
    id: "freddie-clip-page",
    title: chrome.i18n.getMessage("menuClipPage"),
    contexts: ["page", "frame", "link", "image"]
  });
  chrome.contextMenus.create({
    id: "freddie-clip-selection",
    title: chrome.i18n.getMessage("menuClipSelection"),
    contexts: ["selection"]
  });
});

chrome.action.onClicked.addListener((tab) => openClipper(tab, null));

chrome.contextMenus.onClicked.addListener((info, tab) => {
  if (!tab) return;
  openClipper(tab, info.menuItemId === "freddie-clip-selection" ? "selection" : null);
});

async function openClipper(tab, mode) {
  try {
    await chrome.scripting.executeScript({
      target: { tabId: tab.id },
      files: ["content/clipper-core.js", "content/clipper-panel.js"]
    });
    await chrome.tabs.sendMessage(tab.id, { type: "freddie:toggle", mode });
  } catch (error) {
    // Browser pages, the extension store and other extensions cannot be scripted.
    await chrome.action.setBadgeBackgroundColor({ tabId: tab.id, color: "#8a8a8a" });
    await chrome.action.setBadgeText({ tabId: tab.id, text: "×" });
    await chrome.action.setTitle({ tabId: tab.id, title: chrome.i18n.getMessage("cannotClip") });
  }
}

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.type !== "freddie:api") return false;
  callApp(message.method, message.path, message.body).then(sendResponse);
  return true;
});

async function callApp(method, path, body) {
  // Saving downloads the page's images and can outlast the service worker's idle timeout;
  // extension API calls reset that timer.
  const keepAlive = setInterval(() => chrome.runtime.getPlatformInfo(), 20000);
  try {
    const headers = { [API_HEADER]: API_VERSION };
    if (body !== undefined) headers["Content-Type"] = "application/json";
    const response = await fetch(API + path, {
      method,
      headers,
      body: body === undefined ? undefined : JSON.stringify(body),
      cache: "no-store"
    });
    const data = await response.json().catch(() => ({}));
    return { ok: response.ok, status: response.status, data };
  } catch (error) {
    return { ok: false, offline: true, error: String(error) };
  } finally {
    clearInterval(keepAlive);
  }
}
