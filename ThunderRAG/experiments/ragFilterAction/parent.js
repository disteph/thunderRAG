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

var AttachmentInfo;
try {
  ({ AttachmentInfo } = ChromeUtils.importESModule(
    "resource:///modules/AttachmentInfo.sys.mjs"
  ));
} catch (_e) {
  AttachmentInfo = null;
}

var MessageArchiver;
try {
  ({ MessageArchiver } = ChromeUtils.importESModule(
    "resource:///modules/MessageArchiver.sys.mjs"
  ));
} catch (_e) {
  MessageArchiver = null;
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
const dirService = Cc["@mozilla.org/file/directory_service;1"].getService(Ci.nsIProperties);

const BUILD_TAG = "ragFilterAction-parent-2026-02-02-01";
try {
  consoleService.logStringMessage(`[ragFilterAction] parent.js loaded build_tag=${BUILD_TAG}`);
} catch (_e) {
  // ignore
}

const ADDON_ID = "rag-filter-action@example.com";

/* Unique ID for the custom filter action registered with MailServices.filters. */
const ACTION_ID = "rag-filter-action@example.com#PostMessageToEndpoint";
const ACTION_SAVE_ATTACHMENTS_ID = "rag-filter-action@example.com#SaveAttachmentsToPath";
const ACTION_ARCHIVE_ID = "rag-filter-action@example.com#ArchiveMessage";

/* Observer that patches newly-opened FilterEditor windows (see patchFilterEditorWindow). */
let filterEditorObserver = null;

/* Cached reference to the WebExtension API scope (browser/messenger object).
   Acquired lazily via cloneScope / GlobalManager probing. */
let webextScope = null;

/* The ExtensionAPI context saved from getAPI(), used to re-acquire scope later. */
let savedApiContext = null;
let attachmentSettingsCache = {
  filterSyntax: "pcre",
  defaultPath: "",
  lazyIgnore: "",
};

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
let attachmentSaveQueue = [];
let attachmentSaveQueueNextId = 1;

/*
  Ingestion status cache for custom column display.

  Maps headerMessageId → { ingested: bool, processed: bool, partial: bool, reply_by: string }.
  Populated by the background script via updateIngestStatusCache(), which
  polls the OCaml server's /admin/ingested_status endpoint.
  Read synchronously by the custom column handler's getCellText().
*/
const ingestStatusCache = new Map();

/* Parse "YYYY-MM-DD" to days since epoch; returns 0 on failure. */
function replyByToDays(s) {
  if (!s) return 0;
  const ms = Date.parse(s + "T00:00:00Z");
  if (Number.isNaN(ms)) return 0;
  return Math.floor(ms / 86400000);
}

/* Column handler ID used for gDBView.addColumnHandler / treecol element. */
const INGEST_COL_ID = "ragIngestStatusCol";

/* Cached reference to ThreadPaneColumns module (set during registerIngestColumn). */
let cachedThreadPaneColumns = null;

/*
  Custom column handler implementing nsIMsgCustomColumnHandler.

  Displays ● (ingested), ●✓ (ingested+processed), ◯ (partial/metadata-only),
  or blank (unknown/pending) in the thread pane.
  The handler reads synchronously from ingestStatusCache.
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
      const disc = st.partial ? "\u25CB" : "\u25CF";
      const suffix = (st.trigger_active ? "\u26A1" : "") + (st.processed ? "\u2713" : "");
      return disc + suffix;
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
    if (!st || !st.ingested) return 999999999;
    const days = replyByToDays(st.reply_by);
    return days > 0 ? days : 999999998;
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
        // name = "ThunderRAG" appears in the column picker dropdown menu.
        // The column header text is overridden to 🛢 via DOM fixup below.
        ThreadPaneColumns.addCustomColumn(INGEST_COL_ID, {
          name: "ThunderRAG",
          hidden: false,
          resizable: false,
          sortable: true,
          textCallback(msgHdr) {
            const mid = msgHdr?.messageId || "";
            if (!mid) return "";
            const st = ingestStatusCache.get(mid);
            if (!st) return "";
            if (!st.ingested) return "";
            const disc = st.partial ? "\u25CB" : "\u25CF";
            const suffix = (st.trigger_active ? "\u26A1" : "") + (st.processed ? "\u2713" : "");
            return disc + suffix;
          },
        });
        cachedThreadPaneColumns = ThreadPaneColumns;
        consoleService.logStringMessage("[ragFilterAction] registered RAG column via ThreadPaneColumns.addCustomColumn");

        // Inject persistent CSS to override the column header text with 🛢
        // and enforce narrow fixed width.  The stylesheet stays in the
        // about:3pane document across folder switches (no page reload).
        try {
          const doc = about3Pane.document || win.document;
          const STYLE_ID = "ragIngestStatusCol-style";
          if (doc && !doc.getElementById(STYLE_ID)) {
            const style = doc.createElement("style");
            style.id = STYLE_ID;
            style.textContent = `
              /* --- ThunderRAG column header: show 🛢 instead of "ThunderRAG" --- */
              th#${INGEST_COL_ID},
              [is="tree-view-table-header-cell"]#${INGEST_COL_ID} {
                max-width: 48px !important;
                min-width: 48px !important;
                width: 48px !important;
              }
              th#${INGEST_COL_ID} button,
              [is="tree-view-table-header-cell"]#${INGEST_COL_ID} button {
                font-size: 0 !important;
                overflow: hidden !important;
                padding: 0 2px !important;
              }
              th#${INGEST_COL_ID} button::before,
              [is="tree-view-table-header-cell"]#${INGEST_COL_ID} button::before {
                content: "\\1F6E2" !important;
                font-size: 14px !important;
              }
              /* --- ThunderRAG column cells: fixed narrow width --- */
              td.${INGEST_COL_ID}-column,
              [data-column-id="${INGEST_COL_ID}"] {
                max-width: 48px !important;
                min-width: 48px !important;
                width: 48px !important;
                text-align: center !important;
              }
            `;
            (doc.head || doc.documentElement).appendChild(style);
            consoleService.logStringMessage("[ragFilterAction] injected persistent column CSS");
          }
        } catch (cssErr) {
          consoleService.logStringMessage("[ragFilterAction] CSS injection error: " + cssErr);
        }

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
            col.setAttribute("label", "ThunderRAG");
            col.setAttribute("display", "\uD83D\uDEE2");
            col.setAttribute("tooltiptext", "ThunderRAG ingestion status");
            col.setAttribute("width", "28");
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

async function getMimeMessageForHdr(msgHdr) {
  if (!MsgHdrToMimeMessage) {
    throw new Error("MsgHdrToMimeMessage not available");
  }
  return await new Promise((resolve) => {
    try {
      MsgHdrToMimeMessage(msgHdr, null, (_aMsgHdr, aMimeMsg) => {
        resolve(aMimeMsg || null);
      }, true, { examineEncryptedParts: true });
    } catch (e) {
      try {
        consoleService.logStringMessage(`[ragFilterAction] saveAttachments: MsgHdrToMimeMessage threw: ${e}`);
      } catch (_e) {
      }
      resolve(null);
    }
  });
}

function collectMimeAttachments(mimeMsg) {
  if (!mimeMsg) {
    return [];
  }
  if (Array.isArray(mimeMsg.allUserAttachments) && mimeMsg.allUserAttachments.length) {
    return mimeMsg.allUserAttachments;
  }
  if (Array.isArray(mimeMsg.allAttachments) && mimeMsg.allAttachments.length) {
    return mimeMsg.allAttachments;
  }

  const attachments = [];
  const walk = (part) => {
    if (!part) {
      return;
    }
    const name = String(part.name || part.displayName || "").trim();
    const disposition = String(part.contentDisposition || "").toLowerCase();
    const url = String(part.url || "").trim();
    if ((part.isRealAttachment || disposition.includes("attachment") || (name && url)) && url) {
      attachments.push(part);
    }
    const parts = part.parts || part.subParts || [];
    if (Array.isArray(parts)) {
      for (const child of parts) {
        walk(child);
      }
    }
  };
  walk(mimeMsg);
  return attachments;
}

function saveNativeAttachmentToFile(attachment, destination, messageUri) {
  return (async () => {
    const url = String(attachment?.url || "").trim();
    const attUri = String(attachment?.uri || messageUri || "").trim();
    const contentType = String(attachment?.contentType || "application/octet-stream").trim() || "application/octet-stream";
    const name = String(attachment?.name || attachment?.displayName || destination?.leafName || "attachment").trim() || "attachment";
    if (!url) {
      throw new Error("Attachment URL missing");
    }
    if (!AttachmentInfo) {
      throw new Error("AttachmentInfo API unavailable");
    }
    const info = new AttachmentInfo({
      contentType,
      url,
      name,
      uri: attUri,
      isExternalAttachment: false,
      message: null,
    });
    await info.saveToFile(destination.path);
  })();
}

function getMsgHdrForMessageId(messageId) {
  try {
    const ctx = savedApiContext;
    const mgr = ctx?.extension?.messageManager;
    if (mgr && typeof mgr.get === "function") {
      return mgr.get(messageId) || null;
    }
  } catch (_e) {
  }
  return null;
}

function attachmentDescriptorKey(index, rawName) {
  return `${index}:${String(rawName || "")}`;
}

function preferredDestinationFile(dir, filename) {
  const file = dir.clone();
  file.append(filename);
  return file;
}

function stripAttachmentRuntimeFields(item) {
  const { attachment, ...rest } = item;
  return rest;
}

async function describeAttachmentsFromMsgHdr(msgHdr, directoryPath = "", options = {}) {
  if (!msgHdr) {
    throw new Error(`No msgHdr for messageId=${options.headerMessageId || ""}`);
  }
  const mimeMsg = await getMimeMessageForHdr(msgHdr);
  const attachments = collectMimeAttachments(mimeMsg);
  const matcher = String(options.matcher || "").trim();
  const syntax = resolveAttachmentMatcherSyntax(options.syntax, attachmentSettingsCache.filterSyntax);
  const ignorePatterns = parseIgnorePatterns(options.ignoreText || attachmentSettingsCache.lazyIgnore);
  const useGlobalIgnore = shouldApplyGlobalIgnore(options.useGlobalIgnore, true);
  const directory = directoryPath ? nsFileFromPath(directoryPath) : null;
  return attachments.map((attachment, idx) => {
    const index = idx + 1;
    const rawName = attachment?.name || attachment?.displayName || `attachment-${index}`;
    const safeName = sanitizePathComponent(rawName, `attachment-${index}`);
    const preferredPath = directory ? preferredDestinationFile(directory, safeName).path : "";
    const ignored = useGlobalIgnore ? filenameMatchesIgnore(rawName, ignorePatterns) : false;
    const matches = ignored ? false : filenameMatchesMatcher(rawName, matcher, syntax);
    const exists = preferredPath ? preferredDestinationFile(directory, safeName).exists() : false;
    return {
      key: attachmentDescriptorKey(index, rawName),
      index,
      name: rawName,
      safeName,
      contentType: String(attachment?.contentType || "application/octet-stream"),
      size: Number(attachment?.size || 0) || 0,
      ignored,
      matches,
      exists,
      path: preferredPath,
      attachment,
    };
  });
}

async function saveAttachmentsFromMsgHdr(msgHdr, directoryPath, headerMessageId = "", options = {}) {
  if (!msgHdr) {
    throw new Error(`No msgHdr for messageId=${headerMessageId || ""}`);
  }
  const described = await describeAttachmentsFromMsgHdr(msgHdr, directoryPath, {
    headerMessageId,
    matcher: options.matcher || "",
    syntax: options.syntax || attachmentSettingsCache.filterSyntax,
    useGlobalIgnore: shouldApplyGlobalIgnore(options.useGlobalIgnore, true),
    ignoreText: options.ignoreText || attachmentSettingsCache.lazyIgnore,
  });
  if (!described.length) {
    try {
      consoleService.logStringMessage(
        `[ragFilterAction] saveAttachments: no attachments found messageId=${headerMessageId || ""}`
      );
    } catch (_e) {
    }
    return { saved: 0, directory: null, attachments: 0, files: [], descriptors: [] };
  }

  const keySet = Array.isArray(options.selectedKeys) ? new Set(options.selectedKeys.map(String)) : null;
  const toSave = described.filter(item => {
    if (item.ignored || !item.matches) return false;
    if (keySet && !keySet.has(item.key)) return false;
    return true;
  });

  const directory = nsFileFromPath(directoryPath);
  ensureDirectoryExists(directory);
  const messageUri = msgHdr.folder?.getUriForMsg ? msgHdr.folder.getUriForMsg(msgHdr) : "";
  let saved = 0;
  const files = [];
  const renameOld = !!options.renameOld;
  for (const item of toSave) {
    if (item.exists && options.skipExisting && !renameOld) {
      files.push({ key: item.key, name: item.name, path: item.path, savedNow: false, existed: true, skipped: "skipExisting" });
      continue;
    }
    const preferred = preferredDestinationFile(directory, item.safeName);
    if (!item.exists) {
      try {
        await saveNativeAttachmentToFile(item.attachment, preferred, messageUri);
        saved++;
        files.push({ key: item.key, name: item.name, path: preferred.path, savedNow: true, existed: false });
        consoleService.logStringMessage(
          `[ragFilterAction] saveAttachments: saved ${preferred.path} messageId=${headerMessageId || ""}`
        );
      } catch (e) {
        try {
          consoleService.logStringMessage(
            `[ragFilterAction] saveAttachments: native save failed name=${item.name} url=${item.attachment?.url || ""} messageId=${headerMessageId || ""}: ${e}`
          );
        } catch (_e) {
        }
      }
      continue;
    }
    if (renameOld) {
      // Rename old file to archive name, then save new directly to original name.
      const originalLeafName = preferred.leafName;
      const originalPath = preferred.path;
      const archivedOld = uniqueDestinationFile(directory, item.safeName);
      try {
        preferred.renameTo(directory, archivedOld.leafName);
      } catch (renameErr) {
        consoleService.logStringMessage(
          `[ragFilterAction] saveAttachments: rename-old failed ${originalPath} → ${archivedOld.leafName}: ${renameErr}`
        );
        // Can't rename old; fall through to save with unique name below
      }
      if (!preferred.exists() || preferred.leafName !== originalLeafName) {
        // Old file was successfully moved out; save new to original name
        const newDest = preferredDestinationFile(directory, item.safeName);
        try {
          await saveNativeAttachmentToFile(item.attachment, newDest, messageUri);
          // Check if new is identical to archived old; if so, undo the rename
          if (filesAreIdentical(newDest, archivedOld)) {
            try { newDest.remove(false); } catch (_e) {}
            try { archivedOld.renameTo(directory, originalLeafName); } catch (_e) {}
            files.push({ key: item.key, name: item.name, path: originalPath, savedNow: false, existed: true, skipped: "identical" });
            consoleService.logStringMessage(
              `[ragFilterAction] saveAttachments: skipped identical ${originalPath} messageId=${headerMessageId || ""}`
            );
          } else {
            saved++;
            files.push({ key: item.key, name: item.name, path: originalPath, savedNow: true, existed: true, renamedOld: archivedOld.path });
            consoleService.logStringMessage(
              `[ragFilterAction] saveAttachments: saved ${originalPath} (old → ${archivedOld.leafName}) messageId=${headerMessageId || ""}`
            );
          }
        } catch (e) {
          // Save failed; try to restore old file
          try { archivedOld.renameTo(directory, originalLeafName); } catch (_e) {}
          try {
            consoleService.logStringMessage(
              `[ragFilterAction] saveAttachments: native save failed (renameOld) name=${item.name} messageId=${headerMessageId || ""}: ${e}`
            );
          } catch (_e) {}
        }
        continue;
      }
      // Fall through: rename-old failed, save with unique name instead
    }
    const tempDest = uniqueDestinationFile(directory, item.safeName);
    try {
      await saveNativeAttachmentToFile(item.attachment, tempDest, messageUri);
      if (filesAreIdentical(preferred, tempDest)) {
        try { tempDest.remove(false); } catch (_e) {}
        files.push({ key: item.key, name: item.name, path: preferred.path, savedNow: false, existed: true, skipped: "identical" });
        consoleService.logStringMessage(
          `[ragFilterAction] saveAttachments: skipped identical ${preferred.path} messageId=${headerMessageId || ""}`
        );
      } else {
        saved++;
        files.push({ key: item.key, name: item.name, path: tempDest.path, savedNow: true, existed: true });
        consoleService.logStringMessage(
          `[ragFilterAction] saveAttachments: saved ${tempDest.path} messageId=${headerMessageId || ""}`
        );
      }
    } catch (e) {
      try {
        consoleService.logStringMessage(
          `[ragFilterAction] saveAttachments: native save failed name=${item.name} url=${item.attachment?.url || ""} messageId=${headerMessageId || ""}: ${e}`
        );
      } catch (_e) {
      }
    }
  }
  return {
    saved,
    directory: directory.path,
    attachments: described.length,
    files,
    descriptors: described.map(stripAttachmentRuntimeFields),
  };
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

function enqueueAttachmentSave(headerMessageId, directoryPath, options = {}) {
  const item = {
    id: String(attachmentSaveQueueNextId++),
    headerMessageId,
    directoryPath,
    matcher: String(options.matcher || "").trim(),
    renameOld: !!options.renameOld,
    syntax: normalizeAttachmentSyntax(options.syntax, true),
    useGlobalIgnore: shouldApplyGlobalIgnore(options.useGlobalIgnore, true),
    timestamp: Date.now(),
  };
  attachmentSaveQueue.push(item);
  try {
    consoleService.logStringMessage(
      `[ragFilterAction] enqueueAttachmentSave: queued id=${item.id} messageId=${headerMessageId} directory=${directoryPath} matcher=${item.matcher} syntax=${item.syntax} useGlobalIgnore=${item.useGlobalIgnore ? "1" : "0"} queueLength=${attachmentSaveQueue.length}`
    );
  } catch (_e) {
  }
  return item;
}

function dequeueAttachmentSave(itemId) {
  const before = attachmentSaveQueue.length;
  attachmentSaveQueue = attachmentSaveQueue.filter((it) => it.id !== itemId);
  return before !== attachmentSaveQueue.length;
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

/* Preferred ingestion path: delegate to the background script via the in-memory
   ingestQueue so it can call messages.getRaw with decrypt:true and POST to the
   endpoint asynchronously.  The background script polls the queue every 5 s via
   browser.ragFilterAction.getIngestQueue().

   If the webext API scope is unavailable (always the case in current TB), we
   return { ok: false } so applyAction falls through to the direct POST path. */
async function delegateIngestToBackground(msgHdr, endpoint) {
  try {
    const headerMessageId = (msgHdr?.messageId || "").trim();
    if (!headerMessageId) {
      return { ok: false, error: "missing msgHdr.messageId" };
    }
    enqueueIngest(headerMessageId, endpoint);
    return { ok: true };
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

function createSaveAttachmentsTargetNode(win) {
  const doc = win.document;
  const root = doc.createElement("div");
  root.dataset.ragAttachmentTarget = "1";
  root.style.display = "flex";
  root.style.flexDirection = "column";
  root.style.gap = "4px";
  root.style.flex = "1";
  root.style.minWidth = "320px";

  const hidden = doc.createElement("input");
  hidden.type = "hidden";

  const topRow = doc.createElement("div");
  topRow.style.display = "flex";
  topRow.style.alignItems = "center";
  topRow.style.gap = "6px";

  const matcher = doc.createElement("input");
  matcher.type = "text";
  matcher.placeholder = "Filename matcher (empty = all)";
  matcher.style.flex = "1";
  matcher.style.minWidth = "0";

  const syntax = doc.createElement("select");
  for (const [value, label] of [["default", "Default"], ["pcre", "PCRE-like"], ["glob", "Glob"], ["posix_ere", "POSIX ERE"]]) {
    const opt = doc.createElement("option");
    opt.value = value;
    opt.textContent = label;
    syntax.appendChild(opt);
  }

  const ignoreLabel = doc.createElement("label");
  ignoreLabel.style.display = "flex";
  ignoreLabel.style.alignItems = "center";
  ignoreLabel.style.gap = "4px";
  ignoreLabel.style.fontSize = "11px";
  const ignoreCb = doc.createElement("input");
  ignoreCb.type = "checkbox";
  ignoreCb.checked = true;
  const ignoreText = doc.createElement("span");
  ignoreText.textContent = "Apply global ignore";
  ignoreLabel.appendChild(ignoreCb);
  ignoreLabel.appendChild(ignoreText);

  const renameOldLabel = doc.createElement("label");
  renameOldLabel.style.display = "flex";
  renameOldLabel.style.alignItems = "center";
  renameOldLabel.style.gap = "4px";
  renameOldLabel.style.fontSize = "11px";
  const renameOldCb = doc.createElement("input");
  renameOldCb.type = "checkbox";
  renameOldCb.checked = false;
  const renameOldText = doc.createElement("span");
  renameOldText.textContent = "Rename old on conflict";
  renameOldLabel.appendChild(renameOldCb);
  renameOldLabel.appendChild(renameOldText);

  topRow.appendChild(matcher);
  topRow.appendChild(syntax);
  topRow.appendChild(ignoreLabel);
  topRow.appendChild(renameOldLabel);

  const path = doc.createElement("input");
  path.type = "text";
  path.placeholder = attachmentSettingsCache.defaultPath || "Default attachment path from add-on settings";
  path.style.width = "100%";
  path.style.minWidth = "0";

  root.appendChild(hidden);
  root.appendChild(topRow);
  root.appendChild(path);

  root.loadActionValue = (value) => {
    const parsed = parseAttachmentSaveActionValue(value);
    matcher.value = parsed.matcher || "";
    syntax.value = normalizeAttachmentSyntax(parsed.syntax, true);
    ignoreCb.checked = shouldApplyGlobalIgnore(parsed.useGlobalIgnore, true);
    renameOldCb.checked = !!parsed.renameOld;
    path.value = parsed.path || "";
    path.placeholder = attachmentSettingsCache.defaultPath || "Default attachment path from add-on settings";
  };
  root.serializeActionValue = () => stringifyAttachmentSaveActionValue({
    matcher: matcher.value || "",
    syntax: syntax.value || "default",
    useGlobalIgnore: ignoreCb.checked,
    renameOld: renameOldCb.checked,
    path: path.value || "",
  });
  root.getDisplayValue = () => {
    const matcherText = String(matcher.value || "").trim() || "*";
    const syntaxText = syntax.options[syntax.selectedIndex]?.textContent || "Default";
    const pathText = String(path.value || "").trim() || (attachmentSettingsCache.defaultPath ? `[default: ${attachmentSettingsCache.defaultPath}]` : "[default path]");
    const renameText = renameOldCb.checked ? "rename old" : "rename new";
    return `${matcherText} · ${syntaxText} · ${ignoreCb.checked ? "ignore on" : "ignore off"} · ${renameText} · ${pathText}`;
  };

  Object.defineProperty(hidden, "value", {
    get() {
      return root.serializeActionValue();
    },
    set(v) {
      root.loadActionValue(v);
    },
    configurable: true,
  });
  Object.defineProperty(hidden, "label", {
    get() {
      return root.getDisplayValue();
    },
    configurable: true,
  });

  root.loadActionValue("");

  // Built-in target elements (e.g. ruleactiontarget-forwardto used by Ingest)
  // call updateParentNode() from their connectedCallback, which triggers
  // initWithAction() → actionItem.children[0].value = strValue.
  // Our plain div has no connectedCallback, so we replicate that call here
  // on the next tick (after the wrapper has attached us to the DOM).
  win.setTimeout(() => {
    try {
      const wrapper = root.closest("ruleactiontarget-wrapper") || root.parentElement;
      if (!wrapper) {
        return;
      }
      const parentNode = wrapper.closest("richlistitem");
      if (!parentNode || !parentNode.hasAttribute("initialActionIndex")) {
        return;
      }
      const actionIndex = parentNode.getAttribute("initialActionIndex");
      const filterAction = win.gFilter.getActionAt(actionIndex);
      parentNode.initWithAction(filterAction);
      if (typeof parentNode.updateRemoveButton === "function") {
        parentNode.updateRemoveButton();
      }
    } catch (_e) {
    }
  }, 0);

  return root;
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
        if (type === ACTION_SAVE_ATTACHMENTS_ID) {
          return createSaveAttachmentsTargetNode(win);
        }
        if (type === ACTION_ARCHIVE_ID) {
          const node = win.document.createElement("div");
          node.style.display = "flex";
          node.style.alignItems = "center";
          node.style.padding = "2px 4px";
          node.style.fontSize = "11px";
          node.style.color = "#666";
          const hidden = win.document.createElement("input");
          hidden.type = "hidden";
          hidden.value = "";
          const label = win.document.createElement("span");
          label.textContent = "Uses account archive settings (folder, granularity)";
          node.appendChild(hidden);
          node.appendChild(label);
          return node;
        }
        return originalGetChildNode.call(this, type);
      };
      Wrapper.prototype.__ragFilterActionPatched = true;
    }

    for (const wrapper of win.document.querySelectorAll("ruleactiontarget-wrapper")) {
      const type = wrapper.getAttribute("type");
      if (type === ACTION_ID || type === ACTION_SAVE_ATTACHMENTS_ID || type === ACTION_ARCHIVE_ID) {
        wrapper.removeAttribute("type");
        wrapper.setAttribute("type", type);
      }
    }

    // Ensure the action dropdown (menulist) correctly selects our custom actions
    // when loading a saved filter.  TB sometimes fails to select the right
    // menuitem for custom actions, showing "Move Message to" instead.
    const customActions = [
      { id: ACTION_ID, name: "ThunderRAG: Send to URL" },
      { id: ACTION_SAVE_ATTACHMENTS_ID, name: "ThunderRAG: Save attachments" },
      { id: ACTION_ARCHIVE_ID, name: "ThunderRAG: Archive" },
    ];
    function fixActionDropdowns() {
      try {
        const wrappers = win.document.querySelectorAll("ruleactiontarget-wrapper");
        consoleService.logStringMessage(
          `[ragFilterAction] FilterEditor dropdown fix: found ${wrappers.length} wrapper(s)`
        );
        for (const wrapper of wrappers) {
          const type = wrapper.getAttribute("type");
          const actionDef = customActions.find(a => a.id === type);
          if (!actionDef) continue;

          // Walk up to find the containing action row and its menulist.
          let row = wrapper.parentElement;
          const ancestors = [];
          for (let i = 0; i < 10 && row; i++) {
            ancestors.push(row.localName || row.tagName || "?");
            row = row.parentElement;
          }
          consoleService.logStringMessage(
            `[ragFilterAction] FilterEditor: wrapper type=${type} ancestors=[${ancestors.join(",")}]`
          );

          // Re-walk to find the closest container that has a menulist.
          row = wrapper.parentElement;
          let menulist = null;
          for (let i = 0; i < 10 && row && !menulist; i++) {
            menulist = row.querySelector("menulist");
            if (!menulist) {
              // Also try XUL namespace queries.
              for (const child of row.children || []) {
                if (child.localName === "menulist") {
                  menulist = child;
                  break;
                }
              }
            }
            if (!menulist) row = row.parentElement;
          }

          if (!menulist) {
            consoleService.logStringMessage(
              `[ragFilterAction] FilterEditor: no menulist found for action ${actionDef.name}`
            );
            continue;
          }

          consoleService.logStringMessage(
            `[ragFilterAction] FilterEditor: menulist found for ${actionDef.name}, value="${menulist.value}", label="${menulist.label}"`
          );

          // If the menulist already shows the correct value, nothing to do.
          if (menulist.value === type) {
            consoleService.logStringMessage(
              `[ragFilterAction] FilterEditor: dropdown already correct for ${actionDef.name}`
            );
            continue;
          }

          // Ensure a menuitem for this custom action exists in the popup.
          let popup = menulist.querySelector("menupopup");
          if (!popup) {
            for (const child of menulist.children || []) {
              if (child.localName === "menupopup") {
                popup = child;
                break;
              }
            }
          }
          if (!popup) {
            consoleService.logStringMessage(
              `[ragFilterAction] FilterEditor: no menupopup found for ${actionDef.name}`
            );
            continue;
          }

          // Log all existing menuitems to understand what's in the popup.
          const items = popup.querySelectorAll("menuitem");
          const itemValues = [];
          for (const it of items) {
            itemValues.push(`${it.getAttribute("value")}="${it.getAttribute("label")}"`);
          }
          consoleService.logStringMessage(
            `[ragFilterAction] FilterEditor: menupopup has ${items.length} items: ${itemValues.slice(-5).join(", ")}...`
          );

          let menuitem = null;
          for (const it of items) {
            if (it.getAttribute("value") === type) {
              menuitem = it;
              break;
            }
          }
          if (!menuitem) {
            menuitem = win.document.createXULElement("menuitem");
            menuitem.setAttribute("value", type);
            menuitem.setAttribute("label", actionDef.name);
            popup.appendChild(menuitem);
            consoleService.logStringMessage(
              `[ragFilterAction] FilterEditor: created menuitem for ${actionDef.name}`
            );
          }

          // Select the correct menuitem.
          menulist.value = type;
          menulist.selectedItem = menuitem;
          consoleService.logStringMessage(
            `[ragFilterAction] FilterEditor: fixed dropdown for ${actionDef.name}, now value="${menulist.value}"`
          );
        }
      } catch (e) {
        consoleService.logStringMessage(`[ragFilterAction] FilterEditor dropdown fix failed: ${e}`);
      }
    }
    // Run after a short delay and again after a longer one to handle late filter loading.
    win.setTimeout(fixActionDropdowns, 200);
    win.setTimeout(fixActionDropdowns, 800);

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
function hasCustomAction(filterService, actionId) {
  try {
    let existing = filterService.getCustomAction(actionId);
    return !!existing;
  } catch (e) {
    // Fall through.
  }

  try {
    let actions = filterService.getCustomActions();
    return actions.some(a => a && a.id === actionId);
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

function normalizeAttachmentSyntax(value, allowDefault = false) {
  const raw = String(value || "").trim().toLowerCase();
  if (allowDefault && (!raw || raw === "default")) return "default";
  if (raw === "glob") return "glob";
  if (raw === "posix_ere" || raw === "posix-ere") return "posix_ere";
  if (raw === "pcre" || raw === "pcre-like" || raw === "pcre_like") return "pcre";
  return allowDefault ? "default" : "pcre";
}

function normalizeAttachmentSettings(settings) {
  const src = settings && typeof settings === "object" ? settings : {};
  return {
    filterSyntax: normalizeAttachmentSyntax(src.filterSyntax, false),
    defaultPath: String(src.defaultPath || "").trim(),
    lazyIgnore: String(src.lazyIgnore || ""),
  };
}

function updateAttachmentSettingsCache(settings) {
  attachmentSettingsCache = normalizeAttachmentSettings(settings);
}

function parseAndValidatePathTemplate(actionValue, options = {}) {
  const allowEmpty = !!options.allowEmpty;
  const trimmed = String(actionValue || "").trim();
  if (!trimmed) {
    return allowEmpty ? { ok: true, template: "" } : { ok: false, error: "Path template must not be empty." };
  }

  const allowed = new Set(["account", "yyyy", "mm", "dd", "hours", "minutes", "subject", "from"]);
  const matches = trimmed.match(/{{\s*([^{}]+?)\s*}}/g) || [];
  for (const match of matches) {
    const inner = match.replace(/^{{\s*/, "").replace(/\s*}}$/, "").trim();
    if (!allowed.has(inner)) {
      return { ok: false, error: `Unsupported template variable: {{${inner}}}` };
    }
  }

  const absoluteLike = /^\//.test(trimmed) || /^~\//.test(trimmed) || /^[A-Za-z]:[\\/]/.test(trimmed);
  if (!absoluteLike) {
    return { ok: false, error: "Path template must be absolute or start with ~/." };
  }

  return { ok: true, template: trimmed };
}

function zeroPad2(n) {
  return String(Math.max(0, n)).padStart(2, "0");
}

function parseAttachmentSaveActionValue(actionValue) {
  const defaults = { matcher: "", syntax: "default", useGlobalIgnore: true, path: "", renameOld: false };
  const raw = String(actionValue || "").trim();
  if (!raw) {
    return { ...defaults };
  }
  if (!(raw.startsWith("{") && raw.endsWith("}"))) {
    return { ...defaults, path: raw };
  }
  try {
    const parsed = JSON.parse(raw);
    return {
      matcher: String(parsed?.matcher || "").trim(),
      syntax: normalizeAttachmentSyntax(parsed?.syntax, true),
      useGlobalIgnore: parsed?.useGlobalIgnore !== false,
      path: String(parsed?.path || "").trim(),
      renameOld: !!parsed?.renameOld,
    };
  } catch (_e) {
    return { ...defaults, path: raw };
  }
}

function stringifyAttachmentSaveActionValue(value) {
  const parsed = parseAttachmentSaveActionValue(JSON.stringify(value || {}));
  return JSON.stringify(parsed);
}

function resolveAttachmentMatcherSyntax(perFilterSyntax, defaultSyntax = attachmentSettingsCache.filterSyntax) {
  const choice = normalizeAttachmentSyntax(perFilterSyntax, true);
  return choice === "default" ? normalizeAttachmentSyntax(defaultSyntax, false) : choice;
}

function shouldApplyGlobalIgnore(value, defaultValue = true) {
  return value === undefined || value === null ? !!defaultValue : value !== false;
}

function globToRegExp(pattern) {
  let rx = "^";
  const s = String(pattern || "");
  for (let i = 0; i < s.length; i++) {
    const ch = s[i];
    if (ch === "*") {
      if (s[i + 1] === "*") {
        rx += ".*";
        i++;
      } else {
        rx += "[^/]*";
      }
    } else if (ch === "?") {
      rx += ".";
    } else if ("\\^$+?.()|{}[]".includes(ch)) {
      rx += "\\" + ch;
    } else {
      rx += ch;
    }
  }
  rx += "$";
  return new RegExp(rx, "i");
}

function validateAttachmentMatcher(matcher, syntax) {
  const text = String(matcher || "").trim();
  if (!text) {
    return { ok: true, matcher: "" };
  }
  try {
    if (syntax === "glob") {
      globToRegExp(text);
    } else {
      new RegExp(text);
    }
    return { ok: true, matcher: text };
  } catch (e) {
    return { ok: false, error: `Filename matcher is invalid for ${syntax}: ${e}` };
  }
}

function parseIgnorePatterns(text) {
  return String(text || "")
    .split(/\r?\n/)
    .map(line => line.trim())
    .filter(line => !!line && !line.startsWith("#"));
}

function filenameMatchesIgnore(filename, patterns) {
  const name = String(filename || "").trim();
  if (!name || !Array.isArray(patterns) || patterns.length === 0) {
    return false;
  }
  for (const pattern of patterns) {
    try {
      if (globToRegExp(pattern).test(name)) {
        return true;
      }
    } catch (_e) {
    }
  }
  return false;
}

function filenameMatchesMatcher(filename, matcher, syntax) {
  const name = String(filename || "").trim();
  const text = String(matcher || "").trim();
  if (!text) {
    return true;
  }
  if (syntax === "glob") {
    return globToRegExp(text).test(name);
  }
  return new RegExp(text).test(name);
}

function resolveAttachmentSaveDirectoryTemplate(pathFromFilter, defaultPathFromSettings) {
  const filterPath = String(pathFromFilter || "").trim();
  const defaultPath = String(defaultPathFromSettings || "").trim();
  return filterPath || defaultPath || "";
}

function parseAndValidateAttachmentSaveActionValue(actionValue) {
  const parsed = parseAttachmentSaveActionValue(actionValue);
  const syntax = resolveAttachmentMatcherSyntax(parsed.syntax, attachmentSettingsCache.filterSyntax);
  const matcherCheck = validateAttachmentMatcher(parsed.matcher, syntax);
  if (!matcherCheck.ok) {
    return matcherCheck;
  }
  const effectiveTemplate = resolveAttachmentSaveDirectoryTemplate(parsed.path, attachmentSettingsCache.defaultPath);
  if (!effectiveTemplate) {
    return { ok: false, error: "Attachment save path is empty. Set a filter path or configure a default attachment path in add-on settings." };
  }
  const templateCheck = parseAndValidatePathTemplate(effectiveTemplate, { allowEmpty: false });
  if (!templateCheck.ok) {
    return templateCheck;
  }
  return {
    ok: true,
    config: {
      matcher: matcherCheck.matcher,
      syntax: normalizeAttachmentSyntax(parsed.syntax, true),
      useGlobalIgnore: shouldApplyGlobalIgnore(parsed.useGlobalIgnore, true),
      renameOld: !!parsed.renameOld,
      path: String(parsed.path || "").trim(),
      effectiveTemplate: templateCheck.template,
    },
  };
}

function homeDirPath() {
  return dirService.get("Home", Ci.nsIFile).path;
}

function expandHomePath(path) {
  if (path === "~") {
    return homeDirPath();
  }
  if (path.startsWith("~/")) {
    return homeDirPath() + path.slice(1);
  }
  return path;
}

function sanitizePathComponent(value, fallback = "unknown") {
  let s = String(value || "").trim();
  s = s.replace(/[\x00-\x1F\x7F]/g, " ");
  s = s.replace(/[\\/:*?"<>|]/g, "_");
  s = s.replace(/\s+/g, " ").trim();
  s = s.replace(/^\.+$/, "");
  if (!s) {
    s = fallback;
  }
  if (s.length > 120) {
    s = s.slice(0, 120).trim();
  }
  return s || fallback;
}

function renderAttachmentPathTemplate(template, msgHdr) {
  const dateValue = Number(msgHdr?.date || 0);
  const dt = dateValue > 0 ? new Date(Math.floor(dateValue / 1000)) : new Date();
  const account = sanitizePathComponent(
    msgHdr?.folder?.server?.prettyName || msgHdr?.folder?.prettyName || "account",
    "account"
  );
  const subject = sanitizePathComponent(
    msgHdr?.mime2DecodedSubject || msgHdr?.subject || "no-subject",
    "no-subject"
  );
  const from = sanitizePathComponent(
    msgHdr?.mime2DecodedAuthor || msgHdr?.author || "unknown-from",
    "unknown-from"
  );
  const vars = {
    account,
    yyyy: String(dt.getFullYear()),
    mm: zeroPad2(dt.getMonth() + 1),
    dd: zeroPad2(dt.getDate()),
    hours: zeroPad2(dt.getHours()),
    minutes: zeroPad2(dt.getMinutes()),
    subject,
    from,
  };
  const rendered = template.replace(/{{\s*(account|yyyy|mm|dd|hours|minutes|subject|from)\s*}}/g, (_m, key) => vars[key] || "");
  return expandHomePath(rendered);
}

function nsFileFromPath(path) {
  const file = Cc["@mozilla.org/file/local;1"].createInstance(Ci.nsIFile);
  file.initWithPath(path);
  return file;
}

function ensureDirectoryExists(dir) {
  if (dir.exists()) {
    if (!dir.isDirectory()) {
      throw new Error(`Path exists but is not a directory: ${dir.path}`);
    }
    return;
  }
  const parent = dir.parent;
  if (parent && !parent.exists()) {
    ensureDirectoryExists(parent);
  }
  dir.create(Ci.nsIFile.DIRECTORY_TYPE, 0o755);
}

function splitFilename(filename) {
  const idx = filename.lastIndexOf(".");
  if (idx <= 0) {
    return { base: filename, ext: "" };
  }
  return { base: filename.slice(0, idx), ext: filename.slice(idx) };
}

function uniqueDestinationFile(dir, filename) {
  const first = dir.clone();
  first.append(filename);
  if (!first.exists()) {
    return first;
  }
  const parts = splitFilename(filename);
  for (let i = 1; i < 10000; i++) {
    const candidate = dir.clone();
    candidate.append(`${parts.base} (${i})${parts.ext}`);
    if (!candidate.exists()) {
      return candidate;
    }
  }
  throw new Error(`Could not allocate unique filename for ${filename}`);
}

function readFileBytes(file) {
  const fis = Cc["@mozilla.org/network/file-input-stream;1"].createInstance(Ci.nsIFileInputStream);
  const bis = Cc["@mozilla.org/binaryinputstream;1"].createInstance(Ci.nsIBinaryInputStream);
  try {
    fis.init(file, 0x01, 0, 0);
    bis.setInputStream(fis);
    const len = file.fileSize;
    if (len <= 0) return [];
    const bytes = bis.readByteArray(len);
    return bytes;
  } finally {
    try { bis.close(); } catch (_e) {
      try { fis.close(); } catch (_e2) {}
    }
  }
}

function filesAreIdentical(fileA, fileB) {
  try {
    if (!fileA.exists() || !fileB.exists()) {
      consoleService.logStringMessage(
        `[ragFilterAction] filesAreIdentical: exists check failed A=${fileA.exists()} B=${fileB.exists()}`
      );
      return false;
    }
    const sizeA = fileA.fileSize;
    const sizeB = fileB.fileSize;
    if (sizeA !== sizeB) {
      consoleService.logStringMessage(
        `[ragFilterAction] filesAreIdentical: size mismatch A=${sizeA} B=${sizeB}`
      );
      return false;
    }
    const a = readFileBytes(fileA);
    const b = readFileBytes(fileB);
    if (a.length !== b.length) {
      consoleService.logStringMessage(
        `[ragFilterAction] filesAreIdentical: read length mismatch A=${a.length} B=${b.length} (fileSize=${sizeA})`
      );
      return false;
    }
    for (let i = 0; i < a.length; i++) {
      if (a[i] !== b[i]) {
        consoleService.logStringMessage(
          `[ragFilterAction] filesAreIdentical: byte mismatch at offset ${i} A=${a[i]} B=${b[i]} (len=${a.length})`
        );
        return false;
      }
    }
    consoleService.logStringMessage(
      `[ragFilterAction] filesAreIdentical: IDENTICAL ${fileA.path} vs ${fileB.path} (${sizeA} bytes)`
    );
    return true;
  } catch (e) {
    consoleService.logStringMessage(
      `[ragFilterAction] filesAreIdentical: exception: ${e}`
    );
    return false;
  }
}

function writeBytesToFile(file, bytes) {
  const fos = Cc["@mozilla.org/network/file-output-stream;1"].createInstance(Ci.nsIFileOutputStream);
  const bos = Cc["@mozilla.org/binaryoutputstream;1"].createInstance(Ci.nsIBinaryOutputStream);
  try {
    fos.init(file, 0x02 | 0x08 | 0x20, 0o644, 0);
    bos.setOutputStream(fos);
    bos.writeByteArray(Array.from(bytes), bytes.length);
  } finally {
    try {
      bos.close();
    } catch (_e) {
      try {
        fos.close();
      } catch (_e2) {
      }
    }
  }
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

const POST_TIMEOUT_MS = 15000;

async function fetchWithTimeout(url, init, timeoutMs) {
  // AbortController is not available in the XPCOM experiment context.
  if (typeof AbortController !== "undefined") {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    try {
      return await fetch(url, { ...init, signal: controller.signal });
    } finally {
      clearTimeout(timer);
    }
  }
  return await fetch(url, init);
}

/* POST raw RFC822 bytes to the OCaml ingest endpoint as message/rfc822.
   Retries with 127.0.0.1 if localhost fails (common IPv6/IPv4 mismatch). */
async function postMessage(endpoint, rawBytes, msgHdr) {
  const msgId = msgHdr?.messageId || "";
  let blob = new Blob([rawBytes], { type: "message/rfc822" });

  let headers = new Headers();
  headers.set("Content-Type", "message/rfc822");
  headers.set("X-Thunderbird-Message-Id", msgId);

  consoleService.logStringMessage(
    `[ragFilterAction] postMessage: POSTing ${rawBytes.length} bytes to ${endpoint} messageId=${msgId}`
  );

  let resp;
  try {
    resp = await fetchWithTimeout(endpoint, {
      method: "POST",
      headers,
      body: blob,
    }, POST_TIMEOUT_MS);
  } catch (e) {
    const msg = String(e || "");
    const isNetworkError = msg.includes("NetworkError") || msg.includes("Failed to fetch");

    // Common failure mode: localhost resolves to ::1 but server is bound only to 127.0.0.1.
    if (isNetworkError && typeof endpoint === "string" && endpoint.startsWith("http://localhost")) {
      const endpoint2 = endpoint.replace("http://localhost", "http://127.0.0.1");
      try {
        consoleService.logStringMessage(
          `[ragFilterAction] postMessage: retrying with endpoint=${endpoint2} after NetworkError (localhost->127.0.0.1) messageId=${msgId}`
        );
        resp = await fetchWithTimeout(endpoint2, {
          method: "POST",
          headers,
          body: blob,
        }, POST_TIMEOUT_MS);
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
    consoleService.logStringMessage(
      `[ragFilterAction] postMessage: server returned ${resp.status} messageId=${msgId} body=${bodyText}`
    );
    throw new Error(`POST failed: ${resp.status} ${resp.statusText}${bodyText ? ` body=${bodyText}` : ""}`);
  }

  consoleService.logStringMessage(
    `[ragFilterAction] postMessage: success ${resp.status} messageId=${msgId}`
  );
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

async function resolveMessageIdFromHeaderMessageId(headerMessageId) {
  const api = getWebextApi() || getBackgroundWebextApi();
  if (!api) {
    return null;
  }
  const trimmed = String(headerMessageId || "").trim();
  if (!trimmed) {
    return null;
  }
  try {
    const result = await api.messages.query({ headerMessageId: trimmed });
    const messageId = result?.messages?.[0]?.id || null;
    if (messageId) {
      return messageId;
    }
  } catch (_e) {
  }
  if (trimmed.startsWith("<") && trimmed.endsWith(">")) {
    try {
      const result = await api.messages.query({ headerMessageId: trimmed.slice(1, -1) });
      return result?.messages?.[0]?.id || null;
    } catch (_e) {
      return null;
    }
  }
  return null;
}

async function resolveMessageIdFromHdr(msgHdr) {
  return await resolveMessageIdFromHeaderMessageId(msgHdr?.messageId || "");
}

async function saveAttachmentsByMessageId(messageId, directoryPath, headerMessageId = "", options = {}) {
  const msgHdr = getMsgHdrForMessageId(messageId);
  return await saveAttachmentsFromMsgHdr(msgHdr, directoryPath, headerMessageId, options);
}

async function describeAttachmentsByMessageId(messageId, directoryPath = "", headerMessageId = "", options = {}) {
  const msgHdr = getMsgHdrForMessageId(messageId);
  return await describeAttachmentsFromMsgHdr(msgHdr, directoryPath, { headerMessageId, ...options });
}

function openFileManagerForPath(path) {
  const targetPath = String(path || "").trim();
  if (!targetPath) {
    throw new Error("Path missing");
  }
  const file = nsFileFromPath(targetPath);
  if (!file.exists()) {
    throw new Error(`Path does not exist: ${targetPath}`);
  }
  try {
    const openBin = nsFileFromPath("/usr/bin/open");
    if (openBin.exists()) {
      const proc = Cc["@mozilla.org/process/util;1"].createInstance(Ci.nsIProcess);
      proc.init(openBin);
      const args = file.isDirectory() ? [targetPath] : ["-R", targetPath];
      if (typeof proc.runw === "function") {
        proc.runw(false, args, args.length);
      } else {
        proc.run(false, args, args.length);
      }
      return true;
    }
  } catch (_e) {
  }
  try {
    file.reveal();
    return true;
  } catch (_e) {
  }
  try {
    const toLaunch = file.isDirectory() ? file : file.parent;
    toLaunch.launch();
    return true;
  } catch (e) {
    throw new Error(`Could not open folder for path ${targetPath}: ${e}`);
  }
}

/* Attempt to get decrypted message bytes via the WebExtension messages.getRaw API
   with {decrypt:true}.  Validates that the result is actually decrypted (not still
   PGP/S/MIME wrapper) and falls back to getFull() for S/MIME envelope-only cases.
   Returns Uint8Array of usable RFC822 bytes, or null if decryption failed. */
async function fetchDecryptedMessageBytes(msgHdr) {
  const api = getWebextApi() || getBackgroundWebextApi();
  if (!api) {
    return null;
  }

  let messageId = await resolveMessageIdFromHdr(msgHdr);
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
      return "ThunderRAG: Send to URL";
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

function makeSaveAttachmentsAction() {
  return {
    id: ACTION_SAVE_ATTACHMENTS_ID,

    get name() {
      return "ThunderRAG: Save attachments";
    },

    isValidForType(type, scope) {
      return true;
    },

    validateActionValue(actionValue, actionFolder, filterType) {
      let result = parseAndValidateAttachmentSaveActionValue(actionValue);
      if (!result.ok) {
        return result.error;
      }
      return null;
    },

    allowDuplicates: true,

    applyAction(msgHdrs, actionValue, copyListener, filterType, msgWindow) {
      (async () => {
        try {
          let parsed = parseAndValidateAttachmentSaveActionValue(actionValue);
          if (!parsed.ok) {
            throw new Error(parsed.error);
          }

          for (let msgHdr of msgHdrs) {
            try {
              const headerMessageId = (msgHdr?.messageId || "").trim();
              if (!headerMessageId) {
                throw new Error("Missing msgHdr.messageId");
              }
              const directoryPath = renderAttachmentPathTemplate(parsed.config.effectiveTemplate, msgHdr);
              const item = enqueueAttachmentSave(headerMessageId, directoryPath, {
                matcher: parsed.config.matcher,
                syntax: parsed.config.syntax,
                useGlobalIgnore: parsed.config.useGlobalIgnore,
                renameOld: parsed.config.renameOld,
              });
              consoleService.logStringMessage(
                `[ragFilterAction] saveAttachments: queued id=${item.id} directory=${directoryPath} matcher=${item.matcher} syntax=${item.syntax} useGlobalIgnore=${item.useGlobalIgnore ? "1" : "0"} messageId=${headerMessageId}`
              );
            } catch (e) {
              consoleService.logStringMessage(
                `[ragFilterAction] saveAttachments: failed for messageId=${msgHdr?.messageId || ""}: ${e}`
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
      return false;
    },

    QueryInterface: ChromeUtils.generateQI(["nsIMsgFilterCustomAction"]),
  };
}

let archivePromiseChain = Promise.resolve();

function archiveMessagesAsync(msgHdrs) {
  return new Promise((resolve, reject) => {
    if (!MessageArchiver) {
      reject(new Error("MessageArchiver module not available"));
      return;
    }
    if (!msgHdrs.length) {
      resolve();
      return;
    }
    try {
      const archiver = new MessageArchiver();
      archiver.oncomplete = () => resolve();
      archiver.archiveMessages(msgHdrs);
    } catch (e) {
      reject(e);
    }
  });
}

function makeArchiveAction() {
  return {
    id: ACTION_ARCHIVE_ID,

    get name() {
      return "ThunderRAG: Archive";
    },

    isValidForType(type, scope) {
      return true;
    },

    validateActionValue(actionValue, actionFolder, filterType) {
      return null;
    },

    allowDuplicates: false,

    applyAction(msgHdrs, actionValue, copyListener, filterType, msgWindow) {
      const hdrs = Array.from(msgHdrs);
      archivePromiseChain = archivePromiseChain.then(async () => {
        try {
          if (!MessageArchiver) {
            throw new Error("MessageArchiver module not available");
          }
          if (!MessageArchiver.canArchive(hdrs, true)) {
            consoleService.logStringMessage(
              `[ragFilterAction] archive: cannot archive ${hdrs.length} message(s) — archiving disabled for account`
            );
            return;
          }
          await archiveMessagesAsync(hdrs);
          consoleService.logStringMessage(
            `[ragFilterAction] archive: archived ${hdrs.length} message(s)`
          );
        } catch (e) {
          consoleService.logStringMessage(
            `[ragFilterAction] archive: failed: ${e}`
          );
        } finally {
          safeFinishCopy(copyListener);
        }
      });
    },

    get isAsync() {
      return true;
    },

    get needsBody() {
      return false;
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
  if (!hasCustomAction(filterService, ACTION_ID)) {
    try {
      filterService.addCustomAction(makeCustomAction());
      consoleService.logStringMessage(`[ragFilterAction] ${logPrefix}: custom action registered`);
    } catch (e) {
      consoleService.logStringMessage(`[ragFilterAction] ${logPrefix}: addCustomAction failed: ${e}`);
    }
  } else {
    consoleService.logStringMessage(`[ragFilterAction] ${logPrefix}: custom action already registered`);
  }

  if (!hasCustomAction(filterService, ACTION_SAVE_ATTACHMENTS_ID)) {
    try {
      filterService.addCustomAction(makeSaveAttachmentsAction());
      consoleService.logStringMessage(`[ragFilterAction] ${logPrefix}: save-attachments action registered`);
    } catch (e) {
      consoleService.logStringMessage(`[ragFilterAction] ${logPrefix}: addCustomAction(save-attachments) failed: ${e}`);
    }
  } else {
    consoleService.logStringMessage(`[ragFilterAction] ${logPrefix}: save-attachments action already registered`);
  }

  if (!hasCustomAction(filterService, ACTION_ARCHIVE_ID)) {
    try {
      filterService.addCustomAction(makeArchiveAction());
      consoleService.logStringMessage(`[ragFilterAction] ${logPrefix}: archive action registered`);
    } catch (e) {
      consoleService.logStringMessage(`[ragFilterAction] ${logPrefix}: addCustomAction(archive) failed: ${e}`);
    }
  } else {
    consoleService.logStringMessage(`[ragFilterAction] ${logPrefix}: archive action already registered`);
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
        getAttachmentSaveQueue: async () => {
          return attachmentSaveQueue.map((it) => ({
            id: it.id,
            headerMessageId: it.headerMessageId,
            directoryPath: it.directoryPath,
            matcher: it.matcher,
            syntax: it.syntax,
            useGlobalIgnore: it.useGlobalIgnore,
            renameOld: !!it.renameOld,
            timestamp: it.timestamp,
          }));
        },
        completeAttachmentSaveItem: async (itemId) => {
          const removed = dequeueAttachmentSave(itemId);
          try {
            consoleService.logStringMessage(
              `[ragFilterAction] completeAttachmentSaveItem: id=${itemId} removed=${removed} queueLength=${attachmentSaveQueue.length}`
            );
          } catch (_e) {
            // ignore
          }
          return removed;
        },
        setAttachmentSettings: async (settingsJson) => {
          try {
            const parsed = settingsJson ? JSON.parse(settingsJson) : {};
            updateAttachmentSettingsCache(parsed || {});
            return true;
          } catch (_e) {
            updateAttachmentSettingsCache({});
            return false;
          }
        },
        renderAttachmentPathByMessageId: async (messageId, template) => {
          const msgHdr = getMsgHdrForMessageId(messageId);
          const checked = parseAndValidatePathTemplate(template, { allowEmpty: false });
          if (!checked.ok) {
            throw new Error(checked.error);
          }
          return renderAttachmentPathTemplate(checked.template, msgHdr);
        },
        describeAttachmentsByMessageId: async (messageId, directoryPath, headerMessageId, optionsJson) => {
          let options = {};
          try {
            options = optionsJson ? JSON.parse(optionsJson) : {};
          } catch (_e) {
            options = {};
          }
          return await describeAttachmentsByMessageId(messageId, directoryPath || "", headerMessageId || "", options);
        },
        saveAttachmentsByMessageId: async (messageId, directoryPath, headerMessageId, optionsJson) => {
          let options = {};
          try {
            options = optionsJson ? JSON.parse(optionsJson) : {};
          } catch (_e) {
            options = {};
          }
          return await saveAttachmentsByMessageId(messageId, directoryPath, headerMessageId || "", options);
        },
        openFileManagerForPath: async (path) => {
          return openFileManagerForPath(path);
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
                ingestStatusCache.set(k, { ingested: !!v.ingested, processed: !!v.processed, partial: !!v.partial, trigger_active: !!v.trigger_active, reply_by: v.reply_by || "" });
              } else {
                // Legacy boolean format fallback.
                ingestStatusCache.set(k, { ingested: !!v, processed: false, partial: false, trigger_active: false, reply_by: "" });
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
