/*
  ThunderRAG experiment API: parent.js

  Implements a custom nsIMsgFilterCustomAction ("Post Message To Endpoint") that
  intercepts incoming mail during Thunderbird filter execution, obtains the raw
  RFC822 bytes (with best-effort decryption for S/MIME and PGP), and POSTs them
  to the OCaml ingestion endpoint.

  Key challenges addressed here:
  - Acquiring a usable WebExtension API scope from privileged (experiment) code.
  - Decrypting encrypted mail in filter context where no UI msgWindow exists.
  - Patching the FilterEditor XUL dialog so the custom action shows a URL input.
  - Graceful fallback chains: background delegation → getRaw(decrypt) → streamMessage → convertData.
*/

const Cu = Components.utils;

/* Import a Mozilla module, preferring ESM (.sys.mjs) over legacy JSM. */
function importModule(mjsPath, jsmPath) {
  if (ChromeUtils.importESModule) {
    try {
      return ChromeUtils.importESModule(mjsPath);
    } catch (e) {
      // Fall through to legacy JSM import.
    }

  }
  return Cu.import(jsmPath);
}

/* Quick heuristic: does the string contain common HTML tags? */
function looksLikeHtmlText(s) {
  const t = String(s || "").trim().toLowerCase();
  return t.includes("<html") || t.includes("<body") || t.includes("<div") || t.includes("<p");
}

/* --- Mozilla module imports (ESM with JSM fallback) --- */
var { ExtensionCommon } = importModule(
  "resource://gre/modules/ExtensionCommon.sys.mjs",
  "resource://gre/modules/ExtensionCommon.jsm"
);
var { ExtensionParent } = importModule(
  "resource://gre/modules/ExtensionParent.sys.mjs",
  "resource://gre/modules/ExtensionParent.jsm"
);
var { MailServices } = importModule(
  "resource:///modules/MailServices.sys.mjs",
  "resource:///modules/MailServices.jsm"
);

/* MsgHdrToMimeMessage: parses a message through TB's MIME pipeline (with decryption). */
var MsgHdrToMimeMessage;
try {
  ({ MsgHdrToMimeMessage } = importModule(
    "resource:///modules/gloda/MimeMessage.sys.mjs",
    "resource:///modules/gloda/MimeMessage.jsm"
  ));
} catch (_e) {
  MsgHdrToMimeMessage = null;
}

/* Ensure web-platform globals (fetch, Blob, etc.) are available in this privileged scope. */
if (ChromeUtils.importGlobalProperties) {
  ChromeUtils.importGlobalProperties(["fetch", "Blob", "Headers", "TextDecoder", "TextEncoder"]);
} else if (Cu.importGlobalProperties) {
  Cu.importGlobalProperties(["fetch", "Blob", "Headers", "TextDecoder", "TextEncoder"]);
}

/* --- XPCOM service singletons --- */
const Cc = Components.classes;
const Ci = Components.interfaces;

const ioService = Cc["@mozilla.org/network/io-service;1"].getService(Ci.nsIIOService);
const obsService = Cc["@mozilla.org/observer-service;1"].getService(Ci.nsIObserverService);
const consoleService = Cc["@mozilla.org/consoleservice;1"].getService(Ci.nsIConsoleService);
const windowMediator = Cc["@mozilla.org/appshell/window-mediator;1"].getService(
  Ci.nsIWindowMediator
);

const BUILD_TAG = "ragFilterAction-parent-2026-02-02-01";
try {
  consoleService.logStringMessage(`[ragFilterAction] parent.js loaded build_tag=${BUILD_TAG}`);
} catch (_e) {
  // ignore
}

const ADDON_ID = "rag-filter-action@example.com";

/* Unique ID for the custom filter action registered with MailServices.filters. */
const ACTION_ID = "rag-filter-action@example.com#PostMessageToEndpoint";

/* Observer that patches newly-opened FilterEditor windows (see patchFilterEditorWindow). */
let filterEditorObserver = null;

/* Cached reference to the WebExtension API scope (browser/messenger object).
   Acquired lazily via cloneScope / GlobalManager probing. */
let webextScope = null;

/* The ExtensionAPI context saved from getAPI(), used to re-acquire scope later. */
let savedApiContext = null;

/*
  Extract readable body text from a MimeMessage tree returned by MsgHdrToMimeMessage.
  Walks the tree depth-first, preferring text/plain over text/html.
  Returns {kind, body} or null.
*/
function extractBodyFromMimeMessage(msg) {
  if (!msg) return null;
  let bestPlain = null;
  let bestHtml = null;

  function walk(part) {
    if (!part) return;
    const ct = String(part.contentType || "").toLowerCase();
    const body = part.body || "";

    if (typeof body === "string" && body.trim()) {
      if (ct.startsWith("text/plain") && !bestPlain) {
        bestPlain = { kind: "text/plain", body };
      } else if (ct.startsWith("text/html") && !bestHtml) {
        bestHtml = { kind: "text/html", body };
      }
    }

    // Walk sub-parts (MimeMessage uses .parts for children).
    const parts = part.parts || part.subParts || [];
    if (Array.isArray(parts)) {
      for (const p of parts) {
        walk(p);
      }
    }
  }

  walk(msg);
  return bestPlain || bestHtml || null;
}

/*
  Ingest queue for encrypted email delegation (Approach B).

  When applyAction encounters an encrypted message that cannot be decrypted in
  filter context, it enqueues {id, headerMessageId, endpoint, timestamp} here.
  The background script polls getIngestQueue() and processes items using its
  full WebExtension API access (messages.getRaw with decrypt:true).
*/
let ingestQueue = [];
let ingestQueueNextId = 1;

/*
  Ingestion status cache for custom column display.

  Maps headerMessageId → { ingested: bool, processed: bool }.
  Populated by the background script via updateIngestStatusCache(), which
  polls the OCaml server's /admin/ingested_status endpoint.
  Read synchronously by the custom column handler's getCellText().
*/
const ingestStatusCache = new Map();

/* Column handler ID used for gDBView.addColumnHandler / treecol element. */
const INGEST_COL_ID = "ragIngestStatusCol";

/* Cached reference to ThreadPaneColumns module (set during registerIngestColumn). */
let cachedThreadPaneColumns = null;

/*
  Custom column handler implementing nsIMsgCustomColumnHandler.

  Displays ● (ingested), ●✓ (ingested+processed), or blank (unknown/pending)
  in the thread pane.  The handler reads synchronously from ingestStatusCache.
*/
const ingestColumnHandler = {
  QueryInterface: ChromeUtils.generateQI(["nsIMsgCustomColumnHandler"]),

  getCellText(row, col) {
    try {
      const win = windowMediator.getMostRecentWindow("mail:3pane");
      if (!win) return "";
      const view = win.gDBView || win.gTabmail?.currentAbout3Pane?.gDBView;
      if (!view) return "";
      const hdr = view.getMsgHdrAt(row);
      if (!hdr) return "";
      const mid = hdr.messageId || "";
      if (!mid) return "";
      const st = ingestStatusCache.get(mid);
      if (!st) return "";
      if (!st.ingested) return "";
      return st.processed ? "\u25CF\u2713" : "\u25CF";
    } catch (_e) {
      return "";
    }
  },

  getCellProperties(row, col) { return ""; },
  getRowProperties(row) { return ""; },
  getImageSrc(row, col) { return ""; },
  getSortLongForRow(hdr) {
    const mid = hdr.messageId || "";
    const st = ingestStatusCache.get(mid);
    if (!st) return 0;
    if (!st.ingested) return 1;
    return st.processed ? 3 : 2;
  },
  getSortStringForRow(hdr) { return ""; },
  isString() { return false; },
  isEditable(row, col) { return false; },
};

/*
  Register the custom column in the 3pane window's thread pane.

  TB 128+ replaced the XUL <tree> with an HTML table-based thread pane.
  Custom columns are added via the ThreadPaneColumns module and the
  <thread-pane> custom element's column configuration.

  Called on register() and after updateIngestStatusCache().
*/
function findAbout3Pane() {
  const win = windowMediator.getMostRecentWindow("mail:3pane");
  if (!win) return null;

  // Try gTabmail.currentAbout3Pane (TB 128+ standard path).
  if (win.gTabmail?.currentAbout3Pane) return win.gTabmail.currentAbout3Pane;

  // Try tabmail element directly.
  const tabmail = win.document?.getElementById("tabmail");
  if (tabmail?.currentAbout3Pane) return tabmail.currentAbout3Pane;

  // Try currentTabInfo.browser.contentWindow (some TB versions).
  const tab = tabmail?.currentTabInfo;
  const browser = tab?.browser || tab?.chromeBrowser;
  if (browser?.contentWindow) return browser.contentWindow;

  // Try known browser element IDs.
  for (const id of ["mail3PaneTabBrowser1", "mail3PaneBrowser"]) {
    const el = win.document?.getElementById(id);
    if (el?.contentWindow) return el.contentWindow;
  }

  return null;
}

function registerIngestColumn() {
  try {
    const win = windowMediator.getMostRecentWindow("mail:3pane");
    if (!win) {
      consoleService.logStringMessage("[ragFilterAction] registerIngestColumn: no 3pane window");
      return false;
    }

    const about3Pane = findAbout3Pane();
    if (!about3Pane) {
      consoleService.logStringMessage("[ragFilterAction] registerIngestColumn: no about3Pane (will retry)");
      return false;
    }
    consoleService.logStringMessage("[ragFilterAction] registerIngestColumn: found about3Pane");

    // Wait until the thread pane is fully loaded before attempting column registration.
    if (!about3Pane.threadTree && !about3Pane.gDBView) {
      consoleService.logStringMessage("[ragFilterAction] registerIngestColumn: about3Pane not fully loaded yet (no threadTree/gDBView), will retry");
      return false;
    }

    // Probe what's available on about3Pane for diagnostics.
    const probeKeys = [];
    for (const k of ["threadTree", "threadPane", "gDBView", "gViewWrapper",
                      "ThreadPaneColumns", "document"]) {
      if (about3Pane[k]) probeKeys.push(k);
    }
    consoleService.logStringMessage(
      "[ragFilterAction] about3Pane has: " + probeKeys.join(", ")
    );

    // TB 128+: try to import ThreadPaneColumns from various paths.
    const modulePaths = [
      "chrome://messenger/content/thread-pane-columns.mjs",
      "chrome://messenger/content/ThreadPaneColumns.mjs",
      "resource:///modules/ThreadPaneColumns.mjs",
      "resource:///modules/ThreadPaneColumns.sys.mjs",
    ];
    let ThreadPaneColumns = about3Pane.ThreadPaneColumns || null;
    if (!ThreadPaneColumns) {
      for (const path of modulePaths) {
        try {
          const mod = ChromeUtils.importESModule(path);
          ThreadPaneColumns = mod.ThreadPaneColumns || mod.default || null;
          if (ThreadPaneColumns) {
            consoleService.logStringMessage(`[ragFilterAction] loaded ThreadPaneColumns from ${path}`);
            break;
          }
        } catch (_e) {
          // try next
        }
      }
    }
    if (ThreadPaneColumns) {
      const keys = Object.keys(ThreadPaneColumns);
      consoleService.logStringMessage(
        "[ragFilterAction] ThreadPaneColumns keys: " + keys.join(", ")
      );
      // Clean up any broken previous registration before re-registering.
      try { ThreadPaneColumns.removeCustomColumn?.(INGEST_COL_ID); } catch (_e) { /* ignore */ }

      if (ThreadPaneColumns.addCustomColumn) {
        // TB 140 signature: addCustomColumn(id, properties)
        ThreadPaneColumns.addCustomColumn(INGEST_COL_ID, {
          name: "RAG",
          hidden: false,
          icon: false,
          resizable: false,
          sortable: true,
          textCallback(msgHdr) {
            const mid = msgHdr?.messageId || "";
            if (!mid) return "";
            const st = ingestStatusCache.get(mid);
            if (!st) return "";
            if (!st.ingested) return "";
            return st.processed ? "\u25CF\u2713" : "\u25CF";
          },
        });
        cachedThreadPaneColumns = ThreadPaneColumns;
        consoleService.logStringMessage("[ragFilterAction] registered RAG column via ThreadPaneColumns.addCustomColumn");
        return true;
      } else {
        consoleService.logStringMessage(
          "[ragFilterAction] ThreadPaneColumns loaded but no addCustomColumn. Keys: " + keys.join(", ")
        );
      }
    } else {
      consoleService.logStringMessage("[ragFilterAction] ThreadPaneColumns not found via any path");
    }

    // Fallback: try legacy gDBView.addColumnHandler + treecol approach.
    try {
      const view = about3Pane.gDBView || win.gDBView;
      if (view && view.addColumnHandler) {
        view.addColumnHandler(INGEST_COL_ID, ingestColumnHandler);
        const doc = about3Pane.document || win.document;
        if (doc && !doc.getElementById(INGEST_COL_ID)) {
          const threadCols = doc.getElementById("threadCols");
          if (threadCols) {
            const col = doc.createXULElement
              ? doc.createXULElement("treecol")
              : doc.createElement("treecol");
            col.setAttribute("id", INGEST_COL_ID);
            col.setAttribute("label", "RAG");
            col.setAttribute("tooltiptext", "ThunderRAG ingestion status");
            col.setAttribute("width", "36");
            col.setAttribute("fixed", "true");
            threadCols.appendChild(col);
            consoleService.logStringMessage("[ragFilterAction] added RAG column via legacy treecol fallback");
            return true;
          }
        }
        consoleService.logStringMessage("[ragFilterAction] gDBView.addColumnHandler succeeded but no threadCols found");
        return true;
      }
    } catch (e2) {
      consoleService.logStringMessage(`[ragFilterAction] legacy column fallback also failed: ${e2}`);
    }

    consoleService.logStringMessage("[ragFilterAction] registerIngestColumn: no column method worked");
    return false;
  } catch (e) {
    consoleService.logStringMessage(`[ragFilterAction] registerIngestColumn: ${e}`);
    return false;
  }
}

function enqueueIngest(headerMessageId, endpoint) {
  const item = {
    id: String(ingestQueueNextId++),
    headerMessageId,
    endpoint,
    timestamp: Date.now(),
  };
  ingestQueue.push(item);
  try {
    consoleService.logStringMessage(
      `[ragFilterAction] enqueueIngest: queued id=${item.id} messageId=${headerMessageId} endpoint=${endpoint} queueLength=${ingestQueue.length}`
    );
  } catch (_e) {
    // ignore
  }
  return item;
}

function dequeueIngest(itemId) {
  const before = ingestQueue.length;
  ingestQueue = ingestQueue.filter((it) => it.id !== itemId);
  return before !== ingestQueue.length;
}

/*
  Probe a scope object for a reachable WebExtension API (browser/messenger with
  runtime.sendMessage).  Tries various wrapper shapes observed across TB builds.
  Returns { api, scope } where api is the usable namespace object.
*/
function extractWebextApiFromScope(scope) {
  if (!scope) {
    return { api: null, scope: null };
  }

  const waive = (obj) => {
    try {
      if (!obj) return obj;
      if (Components?.utils?.waiveXrays) {
        return Components.utils.waiveXrays(obj);
      }
      return obj;
    } catch (_e) {
      return obj;
    }
  };

  const tryGet = (obj) => {
    try {
      if (!obj) return null;
      // In some Thunderbird builds, the context exposes an apiObj with namespaces directly
      // (runtime/messages/etc) but there is no global 'browser'/'messenger' object reachable.
      if (obj.browser || obj.messenger) {
        return obj.browser || obj.messenger;
      }
      if (obj.runtime && typeof obj.runtime.sendMessage === "function") {
        return obj;
      }
      return null;
    } catch (_e) {
      return null;
    }
  };

  // Try a few common shapes observed in TB's various wrappers.
  const candidates = [
    scope,
    scope?.wrappedJSObject,
    scope?.childManager,
    scope?.childManager?.wrappedJSObject,
    scope?.apiObj,
    scope?.apiObj?.wrappedJSObject,
    scope?.global,
    scope?.global?.wrappedJSObject,
    scope?.window,
    scope?.globalThis,
    scope?.contentWindow,
    scope?.defaultView,
    scope?.document?.defaultView,
    scope?.xulBrowser?.contentWindow,
    scope?.xulBrowser?.ownerGlobal,
    scope?.xulBrowser?.ownerDocument?.defaultView,
  ];

  for (const c0 of candidates) {
    const c1 = waive(c0);
    const c2 = c1?.wrappedJSObject || c1;
    const api = tryGet(c2);
    if (api) {
      return { api, scope: c2 };
    }
  }

  return { api: null, scope: null };
}

/*
  tryAcquireFromViews iterates over extension.views and probes each view's various
  window/xulBrowser/contentWindow shapes for a reachable WebExtension API object.
  This is the shared core used by both maybeAcquireWebextScope (register-time) and
  maybeAcquireWebextScopeFromGlobalManager (applyAction-time).

  Returns true and sets webextScope if a usable API scope is found.
*/
function tryAcquireFromViews(views, logPrefix) {
  if (!views || views.length === 0) {
    return false;
  }

  for (const v of views) {
    try {
      let waivedXulBrowser = null;
      try {
        if (v?.xulBrowser && Components?.utils?.waiveXrays) {
          waivedXulBrowser = Components.utils.waiveXrays(v.xulBrowser);
        }
      } catch (_e) {
        waivedXulBrowser = null;
      }

      const candidates = [
        v?.window,
        v?.contentWindow,
        v?.xulBrowser?.contentWindow,
        waivedXulBrowser?.contentWindow,
        v?.xulBrowser?.ownerGlobal,
        v?.xulBrowser?.ownerDocument?.defaultView,
        v?.xulBrowser?.browsingContext?.window,
        waivedXulBrowser?.ownerGlobal,
        waivedXulBrowser?.ownerDocument?.defaultView,
        waivedXulBrowser?.browsingContext?.window,
        v?.xulBrowser,
        waivedXulBrowser,
      ];

      for (const c of candidates) {
        if (!c) {
          continue;
        }
        let scope = c;
        try {
          if (Components?.utils?.waiveXrays) {
            scope = Components.utils.waiveXrays(scope);
          }
        } catch (_e) {
          scope = c;
        }
        scope = scope?.wrappedJSObject || scope;
        const found = extractWebextApiFromScope(scope);
        const api = found.api;
        if (api && found.scope) {
          scope = found.scope;
        }
        if (api) {
          webextScope = scope;
          try {
            consoleService.logStringMessage(
              `[ragFilterAction] ${logPrefix}: acquired webext scope from viewType=${String(v?.viewType || "?")}`
            );
          } catch (_e) {
            // ignore
          }
          return true;
        }
      }
    } catch (_e) {
      // ignore
    }
  }

  return false;
}

/* Obtain the WebExtension API object directly from the background context
   via GlobalManager, bypassing the view-iteration path.  Used by delegateIngestToBackground. */
function getBackgroundWebextApi() {
  try {
    const extension = ExtensionParent?.GlobalManager?.getExtension
      ? ExtensionParent.GlobalManager.getExtension(ADDON_ID)
      : null;
    const bg = extension?.backgroundContext || null;

    // Some builds expose the callable WebExtension namespaces on backgroundContext.apiObj
    // (instead of a global browser/messenger object).
    try {
      const ao0 = bg?.apiObj || null;
      const ao1 = (Components?.utils?.waiveXrays && ao0) ? Components.utils.waiveXrays(ao0) : ao0;
      if (ao1 && ao1.runtime && typeof ao1.runtime.sendMessage === "function") {
        return ao1;
      }
    } catch (_e) {
      // ignore
    }

    const bg0 = bg;
    const bg1 = (Components?.utils?.waiveXrays && bg) ? Components.utils.waiveXrays(bg) : bg;
    const found0 = extractWebextApiFromScope(bg0);
    const found1 = extractWebextApiFromScope(bg1);
    const api = found0.api || found1.api;
    return api || null;
  } catch (_e) {
    return null;
  }
}

/* Preferred ingestion path: delegate to the background script via runtime.sendMessage
   so that the background script (which has full WebExtension permissions) can call
   messages.getRaw with decrypt:true and POST to the endpoint. */
async function delegateIngestToBackground(msgHdr, endpoint) {
  try {
    const api = getBackgroundWebextApi();
    const headerMessageId = (msgHdr?.messageId || "").trim();
    if (!api || !api.runtime || typeof api.runtime.sendMessage !== "function") {
      return { ok: false, error: "background runtime.sendMessage unavailable" };
    }
    if (!headerMessageId) {
      return { ok: false, error: "missing msgHdr.messageId" };
    }
    const res = await api.runtime.sendMessage({
      type: "ingestMessageByHeaderMessageId",
      headerMessageId,
      endpoint,
    });
    return { ok: true, res };
  } catch (e) {
    return { ok: false, error: String(e || "") };
  }
}

/* Return the cached browser/messenger namespace from webextScope, or null. */
function getWebextApi() {
  if (!webextScope) {
    return null;
  }
  return webextScope.browser || webextScope.messenger || null;
}

/* Try to acquire a WebExtension API scope at applyAction time via GlobalManager.
   Probes backgroundContext, its cloneScope, and then extension.views as fallback. */
function maybeAcquireWebextScopeFromGlobalManager() {
  if (webextScope) {
    return true;
  }

  try {
    const extension = ExtensionParent?.GlobalManager?.getExtension
      ? ExtensionParent.GlobalManager.getExtension(ADDON_ID)
      : null;
    if (!extension) {
      return false;
    }

    // Some Thunderbird builds expose a backgroundContext with a cloneScope that contains the real
    // WebExtension API object. Prefer this when available.
    try {
      const bg = extension?.backgroundContext || null;

      // First try: sometimes the backgroundContext itself exposes the API (or a reachable global)
      // even when cloneScope is not present.
      try {
        const bg0 = bg;
        const bg1 = (Components?.utils?.waiveXrays && bg) ? Components.utils.waiveXrays(bg) : bg;
        const found0 = extractWebextApiFromScope(bg0);
        const found1 = extractWebextApiFromScope(bg1);
        const api = found0.api || found1.api;
        const scope = found0.scope || found1.scope;
        if (api && scope) {
          webextScope = scope;
          try {
            consoleService.logStringMessage(
              "[ragFilterAction] applyAction: acquired webext scope via GlobalManager.backgroundContext"
            );
          } catch (_e) {
            // ignore
          }
          return true;
        }

        try {
          const k0 = Object.getOwnPropertyNames(bg0 || {}).slice(0, 25).join(",");
          const k1 = Object.getOwnPropertyNames(bg1 || {}).slice(0, 25).join(",");
          consoleService.logStringMessage(
            `[ragFilterAction] applyAction: backgroundContext present but no browser/messenger (keys0=[${k0}] keys1=[${k1}])`
          );
        } catch (_e) {
          // ignore
        }
      } catch (_e) {
        // ignore
      }

      const cs = bg?.cloneScope || null;
      if (!cs) {
        try {
          consoleService.logStringMessage(
            `[ragFilterAction] applyAction: GlobalManager extension.backgroundContext.cloneScope missing (bg=${bg ? "1" : "0"})`
          );
        } catch (_e) {
          // ignore
        }
      }
      if (cs && Components?.utils?.waiveXrays) {
        let scope0;
        try {
          scope0 = Components.utils.waiveXrays(cs);
        } catch (e) {
          try {
            consoleService.logStringMessage(
              `[ragFilterAction] applyAction: waiveXrays(backgroundContext.cloneScope) failed: ${e}`
            );
          } catch (_e) {
            // ignore
          }
          scope0 = null;
        }
        const { api, scope } = extractWebextApiFromScope(scope0?.wrappedJSObject || scope0);
        if (api) {
          webextScope = scope;
          try {
            consoleService.logStringMessage(
              "[ragFilterAction] applyAction: acquired webext scope via GlobalManager.backgroundContext.cloneScope"
            );
          } catch (_e) {
            // ignore
          }
          return true;
        }

        try {
          const ks = Object.getOwnPropertyNames(scope0 || {}).slice(0, 25).join(",");
          consoleService.logStringMessage(
            `[ragFilterAction] applyAction: backgroundContext.cloneScope present but no browser/messenger (keys=[${ks}])`
          );
        } catch (_e) {
          // ignore
        }
      }
    } catch (_e) {
      // ignore
    }

    const views = extension?.views ? Array.from(extension.views) : [];
    return tryAcquireFromViews(views, "applyAction");
  } catch (_e) {
    return false;
  }
}

/* Try to acquire a WebExtension API scope at register() time via the ExtensionAPI context.
   Probes context.cloneScope first, then falls back to extension.views iteration. */
async function maybeAcquireWebextScope(context) {
  if (webextScope) {
    return true;
  }

  try {
    // Preferred: directly access the real WebExtension scope (documented hack).
    try {
      if (context?.cloneScope && Components?.utils?.waiveXrays) {
        let scope;
        try {
          scope = Components.utils.waiveXrays(context.cloneScope);
        } catch (e) {
          try {
            consoleService.logStringMessage(
              `[ragFilterAction] register(): waiveXrays(context.cloneScope) failed: ${e}`
            );
          } catch (_e) {
            // ignore
          }
          scope = null;
        }

        const found = extractWebextApiFromScope(scope);
        const api = found.api;
        const scope2 = found.scope || scope;
        if (api) {
          webextScope = scope2;
          consoleService.logStringMessage("[ragFilterAction] register(): acquired webext scope via waiveXrays(context.cloneScope)");
          return true;
        } else {
          try {
            const keys = Object.getOwnPropertyNames(scope || {}).slice(0, 30).join(",");
            consoleService.logStringMessage(
              `[ragFilterAction] register(): cloneScope present but no browser/messenger keys=[${keys}]`
            );
          } catch (_e) {
            // ignore
          }
        }
      }
    } catch (_e) {
      // ignore
    }

    let extension = context?.extension;
    if (!extension && ExtensionParent?.GlobalManager?.getExtension) {
      try {
        const extId = context?.extension?.id || context?.extensionId;
        if (extId) {
          extension = ExtensionParent.GlobalManager.getExtension(extId) || extension;
        }
      } catch (_e) {
        // ignore
      }
    }

    const views = extension?.views ? Array.from(extension.views) : [];
    if (!views || views.length === 0) {
      consoleService.logStringMessage("[ragFilterAction] register(): no extension views available");
      return false;
    }

    try {
      const summary = views
        .map((v) => `${String(v?.viewType || "?")}`)
        .join(", ");
      consoleService.logStringMessage(`[ragFilterAction] register(): extension views = [${summary}]`);
    } catch (_e) {
      // ignore
    }

    return tryAcquireFromViews(views, "register()");
  } catch (e) {
    consoleService.logStringMessage(`[ragFilterAction] register(): maybeAcquireWebextScope failed: ${e}`);
    return false;
  }
}

/* Check if a window is the Thunderbird FilterEditor dialog (FilterEditor.xhtml). */
function isFilterEditorWindow(win) {
  try {
    const uri = win?.document?.documentURI;
    return (
      typeof uri === "string" &&
      uri.endsWith("FilterEditor.xhtml") &&
      win.document?.documentElement?.id === "FilterEditor"
    );
  } catch (e) {
    return false;
  }
}

/* Walk a messages.getFull() MIME tree and return the best readable body part,
   preferring text/plain over text/html.  Returns {kind, body} or null. */
function extractBestBodyFromFull(full) {
  const walk = (part) => {
    if (!part) {
      return null;
    }

    const ct = String(part.contentType || "").toLowerCase();
    const body =
      typeof part.body === "string"
        ? part.body
        : Array.isArray(part.body)
          ? part.body.join("")
          : "";

    if (body && ct.startsWith("text/plain")) {
      return { kind: "text/plain", body };
    }

    if (Array.isArray(part.parts)) {
      for (const p of part.parts) {
        const r = walk(p);
        if (r && r.kind === "text/plain") {
          return r;
        }
      }
      for (const p of part.parts) {
        const r = walk(p);
        if (r) {
          return r;
        }
      }
    }

    if (body && ct.startsWith("text/html")) {
      return { kind: "text/html", body };
    }

    return null;
  };

  return walk(full);
}

/* Detect an S/MIME wrapper (smime.p7m with no visible text part). */
function looksLikeSmimeWrapper(rawText) {
  const s = String(rawText || "").toLowerCase();
  if (!s) {
    return false;
  }

  const hasSmime = s.includes("smime.p7m") || s.includes("application/pkcs7-mime") || s.includes("application/x-pkcs7-mime");
  const hasVisibleTextPart = s.includes("content-type: text/plain") || s.includes("content-type: text/html");
  return hasSmime && !hasVisibleTextPart;
}

/* Detect PGP ASCII armor (-----BEGIN PGP MESSAGE----- etc.). */
function looksLikePgpArmor(rawText) {
  const s = String(rawText || "").toLowerCase();
  return s.includes("-----begin pgp message-----") || s.includes("-----begin pgp signed message-----");
}

/* Detect PGP/MIME encrypted structure (multipart/encrypted + application/pgp-encrypted). */
function looksLikePgpMimeEncrypted(rawText) {
  const s = String(rawText || "").toLowerCase();
  if (!s) {
    return false;
  }
  return (
    s.includes("content-type: multipart/encrypted") ||
    s.includes("application/pgp-encrypted") ||
    s.includes("protocol=\"application/pgp-encrypted\"") ||
    s.includes("protocol=application/pgp-encrypted")
  );
}

/* Check the nsMsgMessageFlags.Encrypted bit on an nsIMsgDBHdr. */
function isHdrFlaggedEncrypted(msgHdr) {
  try {
    const flags = msgHdr?.flags;
    const mask = Ci?.nsMsgMessageFlags?.Encrypted;
    if (typeof flags === "number" && typeof mask === "number") {
      return (flags & mask) !== 0;
    }
  } catch (_e) {
    // ignore
  }
  return false;
}

/* Detect S/MIME encryption markers (pkcs7-mime, enveloped-data, etc.). */
function looksLikeSmimeEncrypted(rawText) {
  const s = String(rawText || "").toLowerCase();
  if (!s) {
    return false;
  }
  // Enveloped-data indicates actual encryption (as opposed to signed-only).
  return (
    s.includes("application/pkcs7-mime") ||
    s.includes("application/x-pkcs7-mime") ||
    s.includes("application/pkcs7-signature") ||
    s.includes("application/x-pkcs7-signature") ||
    s.includes("smime-type=enveloped-data") ||
    s.includes("smime-type=envelopeddata")
  );
}

/* Return the message body after the RFC822 header/body separator (\r\n\r\n or \n\n). */
function bodyAfterHeaders(rawText) {
  const s = String(rawText || "");
  const idx = s.indexOf("\r\n\r\n");
  if (idx >= 0) {
    return s.slice(idx + 4);
  }
  const idx2 = s.indexOf("\n\n");
  if (idx2 >= 0) {
    return s.slice(idx2 + 2);
  }
  return "";
}

/* Synthesize a minimal RFC822 message from an nsIMsgDBHdr's metadata and a body string.
   Used when we can only obtain the decrypted body (not the original RFC822 bytes). */
function synthesizeRfc822FromBody(msgHdr, best) {
  const headers = [];
  if (msgHdr?.author) headers.push(`From: ${msgHdr.author}`);
  if (msgHdr?.recipients) headers.push(`To: ${msgHdr.recipients}`);
  if (msgHdr?.ccList) headers.push(`Cc: ${msgHdr.ccList}`);
  if (msgHdr?.bccList) headers.push(`Bcc: ${msgHdr.bccList}`);
  if (msgHdr?.subject) headers.push(`Subject: ${msgHdr.subject}`);
  if (msgHdr?.messageId) {
    const mid = msgHdr.messageId;
    headers.push(`Message-Id: ${mid.startsWith("<") ? mid : "<" + mid + ">"}`);
  }
  headers.push("MIME-Version: 1.0");
  headers.push(`Content-Type: ${best.kind}; charset=UTF-8`);
  headers.push("Content-Transfer-Encoding: 8bit");
  return `${headers.join("\r\n")}\r\n\r\n${best.body}`;
}

/* Monkey-patch the FilterEditor's ruleactiontarget-wrapper custom element so that
   our custom action ID gets a "forward-to" style text input (for the endpoint URL)
   instead of the default empty target. */
function patchFilterEditorWindow(win) {
  try {
    if (!isFilterEditorWindow(win)) {
      return;
    }

    if (win.__ragFilterActionPatched) {
      return;
    }
    win.__ragFilterActionPatched = true;

    const Wrapper = win.customElements?.get("ruleactiontarget-wrapper");
    if (!Wrapper || !Wrapper.prototype || typeof Wrapper.prototype._getChildNode !== "function") {
      consoleService.logStringMessage(
        "[ragFilterAction] FilterEditor patch: ruleactiontarget-wrapper not available"
      );
      return;
    }

    if (!Wrapper.prototype.__ragFilterActionPatched) {
      const originalGetChildNode = Wrapper.prototype._getChildNode;
      Wrapper.prototype._getChildNode = function (type) {
        if (type === ACTION_ID) {
          return win.document.createXULElement("ruleactiontarget-forwardto");
        }
        return originalGetChildNode.call(this, type);
      };
      Wrapper.prototype.__ragFilterActionPatched = true;
    }

    for (const wrapper of win.document.querySelectorAll("ruleactiontarget-wrapper")) {
      const type = wrapper.getAttribute("type");
      if (type === ACTION_ID) {
        wrapper.removeAttribute("type");
        wrapper.setAttribute("type", type);
      }
    }

    consoleService.logStringMessage("[ragFilterAction] FilterEditor patch installed");
  } catch (e) {
    consoleService.logStringMessage(`[ragFilterAction] FilterEditor patch failed: ${e}`);
  }
}

/* Start a domwindowopened observer to auto-patch any FilterEditor dialog
   that opens after our action is registered. */
function startFilterEditorObserver() {
  if (filterEditorObserver) {
    return;
  }

  filterEditorObserver = {
    observe(subject, topic, data) {
      if (topic !== "domwindowopened") {
        return;
      }

      try {
        let win = null;

        // In Thunderbird 140, subject isn't guaranteed to be an nsISupports
        // that implements QueryInterface, so we try multiple strategies.
        if (subject && typeof subject.addEventListener === "function") {
          win = subject;
        } else if (subject && typeof subject.QueryInterface === "function") {
          try {
            win = subject.QueryInterface(Ci.nsIDOMWindow);
          } catch (e) {
            // Fall through.
          }
        }

        if (!win && subject && typeof subject.getInterface === "function") {
          try {
            win = subject.getInterface(Ci.nsIDOMWindow);
          } catch (e) {
            // Fall through.
          }
        }

        if (!win && subject && typeof subject.QueryInterface === "function") {
          try {
            win = subject
              .QueryInterface(Ci.nsIInterfaceRequestor)
              .getInterface(Ci.nsIDOMWindow);
          } catch (e) {
            // Fall through.
          }
        }

        if (!win) {
          consoleService.logStringMessage(
            `[ragFilterAction] domwindowopened handler failed: unable to get window from subject (${typeof subject})`
          );
          return;
        }

        win.addEventListener(
          "DOMContentLoaded",
          () => {
            patchFilterEditorWindow(win);
          },
          { once: true }
        );
      } catch (e) {
        consoleService.logStringMessage(`[ragFilterAction] domwindowopened handler failed: ${e}`);
      }
    },
    QueryInterface: ChromeUtils.generateQI(["nsIObserver"]),
  };

  obsService.addObserver(filterEditorObserver, "domwindowopened");

  try {
    const existing = windowMediator.getMostRecentWindow("mailnews:filtereditor");
    if (existing) {
      patchFilterEditorWindow(existing);
    }
  } catch (e) {
    consoleService.logStringMessage(`[ragFilterAction] existing FilterEditor patch check failed: ${e}`);
  }
}

/* Remove the domwindowopened observer on shutdown. */
function stopFilterEditorObserver() {
  if (!filterEditorObserver) {
    return;
  }
  try {
    obsService.removeObserver(filterEditorObserver, "domwindowopened");
  } catch (e) {
    consoleService.logStringMessage(`[ragFilterAction] removeObserver failed: ${e}`);
  }
  filterEditorObserver = null;
}

/* Check whether our custom action is already registered with MailServices.filters. */
function hasCustomAction(filterService) {
  try {
    let existing = filterService.getCustomAction(ACTION_ID);
    return !!existing;
  } catch (e) {
    // Fall through.
  }

  try {
    let actions = filterService.getCustomActions();
    return actions.some(a => a && a.id === ACTION_ID);
  } catch (e) {
    return false;
  }
}

/* Validate the user-provided endpoint URL for the filter action value.
   Returns {ok, url} on success or {ok:false, error} on failure. */
function parseAndValidateUrl(actionValue) {
  if (!actionValue || !actionValue.trim()) {
    return { ok: false, error: "Endpoint must not be empty." };
  }

  let trimmed = actionValue.trim();
  if (!/^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(trimmed)) {
    trimmed = `http://${trimmed}`;
  }

  let url;
  try {
    url = ioService.newURI(trimmed, null, null);
  } catch (e) {
    return { ok: false, error: "Endpoint must be a valid URL." };
  }

  if (!url.schemeIs("http") && !url.schemeIs("https")) {
    return { ok: false, error: "Endpoint must be http(s)." };
  }

  if (!url.host) {
    return { ok: false, error: "Endpoint must include a host." };
  }

  return { ok: true, url: url.spec };
}

/* Stream a message's raw bytes via XPCOM nsIMsgMessageService.streamMessage.
   When convertData=true, Thunderbird runs its conversion pipeline (MIME decode,
   crypto decrypt for S/MIME/PGP if keys are available). */
function streamMessageToUint8Array(msgHdr, msgWindow, { convertData = false } = {}) {
  return new Promise((resolve, reject) => {
    try {
      let uri = msgHdr.folder.getUriForMsg(msgHdr);
      let msgService = MailServices.messageServiceFromURI(uri);

      let chunks = [];
      let total = 0;

      let listener = {
        onStartRequest(request) {},

        onDataAvailable(request, inputStream, offset, count) {
          let binaryInputStream = Cc["@mozilla.org/binaryinputstream;1"].createInstance(
            Ci.nsIBinaryInputStream
          );
          binaryInputStream.setInputStream(inputStream);
          let bytes = binaryInputStream.readByteArray(count);
          chunks.push(bytes);
          total += bytes.length;
        },

        onStopRequest(request, statusCode) {
          if (!Components.isSuccessCode(statusCode)) {
            reject(new Error(`streamMessage(convertData=${convertData}) failed: ${statusCode}`));
            return;
          }

          let out = new Uint8Array(total);
          let pos = 0;
          for (let arr of chunks) {
            out.set(arr, pos);
            pos += arr.length;
          }
          resolve(out);
        },

        QueryInterface: ChromeUtils.generateQI(["nsIStreamListener", "nsIRequestObserver"]),
      };

      // convertData=true runs the message through Thunderbird's conversion pipeline,
      // which is what enables S/MIME/PGP decrypted display.
      msgService.streamMessage(uri, listener, msgWindow, null, convertData, "", false);
    } catch (e) {
      reject(e);
    }
  });
}

/* Obtain or synthesize an nsIMsgWindow suitable for the convertData pipeline.
   Prefers the real 3-pane mail window (needed for crypto); falls back to
   the filter-provided msgWindow or a newly created instance. */
function ensureMsgWindowForConversion(msgWindow) {
  const tryGet3paneMsgWindow = () => {
    try {
      const w = windowMediator.getMostRecentWindow("mail:3pane");
      if (!w) return null;
      return w.msgWindow || w.gMsgWindow || (typeof w.GetMsgWindow === "function" ? w.GetMsgWindow() : null);
    } catch (_e) {
      return null;
    }
  };

  // Prefer a real UI msgWindow when possible; filter-run msgWindow is often not wired for crypto.
  const threePane = tryGet3paneMsgWindow();
  if (threePane) {
    try {
      consoleService.logStringMessage(
        `[ragFilterAction] convertData: using 3pane msgWindow for conversion (hadMsgWindow=${msgWindow ? "1" : "0"})`
      );
    } catch (_e) {
      // ignore
    }
    return threePane;
  }

  if (msgWindow) {
    return msgWindow;
  }

  try {
    const mw = Cc["@mozilla.org/messenger/msgwindow;1"].createInstance(Ci.nsIMsgWindow);
    try {
      const w = windowMediator.getMostRecentWindow("mail:3pane");
      if (w) {
        mw.domWindow = w;
      }
    } catch (_e) {
      // ignore
    }
    consoleService.logStringMessage("[ragFilterAction] convertData: synthesized nsIMsgWindow for conversion");
    return mw;
  } catch (_e) {
    return null;
  }
}

/* POST raw RFC822 bytes to the OCaml ingest endpoint as message/rfc822.
   Retries with 127.0.0.1 if localhost fails (common IPv6/IPv4 mismatch). */
async function postMessage(endpoint, rawBytes, msgHdr) {
  let blob = new Blob([rawBytes], { type: "message/rfc822" });

  let headers = new Headers();
  headers.set("Content-Type", "message/rfc822");
  headers.set("X-Thunderbird-Message-Id", msgHdr.messageId || "");

  let resp;
  try {
    resp = await fetch(endpoint, {
      method: "POST",
      headers,
      body: blob,
    });
  } catch (e) {
    const msgId = msgHdr?.messageId || "";
    const msg = String(e || "");
    const isNetworkError = msg.includes("NetworkError") || msg.includes("Failed to fetch");

    // Common failure mode: localhost resolves to ::1 but server is bound only to 127.0.0.1.
    if (isNetworkError && typeof endpoint === "string" && endpoint.startsWith("http://localhost")) {
      const endpoint2 = endpoint.replace("http://localhost", "http://127.0.0.1");
      try {
        consoleService.logStringMessage(
          `[ragFilterAction] postMessage: retrying with endpoint=${endpoint2} after NetworkError (localhost->127.0.0.1) messageId=${msgId}`
        );
        resp = await fetch(endpoint2, {
          method: "POST",
          headers,
          body: blob,
        });
      } catch (e2) {
        consoleService.logStringMessage(
          `[ragFilterAction] postMessage: fetch failed endpoint=${endpoint} messageId=${msgId} error=${e}`
        );
        consoleService.logStringMessage(
          `[ragFilterAction] postMessage: fetch retry failed endpoint=${endpoint2} messageId=${msgId} error=${e2}`
        );
        consoleService.logStringMessage(
          "[ragFilterAction] postMessage: check that the endpoint is reachable from Thunderbird and that the add-on has host permissions for the exact URL."
        );
        throw e2;
      }
    } else {
      consoleService.logStringMessage(
        `[ragFilterAction] postMessage: fetch failed endpoint=${endpoint} messageId=${msgId} error=${e}`
      );
      consoleService.logStringMessage(
        "[ragFilterAction] postMessage: check that the endpoint is reachable from Thunderbird and that the add-on has host permissions for the exact URL."
      );
      throw e;
    }
  }

  if (!resp.ok) {
    let bodyText = "";
    try {
      bodyText = await resp.text();
    } catch (_e) {
      bodyText = "";
    }
    if (bodyText && bodyText.length > 500) {
      bodyText = bodyText.slice(0, 500) + "…";
    }
    throw new Error(`POST failed: ${resp.status} ${resp.statusText}${bodyText ? ` body=${bodyText}` : ""}`);
  }
}

/* Signal filter completion to Thunderbird's copy listener.
   Tries OnStopCopy, onStopCopy, and direct invocation (varies by TB version). */
function safeFinishCopy(copyListener) {
  if (!copyListener) {
    return;
  }

  const listener = copyListener?.wrappedJSObject || copyListener;

  const tryCall = (fn) => {
    try {
      if (typeof fn === "function") {
        fn.call(listener, 0);
        return true;
      }
    } catch (_e) {
      // swallow
    }
    return false;
  };

  try {
    if (tryCall(listener.OnStopCopy)) return;
  } catch (_e) {}
  try {
    if (tryCall(listener.onStopCopy)) return;
  } catch (_e) {}
  try {
    if (tryCall(listener)) return;
  } catch (_e) {}

  try {
    consoleService.logStringMessage(
      `[ragFilterAction] safeFinishCopy: no callable completion callback (OnStopCopy/onStopCopy/function) type=${typeof listener}`
    );
  } catch (_e) {
    // ignore
  }
}

/* Attempt to get decrypted message bytes via the WebExtension messages.getRaw API
   with {decrypt:true}.  Validates that the result is actually decrypted (not still
   PGP/S/MIME wrapper) and falls back to getFull() for S/MIME envelope-only cases.
   Returns Uint8Array of usable RFC822 bytes, or null if decryption failed. */
async function fetchDecryptedMessageBytes(msgHdr) {
  const api = getWebextApi();
  if (!api) {
    return null;
  }

  const headerMessageId = (msgHdr.messageId || "").trim();
  if (!headerMessageId) {
    return null;
  }

  // Resolve nsIMsgDBHdr -> MailExtension numeric messageId.
  let messageId = null;
  try {
    const result = await api.messages.query({ headerMessageId });
    messageId = result?.messages?.[0]?.id || null;
  } catch (_e) {
    messageId = null;
  }
  if (!messageId && headerMessageId.startsWith("<") && headerMessageId.endsWith(">")) {
    try {
      const result = await api.messages.query({ headerMessageId: headerMessageId.slice(1, -1) });
      messageId = result?.messages?.[0]?.id || null;
    } catch (_e) {
      messageId = null;
    }
  }
  if (!messageId) {
    return null;
  }

  // TB 140 ESR supports decrypt on getRaw. Use File format and read bytes.
  let file;
  try {
    file = await api.messages.getRaw(messageId, { decrypt: true, data_format: "File" });
  } catch (_e) {
    file = null;
  }
  if (file && typeof file.arrayBuffer === "function") {
    const buf = await file.arrayBuffer();
    const bytes = new Uint8Array(buf);

    try {
      const rawText = new TextDecoder("utf-8", { fatal: false }).decode(bytes);
      const lower = rawText.toLowerCase();
      const hasSmime = lower.includes("smime.p7m") || looksLikeSmimeEncrypted(rawText);
      const emptyVisibleBody = bodyAfterHeaders(rawText).trim() === "";
      const pgpMime = looksLikePgpMimeEncrypted(rawText);

      if (looksLikePgpArmor(rawText)) {
        consoleService.logStringMessage(
          `[ragFilterAction] decrypt: getRaw(decrypt:true) still looks like PGP armor for messageId=${msgHdr.messageId || ""}`
        );
        return null;
      }

      if (pgpMime) {
        consoleService.logStringMessage(
          `[ragFilterAction] decrypt: getRaw(decrypt:true) still looks like PGP/MIME encrypted for messageId=${msgHdr.messageId || ""}`
        );
        return null;
      }

      if (hasSmime && (looksLikeSmimeWrapper(rawText) || emptyVisibleBody)) {
        const full = await api.messages.getFull(messageId, { decrypt: true });
        const best = extractBestBodyFromFull(full);
        if (best && typeof best.body === "string" && best.body.trim() !== "") {
          const synth = synthesizeRfc822FromBody(msgHdr, best);
          return new TextEncoder().encode(synth);
        }

        consoleService.logStringMessage(
          `[ragFilterAction] decrypt: S/MIME wrapper/empty body after decrypt+getFull fallback for messageId=${msgHdr.messageId || ""}`
        );
        return null;
      }

      // Strict: if body is empty after decrypt, do not post. This avoids ingesting ciphertext-only wrappers.
      if (emptyVisibleBody) {
        consoleService.logStringMessage(
          `[ragFilterAction] decrypt: getRaw(decrypt:true) produced empty body-after-headers; treating as undecrypted for messageId=${msgHdr.messageId || ""}`
        );
        return null;
      }
    } catch (_e) {
      // ignore, fall through to raw bytes
    }

    return bytes;
  }

  return null;
}

/* Create the nsIMsgFilterCustomAction object that Thunderbird registers.
   The applyAction method implements the full ingestion pipeline:
   1. Try background delegation (preferred, has full API access)
   2. Try fetchDecryptedMessageBytes (WebExtension getRaw decrypt)
   3. Try streamMessage(convertData=false) for non-encrypted mail
   4. Try streamMessage(convertData=true) as last resort
   5. POST the result to the configured endpoint */
function makeCustomAction() {
  return {
    id: ACTION_ID,

    get name() {
      return "ThunderRAG";
    },

    isValidForType(type, scope) {
      return true;
    },

    validateActionValue(actionValue, actionFolder, filterType) {
      let result = parseAndValidateUrl(actionValue);
      if (!result.ok) {
        return result.error;
      }
      return null;
    },

    allowDuplicates: true,

    applyAction(msgHdrs, actionValue, copyListener, filterType, msgWindow) {
      (async () => {
        try {
          let parsed = parseAndValidateUrl(actionValue);
          if (!parsed.ok) {
            throw new Error(parsed.error);
          }

          try {
            if (!getWebextApi()) {
              try {
                if (savedApiContext) {
                  await maybeAcquireWebextScope(savedApiContext);
                }
              } catch (_e) {
                // ignore
              }
              maybeAcquireWebextScopeFromGlobalManager();
            }
          } catch (_e) {
            // ignore
          }

          for (let msgHdr of msgHdrs) {
            try {
              let encryptedHint = false;

              try {
                const delegated = await delegateIngestToBackground(msgHdr, parsed.url);
                if (delegated.ok) {
                  try {
                    consoleService.logStringMessage(
                      `[ragFilterAction] applyAction: delegated ingestion to background for messageId=${msgHdr.messageId || ""}`
                    );
                  } catch (_e) {
                    // ignore
                  }
                  continue;
                }
                try {
                  consoleService.logStringMessage(
                    `[ragFilterAction] applyAction: background delegation unavailable messageId=${msgHdr.messageId || ""} error=${String(delegated?.error || "")}`
                  );
                } catch (_e) {
                  // ignore
                }
              } catch (_e) {
                // ignore
              }

              let raw = await fetchDecryptedMessageBytes(msgHdr);
              if (!raw) {
                // Prefer raw RFC822 via streamMessage(convertData=false) when possible.
                // Even if we can't ingest its bytes (e.g., encrypted), we still use it as a
                // reliable signal for encryption/content-type.
                try {
                  const bytes = await streamMessageToUint8Array(msgHdr, msgWindow);
                  const text = new TextDecoder("utf-8", { fatal: false }).decode(bytes);
                  const encryptedish =
                    looksLikePgpArmor(text) ||
                    looksLikePgpMimeEncrypted(text) ||
                    looksLikeSmimeEncrypted(text) ||
                    looksLikeSmimeWrapper(text);

                  encryptedHint = encryptedish;
                  if (encryptedHint) {
                    try {
                      consoleService.logStringMessage(
                        `[ragFilterAction] applyAction: streamMessage(convertData=false) indicates encrypted content-type/message. messageId=${msgHdr.messageId || ""}`
                      );
                    } catch (_e) {
                      // ignore
                    }
                  }

                  if (!encryptedish && bodyAfterHeaders(text).trim() !== "") {
                    consoleService.logStringMessage(
                      `[ragFilterAction] applyAction: using streamMessage(convertData=false) for non-encrypted messageId=${msgHdr.messageId || ""} bytes=${bytes?.length || 0}`
                    );
                    raw = bytes;
                  }
                } catch (_e) {
                  // ignore
                }

                if (!raw) {
                  // Fallback for multiprocess / missing webext scope: try Thunderbird's conversion pipeline.
                try {
                  const mw = ensureMsgWindowForConversion(msgWindow);
                  if (!mw) {
                    consoleService.logStringMessage(
                      `[ragFilterAction] applyAction: ERROR: could not create nsIMsgWindow for convertData pipeline. messageId=${msgHdr.messageId || ""}`
                    );
                    continue;
                  }
                  consoleService.logStringMessage(
                    `[ragFilterAction] applyAction: trying convertData=true fallback messageId=${msgHdr.messageId || ""} hadMsgWindow=${msgWindow ? "1" : "0"}`
                  );
                  const converted = await streamMessageToUint8Array(msgHdr, mw, { convertData: true });
                  consoleService.logStringMessage(
                    `[ragFilterAction] applyAction: convertData=true produced bytes=${converted?.length || 0} messageId=${msgHdr.messageId || ""}`
                  );
                  const text = new TextDecoder("utf-8", { fatal: false }).decode(converted);

                  // convertData=true may return display HTML (starts with <!DOCTYPE or <html)
                  // instead of RFC822.  This happens for S/MIME decrypted messages.
                  // In that case, use the HTML directly as the message body.
                  // Strip Thunderbird's header display tables (Subject/From/Date/To)
                  // before ingestion — they confuse the new-vs-quoted splitter.
                  const isDisplayHtml = text.trimStart().startsWith("<!DOCTYPE") || text.trimStart().startsWith("<html");
                  if (isDisplayHtml && text.trim() !== "") {
                    // Remove <table> elements with class containing "moz-header" (TB display chrome).
                    // These tables render Subject/From/Date/To as HTML but are not part of the email body.
                    let cleanHtml = text.replace(/<table[^>]*class="[^"]*moz-header[^"]*"[^>]*>[\s\S]*?<\/table>/gi, "");
                    // Remove leading <br> left after table removal
                    cleanHtml = cleanHtml.replace(/^([\s\S]*?<body[^>]*>)\s*(<br\s*\/?\s*>)+/i, "$1");
                    consoleService.logStringMessage(
                      `[ragFilterAction] applyAction: convertData returned display HTML (${text.length} chars -> ${cleanHtml.length} cleaned), using as body. messageId=${msgHdr.messageId || ""}`
                    );
                    const synth = synthesizeRfc822FromBody(msgHdr, { kind: "text/html", body: cleanHtml });
                    raw = new TextEncoder().encode(synth);
                  }

                  if (!raw) {
                  const after = bodyAfterHeaders(text).trim();

                  const smimeWrap = looksLikeSmimeWrapper(text);
                  const smimeEnc = looksLikeSmimeEncrypted(text);
                  const pgp = looksLikePgpArmor(text);
                  const pgpMime = looksLikePgpMimeEncrypted(text);
                  const empty = after === "";
                  consoleService.logStringMessage(
                    `[ragFilterAction] applyAction: convertData analysis smimeWrapper=${smimeWrap ? "1" : "0"} smimeEncrypted=${smimeEnc ? "1" : "0"} pgpArmor=${pgp ? "1" : "0"} pgpMime=${pgpMime ? "1" : "0"} emptyBody=${empty ? "1" : "0"} hintEncrypted=${encryptedHint ? "1" : "0"} messageId=${msgHdr.messageId || ""}`
                  );

                  if (smimeWrap || smimeEnc || pgp || pgpMime || empty) {
                    const hdrEncrypted = isHdrFlaggedEncrypted(msgHdr);
                    const encryptedish = hdrEncrypted || encryptedHint || smimeWrap || smimeEnc || pgp || pgpMime;
                    if (encryptedish) {
                      consoleService.logStringMessage(
                        `[ragFilterAction] applyAction: posting encrypted error-stub to OCaml (no ciphertext). messageId=${msgHdr.messageId || ""}`
                      );
                      const kind = "text/plain";
                      const bodyWithMarker =
                        "[ERROR: message appears encrypted but could not be decrypted in filter context. The add-on did not ingest ciphertext. Please use background-script decryption or manual evidence upload.]\n\n" +
                        "[ERROR: decrypted raw RFC822 unavailable; message body obtained via Thunderbird conversion pipeline; attachments may be missing]\n\n" +
                        (after || "");
                      const synth = synthesizeRfc822FromBody(msgHdr, { kind, body: bodyWithMarker });
                      raw = new TextEncoder().encode(synth);

                      // Approach B: enqueue for background-script decryption retry.
                      // The background script will re-ingest with the decrypted content,
                      // replacing this error stub via idempotent /ingest.
                      try {
                        const hdrMid = (msgHdr.messageId || "").trim();
                        if (hdrMid) {
                          enqueueIngest(hdrMid, parsed.url);
                        }
                      } catch (_e) {
                        // ignore
                      }
                    } else {
                      consoleService.logStringMessage(
                        `[ragFilterAction] applyAction: posting empty-body NOTE stub to OCaml. messageId=${msgHdr.messageId || ""}`
                      );
                      const kind = "text/plain";
                      const bodyWithMarker =
                        "[NOTE: email body appears empty in filter context; ingesting metadata anyway. Attachments may be missing.]\n\n";
                      const synth = synthesizeRfc822FromBody(msgHdr, { kind, body: bodyWithMarker });
                      raw = new TextEncoder().encode(synth);
                    }
                  }

                  if (!raw) {
                    const kind = looksLikeHtmlText(text) ? "text/html" : "text/plain";

                    const hdrEncrypted = isHdrFlaggedEncrypted(msgHdr);
                    const marker = hdrEncrypted
                      ? "[ERROR: decrypted raw RFC822 unavailable; message body obtained via Thunderbird conversion pipeline; attachments may be missing]\n\n"
                      : "[NOTE: raw RFC822 unavailable in filter context; message body obtained via Thunderbird conversion pipeline; attachments may be missing]\n\n";

                    const bodyWithMarker = marker + after;

                    const synth = synthesizeRfc822FromBody(msgHdr, { kind, body: bodyWithMarker });
                    raw = new TextEncoder().encode(synth);
                  }
                  } // close if (!raw) — display HTML case already set raw above
                } catch (e) {
                  consoleService.logStringMessage(
                    `[ragFilterAction] applyAction: skipping (no decrypted bytes, conversion failed) messageId=${msgHdr.messageId || ""} error=${e}`
                  );
                  // Approach B: enqueue for background retry if this looks encrypted.
                  try {
                    const hdrMid = (msgHdr.messageId || "").trim();
                    if (hdrMid && (encryptedHint || isHdrFlaggedEncrypted(msgHdr))) {
                      enqueueIngest(hdrMid, parsed.url);
                    }
                  } catch (_e2) {
                    // ignore
                  }
                  continue;
                }
                }
              }

              await postMessage(parsed.url, raw, msgHdr);
            } catch (e) {
              // If decryption fails, do not fall back to posting ciphertext.
              consoleService.logStringMessage(
                `[ragFilterAction] applyAction: failed for messageId=${msgHdr.messageId || ""}: ${e}`
              );
            }
          }
        } catch (e) {
          console.error(e);
        } finally {
          safeFinishCopy(copyListener);
        }
      })();
    },

    get isAsync() {
      return true;
    },

    get needsBody() {
      return true;
    },

    QueryInterface: ChromeUtils.generateQI(["nsIMsgFilterCustomAction"]),
  };
}

/*
  ensureRegistered adds the custom filter action to MailServices.filters if it is not
  already present, then starts the FilterEditor observer so the UI shows the endpoint
  text field.  Called from both onStartup (synchronous, early) and register() (async,
  after the WebExtension scope has been acquired).
*/
function ensureRegistered(logPrefix) {
  let filterService = MailServices.filters;
  if (!hasCustomAction(filterService)) {
    try {
      filterService.addCustomAction(makeCustomAction());
      consoleService.logStringMessage(`[ragFilterAction] ${logPrefix}: custom action registered`);
    } catch (e) {
      consoleService.logStringMessage(`[ragFilterAction] ${logPrefix}: addCustomAction failed: ${e}`);
    }
  } else {
    consoleService.logStringMessage(`[ragFilterAction] ${logPrefix}: custom action already registered`);
  }

  try {
    let actions = filterService.getCustomActions();
    consoleService.logStringMessage(`[ragFilterAction] ${logPrefix}: custom actions count = ${actions.length}`);
  } catch (e) {
    consoleService.logStringMessage(`[ragFilterAction] ${logPrefix}: unable to list custom actions: ${e}`);
  }

  startFilterEditorObserver();
}

/* --- ExtensionAPI class: lifecycle hooks and public API surface --- */
var ragFilterAction = class extends ExtensionCommon.ExtensionAPI {
  onStartup() {
    try {
      consoleService.logStringMessage("[ragFilterAction] onStartup: attempting to register custom action");
      ensureRegistered("onStartup");
    } catch (e) {
      console.error(e);
      consoleService.logStringMessage(`[ragFilterAction] onStartup: registration failed: ${e}`);
    }
  }

  onShutdown(isAppShutdown) {
    if (isAppShutdown) {
      return;
    }

    try {
      stopFilterEditorObserver();
      obsService.notifyObservers(null, "startupcache-invalidate", null);
    } catch (e) {
      console.error(e);
    }
  }

  getAPI(context) {
    try {
      savedApiContext = context;
      const hasClone = context?.cloneScope ? "1" : "0";
      const hasExt = context?.extension ? "1" : "0";
      consoleService.logStringMessage(
        `[ragFilterAction] getAPI: saved context (cloneScope=${hasClone} extension=${hasExt})`
      );
    } catch (_e) {
      // ignore
    }
    return {
      ragFilterAction: {
        register: async () => {
          try {
            consoleService.logStringMessage("[ragFilterAction] register(): attempting to register custom action");

            try {
              let ok = await maybeAcquireWebextScope(context);
              if (!ok) {
                for (let i = 0; i < 3 && !ok; i++) {
                  await new Promise((resolve) => (typeof setTimeout === "function" ? setTimeout(resolve, 200) : resolve()));
                  ok = await maybeAcquireWebextScope(context);
                }
              }
              if (!ok) {
                consoleService.logStringMessage("[ragFilterAction] register(): background/webext scope not found");
              }
            } catch (e) {
              consoleService.logStringMessage(`[ragFilterAction] register(): unable to locate webext scope: ${e}`);
            }

            ensureRegistered("register()");

            // Register the custom column with retries (3pane takes a while to load).
            try {
              if (typeof setTimeout === "function") {
                let colAttempt = 0;
                const tryCol = () => {
                  colAttempt++;
                  const ok = registerIngestColumn();
                  if (!ok && colAttempt < 10) {
                    setTimeout(tryCol, 2000);
                  }
                };
                setTimeout(tryCol, 3000);
              } else {
                registerIngestColumn();
              }
            } catch (_e) {
              // Column registration is best-effort.
            }
          } catch (e) {
            consoleService.logStringMessage(`[ragFilterAction] register(): failed: ${e}`);
          }
        },
        unregister: async () => {
          // No removal API exists on nsIMsgFilterService; best-effort noop.
        },
        getIngestQueue: async () => {
          // Return a snapshot of the current queue (plain objects, safe to cross boundary).
          return ingestQueue.map((it) => ({
            id: it.id,
            headerMessageId: it.headerMessageId,
            endpoint: it.endpoint,
            timestamp: it.timestamp,
          }));
        },
        completeIngestItem: async (itemId) => {
          const removed = dequeueIngest(itemId);
          try {
            consoleService.logStringMessage(
              `[ragFilterAction] completeIngestItem: id=${itemId} removed=${removed} queueLength=${ingestQueue.length}`
            );
          } catch (_e) {
            // ignore
          }
          return removed;
        },
        getDecryptedBodyText: async (messageId) => {
          /*
            Use Thunderbird's internal MsgHdrToMimeMessage to parse a message
            through the full MIME pipeline (including S/MIME/PGP decryption).
            This sees the same decrypted content that Thunderbird displays in the UI.
          */
          try {
            if (!MsgHdrToMimeMessage) {
              consoleService.logStringMessage("[ragFilterAction] getDecryptedBodyText: MsgHdrToMimeMessage not available");
              return null;
            }

            // Resolve the numeric messageId to an nsIMsgDBHdr.
            const msgHdr = context.extension.messageManager.get(messageId);
            if (!msgHdr) {
              consoleService.logStringMessage(`[ragFilterAction] getDecryptedBodyText: no msgHdr for id=${messageId}`);
              return null;
            }

            // MsgHdrToMimeMessage is callback-based; wrap in a promise.
            const result = await new Promise((resolve) => {
              try {
                MsgHdrToMimeMessage(msgHdr, null, (aMsgHdr, aMimeMsg) => {
                  resolve(aMimeMsg);
                }, true /* allowDownload */, { examineEncryptedParts: true });
              } catch (e) {
                consoleService.logStringMessage(`[ragFilterAction] getDecryptedBodyText: MsgHdrToMimeMessage threw: ${e}`);
                resolve(null);
              }
            });

            if (!result) {
              consoleService.logStringMessage(`[ragFilterAction] getDecryptedBodyText: MsgHdrToMimeMessage returned null for id=${messageId}`);
              return null;
            }

            const extracted = extractBodyFromMimeMessage(result);
            if (extracted && extracted.body?.trim()) {
              consoleService.logStringMessage(
                `[ragFilterAction] getDecryptedBodyText: success for id=${messageId} kind=${extracted.kind} len=${extracted.body.length}`
              );
              return { body: extracted.body, kind: extracted.kind };
            }

            consoleService.logStringMessage(`[ragFilterAction] getDecryptedBodyText: no body found in MIME tree for id=${messageId}`);
            return null;
          } catch (e) {
            consoleService.logStringMessage(`[ragFilterAction] getDecryptedBodyText: error for id=${messageId}: ${e}`);
            return null;
          }
        },
        updateIngestStatusCache: async (cacheJson) => {
          try {
            const obj = JSON.parse(cacheJson);
            for (const [k, v] of Object.entries(obj)) {
              if (v && typeof v === "object") {
                ingestStatusCache.set(k, { ingested: !!v.ingested, processed: !!v.processed });
              } else {
                // Legacy boolean format fallback.
                ingestStatusCache.set(k, { ingested: !!v, processed: false });
              }
            }
            // Refresh the column so it repaints with the new cache data.
            if (cachedThreadPaneColumns?.refreshCustomColumn) {
              try {
                cachedThreadPaneColumns.refreshCustomColumn(INGEST_COL_ID);
              } catch (_e) {
                // If refresh fails, try re-registering.
                registerIngestColumn();
              }
            } else {
              // Column not registered yet — try now.
              registerIngestColumn();
            }
          } catch (e) {
            consoleService.logStringMessage(`[ragFilterAction] updateIngestStatusCache error: ${e}`);
          }
        },
      },
    };
  }
};
