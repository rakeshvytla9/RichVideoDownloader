const BRIDGE_URL = "http://127.0.0.1:38123";
const DEDUPE_WINDOW_MS = 60 * 1000;
const PROMPT_TTL_MS = 30 * 1000;
const SETTINGS_KEY = "settings";
const NOTIFICATION_ICON_DATA_URL = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/a4QAAAAASUVORK5CYII=";

const DEFAULT_SETTINGS = {
  browserDownloadMode: "ask", // ask | take_over | capture_only
  sniffMediaRequests: true
};

const recentHits = new Map();
const pendingDownloadPrompts = new Map();
const activeBackgroundDownloads = new Map(); // id -> timestamp

async function logToBridge(msg) {
  fetch(`${BRIDGE_URL}/relay_log`, {
    method: "POST",
    body: `[Relay SW] ${msg}`
  }).catch(() => {});
}

chrome.runtime.onInstalled.addListener(() => {
  chrome.storage.local.get([SETTINGS_KEY], (result) => {
    const stored = result[SETTINGS_KEY] || {};
    const hasLegacyTakeover = typeof stored.takeOverBrowserDownloads === "boolean";
    const migratedMode = stored.browserDownloadMode || (
      hasLegacyTakeover
        ? (stored.takeOverBrowserDownloads === true ? "take_over" : "capture_only")
        : DEFAULT_SETTINGS.browserDownloadMode
    );
    chrome.storage.local.set({
      [SETTINGS_KEY]: {
        ...DEFAULT_SETTINGS,
        ...stored,
        browserDownloadMode: migratedMode || DEFAULT_SETTINGS.browserDownloadMode
      }
    });
  });
});

function getSettings() {
  return new Promise((resolve) => {
    chrome.storage.local.get([SETTINGS_KEY], (result) => {
      const stored = result[SETTINGS_KEY] || {};
      const hasLegacyTakeover = typeof stored.takeOverBrowserDownloads === "boolean";
      const migratedMode = stored.browserDownloadMode || (
        hasLegacyTakeover
          ? (stored.takeOverBrowserDownloads === true ? "take_over" : "capture_only")
          : DEFAULT_SETTINGS.browserDownloadMode
      );
      resolve({
        ...DEFAULT_SETTINGS,
        ...stored,
        browserDownloadMode: migratedMode
      });
    });
  });
}

function isMediaByExtension(url) {
  return /\.(m3u8|mpd|mp4|m4v|webm|mov|m4a|mp3|aac)(\?|$)/i.test(url);
}

function isMediaByMime(details) {
  if (!details.responseHeaders) return false;

  for (const header of details.responseHeaders) {
    if (!header || !header.name || !header.value) continue;
    if (header.name.toLowerCase() !== "content-type") continue;

    const value = header.value.toLowerCase();
    if (
      value.includes("video/") ||
      value.includes("audio/") ||
      value.includes("application/vnd.apple.mpegurl") ||
      value.includes("application/dash+xml")
    ) {
      return true;
    }
  }

  return false;
}

function shouldCaptureMedia(details) {
  if (!details || !details.url) return false;
  if (details.url.startsWith("http://127.0.0.1:38123")) return false;

  if (details.type === "media") return true;
  if (isMediaByExtension(details.url)) return true;
  if (isMediaByMime(details)) return true;

  return false;
}

function isHttpUrl(url) {
  return /^https?:\/\//i.test(url);
}

function basename(path) {
  const normalized = String(path || "").replace(/\\/g, "/");
  const parts = normalized.split("/").filter(Boolean);
  return parts.length ? parts[parts.length - 1] : "";
}

function pruneRecentHits(now) {
  for (const [key, time] of recentHits.entries()) {
    if (now - time > DEDUPE_WINDOW_MS) {
      recentHits.delete(key);
    }
  }
}

function isDuplicate(key) {
  const now = Date.now();
  pruneRecentHits(now);

  const previous = recentHits.get(key);
  if (previous && now - previous < DEDUPE_WINDOW_MS) {
    return true;
  }

  recentHits.set(key, now);
  return false;
}

function getCookiesForUrl(url) {
  return new Promise((resolve) => {
    if (!isHttpUrl(url)) {
      resolve("");
      return;
    }

    chrome.cookies.getAll({ url }, (cookies) => {
      if (chrome.runtime.lastError || !Array.isArray(cookies) || cookies.length === 0) {
        resolve("");
        return;
      }

      const cookieHeader = cookies.map((cookie) => `${cookie.name}=${cookie.value}`).join("; ");
      resolve(cookieHeader);
    });
  });
}

function getTabDetails(tabId) {
  return new Promise((resolve) => {
    if (!Number.isInteger(tabId) || tabId < 0) {
      resolve({ pageUrl: "", tabTitle: "" });
      return;
    }

    chrome.tabs.get(tabId, (tab) => {
      if (chrome.runtime.lastError || !tab) {
        resolve({ pageUrl: "", tabTitle: "" });
        return;
      }

      resolve({
        pageUrl: tab.url || "",
        tabTitle: tab.title || ""
      });
    });
  });
}

async function pushCapture(payload) {
  try {
    const res = await fetch(`${BRIDGE_URL}/capture`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload)
    });
    if (!res.ok) {
      console.error("[RVD Bridge] Post failed with status:", res.status);
    } else {
      console.log("[RVD Bridge] Successfully pushed capture:", payload.mediaUrl);
    }
  } catch (err) {
    console.error("[RVD Bridge] Bridge offline or unreachable:", err.message);
  }
}

function cancelBrowserDownload(downloadId) {
  if (!Number.isInteger(downloadId)) return;

  chrome.downloads.cancel(downloadId, () => {
    // Ignore errors for completed/uncancellable downloads.
  });

  setTimeout(() => {
    chrome.downloads.erase({ id: downloadId }, () => {
      // Ignore erase errors.
    });
  }, 1200);
}

function notificationMessageForPayload(payload) {
  const fileName = payload.fileName || basename(payload.mediaUrl) || "this file";
  const shortUrl = String(payload.mediaUrl || "").slice(0, 120);
  return `Take over ${fileName} in RichVideoDownloader?\n${shortUrl}`;
}

function createPromptNotification(notificationId, payload) {
  return new Promise((resolve) => {
    chrome.notifications.create(notificationId, {
      type: "basic",
      iconUrl: NOTIFICATION_ICON_DATA_URL,
      title: "RichVideoDownloader",
      message: notificationMessageForPayload(payload),
      buttons: [
        { title: "Take over in app" },
        { title: "Keep in browser" }
      ],
      priority: 2
    }, () => {
      resolve(!chrome.runtime.lastError);
    });
  });
}

function clearPrompt(notificationId) {
  pendingDownloadPrompts.delete(notificationId);
  chrome.notifications.clear(notificationId, () => {
    // Ignore clear errors.
  });
}

async function finalizePromptChoice(notificationId, takeOver) {
  const pending = pendingDownloadPrompts.get(notificationId);
  if (!pending) return;

  pendingDownloadPrompts.delete(notificationId);
  await pushCapture(pending.payload);

  if (takeOver) {
    cancelBrowserDownload(pending.downloadId);
  }

  chrome.notifications.clear(notificationId, () => {
    // Ignore clear errors.
  });
}

function schedulePromptExpiry(notificationId) {
  setTimeout(async () => {
    const pending = pendingDownloadPrompts.get(notificationId);
    if (!pending) return;

    // Timeout defaults to keeping browser download, but still sends capture to app.
    await finalizePromptChoice(notificationId, false);
  }, PROMPT_TTL_MS);
}

chrome.notifications.onButtonClicked.addListener((notificationId, buttonIndex) => {
  if (!pendingDownloadPrompts.has(notificationId)) return;
  if (buttonIndex === 0) {
    void finalizePromptChoice(notificationId, true);
  } else {
    void finalizePromptChoice(notificationId, false);
  }
});

chrome.notifications.onClosed.addListener((notificationId) => {
  if (!pendingDownloadPrompts.has(notificationId)) return;
  pendingDownloadPrompts.delete(notificationId);
});

async function handleBrowserDownload(downloadItem, settings) {
  const targetUrl = downloadItem.url || downloadItem.finalUrl;
  const tabContext = await getTabDetails(downloadItem.tabId);
  const pageUrl = tabContext.pageUrl || downloadItem.referrer || "";
  const cookieHeader = await getCookiesForUrl(targetUrl || pageUrl);

  const payload = {
    mediaUrl: targetUrl,
    pageUrl,
    tabTitle: tabContext.tabTitle,
    resourceType: "download",
    captureSource: "browser_download",
    fileName: basename(downloadItem.filename) || basename(targetUrl),
    mimeType: downloadItem.mime || "",
    cookieHeader,
    userAgent: navigator.userAgent,
    timestamp: Date.now()
  };

  if (settings.browserDownloadMode === "ask") {
    const notificationId = `rvd_prompt_${downloadItem.id}_${Date.now()}`;
    pendingDownloadPrompts.set(notificationId, {
      downloadId: downloadItem.id,
      payload,
      createdAt: Date.now()
    });

    const shown = await createPromptNotification(notificationId, payload);
    if (!shown) {
      clearPrompt(notificationId);
      await pushCapture(payload);
      return;
    }

    schedulePromptExpiry(notificationId);
    return;
  }

  await pushCapture(payload);
  if (settings.browserDownloadMode === "take_over") {
    cancelBrowserDownload(downloadItem.id);
  }
}

chrome.webRequest.onCompleted.addListener(
  async (details) => {
    const settings = await getSettings();
    if (!settings.sniffMediaRequests) return;
    if (!shouldCaptureMedia(details)) return;

    const dedupeKey = `media:${details.url}`;
    if (isDuplicate(dedupeKey)) return;

    const tabContext = await getTabDetails(details.tabId);
    // Use initiator first, so embedded iframes send the right Referer instead of the top level page.
    const effectivePageUrl = details.initiator || tabContext.pageUrl || "";
    const cookieHeader = await getCookiesForUrl(details.url || effectivePageUrl);

    await pushCapture({
      mediaUrl: details.url,
      pageUrl: effectivePageUrl,
      tabTitle: tabContext.tabTitle,
      resourceType: details.type || "media",
      captureSource: "media_request",
      cookieHeader,
      userAgent: navigator.userAgent,
      timestamp: Date.now()
    });
  },
  { urls: ["<all_urls>"] },
  ["responseHeaders"]
);

chrome.downloads.onCreated.addListener(async (downloadItem) => {
  if (!downloadItem || !downloadItem.url || !isHttpUrl(downloadItem.url)) return;

  const settings = await getSettings();
  const targetUrl = downloadItem.url || downloadItem.finalUrl;
  const dedupeKey = `download:${targetUrl}`;
  if (isDuplicate(dedupeKey)) return;

  await handleBrowserDownload(downloadItem, settings);
});

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message.type === "PROXY_CHUNK") {
    const { id, chunk, progress, isFinish } = message;
    
    // chunk arrived as a plain Array from the injector
    const buffer = new Uint8Array(chunk);
    
    (async () => {
      try {
        await fetch(`${BRIDGE_URL}/chunk?id=${id}`, {
          method: "POST",
          body: buffer
        });
        await fetch(`${BRIDGE_URL}/progress?id=${id}&p=${progress}`, { method: "POST" });
        if (isFinish) {
          await fetch(`${BRIDGE_URL}/finish?id=${id}`, { method: "POST" });
        }
        sendResponse({ ok: true });
      } catch (err) {
        sendResponse({ ok: false, error: err.message });
      }
    })();
    return true; // Keep channel open for async response
  }

  if (message.type === "PROXY_LOG") {
    logToBridge(message.message);
    return;
  }

  if (message.type === "PROXY_ERROR") {
    const { id, message: errMsg } = message;
    console.error(`[RVD Bridge] Proxy error received from tab for ${id}:`, errMsg);
    activeBackgroundDownloads.delete(id);
    fetch(`${BRIDGE_URL}/error?id=${id}`, {
      method: "POST",
      body: errMsg
    }).catch(() => {});
    return;
  }

  if (message.type === "CAPTURE_TELEGRAM_MEDIA" && message.url) {
    console.log("[RVD ServiceWorker] Received capture from Telegram tab:", message.url);
    const tabId = sender.tab ? sender.tab.id : -1;
    
    getTabDetails(tabId).then(tabContext => {
      const pageUrl = tabContext.pageUrl || (sender.tab ? sender.tab.url : "");
      
      getCookiesForUrl(message.url || pageUrl).then(cookieHeader => {
        pushCapture({
          mediaUrl: message.url,
          pageUrl: pageUrl,
          tabTitle: tabContext.tabTitle || "Telegram Web",
          resourceType: "media",
          captureSource: "telegram_injector",
          fileName: message.fileName || "",
          mimeType: "",
          cookieHeader: cookieHeader,
          userAgent: navigator.userAgent,
          timestamp: Date.now()
        });
      });
    });
  }
});

const contentRangeRegex = /^bytes (\d+)-(\d+)\/(\d+)$/;

async function pollBridge() {
  try {
    const res = await fetch(`${BRIDGE_URL}/poll`);
    if (res.status === 200) {
      const command = await res.json();
      console.log("[RVD Bridge] Received command from bridge:", command);

      if (command.action === "download" && command.url) {
        const now = Date.now();
        if (activeBackgroundDownloads.has(command.id)) {
            const startTime = activeBackgroundDownloads.get(command.id);
            if (now - startTime < 60000) { // 1 minute timeout for stall
                console.log("[RVD Bridge] Download recently active, skipping:", command.id);
                return;
            } else {
                console.log("[RVD Bridge] Download stalled for >1m, allowing retry:", command.id);
            }
        }
 
        // Forward to the Telegram tab to fetch within its session context
        const tabs = await new Promise(r => chrome.tabs.query({ url: ["*://web.telegram.org/*", "*://*.t.me/*"] }, r));
        console.log(`[RVD Bridge] Found ${tabs.length} potential Telegram tabs to relay to.`);

        let relayed = false;
        for (const tab of tabs) {
          try {
            const reply = await chrome.tabs.sendMessage(tab.id, { 
              type: "START_PROXY_DOWNLOAD", 
              command: command 
            });
            logToBridge(`Command sent to tab ${tab.id}, reply: ${JSON.stringify(reply)}`);
            if (reply && reply.ack) {
              console.log(`[RVD Bridge] Tab ${tab.id} accepted the download.`);
              relayed = true;
              activeBackgroundDownloads.set(command.id, Date.now());
            }
          } catch (err) {
            console.warn(`[RVD Bridge] Failed to relay to tab ${tab.id}: ${err.message}`);
          }
        }

        if (!relayed) {
          console.error("[RVD Bridge] FAILED to delivery download to ANY tab.");
          fetch(`${BRIDGE_URL}/error?id=${command.id}`, {
            method: "POST",
            body: "[Bridge] No active Telegram tab found to handle the download."
          }).catch(() => {});
        }
      }
    }
  } catch (e) {
    if (Math.random() < 0.1) console.warn("[RVD Bridge] Poll failed:", e.message);
  }
  setTimeout(pollBridge, 2000);
}


pollBridge();
