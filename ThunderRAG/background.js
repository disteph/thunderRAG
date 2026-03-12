/*
  ThunderRAG Thunderbird add-on: background script

  Responsibilities
  - Registers filter action hooks (if present) on startup.
  - Opens the query UI tab when the browser action is clicked.
  - Provides privileged Thunderbird APIs to the UI via runtime messages:
    - Resolving a header Message-ID (the RFC822 Message-Id / "doc_id") to a Thunderbird messageId.
    - Opening a message in a tab.
    - Fetching the raw RFC822 content of a message.

  Notes
  - The OCaml server uses Thunderbird message IDs (Message-Id header strings) as stable pointers.
    The UI and OCaml server never read mail from disk; Thunderbird is the source of truth.
*/

/* Register the experiment-API filter action on add-on startup (if available). */
async function startup() {
  try {
    if (browser.ragFilterAction?.register) {
      await browser.ragFilterAction.register();
    }
  } catch (e) {
    console.error(e);
  }
}

/* Open the ThunderRAG query UI in a new Thunderbird tab. */
function openQueryTab() {
  try {
    const url = browser.runtime.getURL("ui/query.html");
    browser.tabs.create({ url });
  } catch (e) {
    console.error(e);
  }
}

/* Notify any open task UI tabs that something changed (new task, context ready, etc.) */
function notifyTasksChanged() {
  try {
    browser.runtime.sendMessage({ type: "tasksChanged" }).catch(() => {});
  } catch (_) {}
}

/* Open the ThunderRAG task manager UI, optionally filtered to emails. */
function openTasksTab(emailIds) {
  try {
    let url = browser.runtime.getURL("ui/tasks.html");
    if (emailIds && emailIds.length) {
      url += `?email_ids=${encodeURIComponent(JSON.stringify(emailIds))}`;
    }
    browser.tabs.create({ url });
  } catch (e) {
    console.error(e);
  }
}

/* Wire the browser-action (toolbar button) click to open the unified task manager tab. */
if (browser.browserAction && browser.browserAction.onClicked) {
  browser.browserAction.onClicked.addListener(() => {
    openTasksTab();
  });
}

/*
  Thunderbird's UI and OCaml server traffic commonly refers to messages by header Message-Id.
  This helper resolves that stable identifier to the internal Thunderbird numeric message id,
  with a fallback that strips angle brackets.
*/
async function resolveHeaderMessageId(headerMessageId) {
  if (!headerMessageId || typeof headerMessageId !== "string") {
    throw new Error("Missing headerMessageId");
  }
  const hmid = headerMessageId.trim();
  const result = await browser.messages.query({ headerMessageId: hmid });
  const first = result?.messages?.[0];
  if (first) return first.id;
  if (hmid.startsWith("<") && hmid.endsWith(">")) {
    const result2 = await browser.messages.query({ headerMessageId: hmid.slice(1, -1) });
    const first2 = result2?.messages?.[0];
    if (first2) return first2.id;
  }
  throw new Error(`Message not found for headerMessageId: ${hmid}`);
}

/* Fetch the raw RFC822 bytes for a message, preferring the decrypted variant.
   Falls back to the non-decrypted form if {decrypt:true} is unsupported. */
async function getRawDecrypted(messageId) {
  let raw;
  try {
    raw = await browser.messages.getRaw(messageId, { decrypt: true });
  } catch (_e) {
    raw = await browser.messages.getRaw(messageId);
  }
  if (typeof raw !== "string") {
    throw new Error("getRaw did not return a string");
  }
  return raw;
}

/*
  Central runtime.onMessage dispatcher.  Handles three message types from the UI:
  - openMessageByHeaderMessageId: resolve header Message-Id → open in a tab.
  - getRawMessageByHeaderMessageId: resolve + return raw RFC822 text.
  - ingestMessageByHeaderMessageId: resolve + POST raw bytes to an OCaml ingest endpoint.
*/
browser.runtime.onMessage.addListener(async (msg) => {
  try {
    if (!msg || typeof msg !== "object") {
      return;
    }

    if (msg.type === "openMessageByHeaderMessageId") {
      const messageId = await resolveHeaderMessageId(msg.headerMessageId);
      return await browser.messageDisplay.open({
        messageId,
        location: "tab",
        active: true,
      });
    }

    if (msg.type === "getRawMessageByHeaderMessageId") {
      const headerMessageId = (msg.headerMessageId || "").trim();
      const messageId = await resolveHeaderMessageId(headerMessageId);
      const raw = await getRawDecrypted(messageId);
      return { headerMessageId, raw };
    }

    if (msg.type === "extractBody") {
      const headerMessageId = (msg.headerMessageId || "").trim();
      const endpoint = (msg.endpoint || await getServerBase()).trim();
      const summarize = !!msg.summarize;
      if (!headerMessageId) throw new Error("Missing headerMessageId");
      const messageId = await resolveHeaderMessageId(headerMessageId);
      const raw = await getRawDecrypted(messageId);
      const resp = await fetch(`${endpoint}/admin/extract_body`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ raw, doc_id: headerMessageId, summarize }),
      });
      return await resp.json();
    }

    if (msg.type === "fetchIngestedDetail") {
      const id = (msg.id || "").trim();
      const endpoint = (msg.endpoint || await getServerBase()).trim();
      if (!id) throw new Error("Missing id");
      debugLog(`[fetchIngestedDetail] id=${id} endpoint=${endpoint}`);
      const resp = await fetch(`${endpoint}/admin/ingested_detail`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ id }),
      });
      const data = await resp.json();
      debugLog(`[fetchIngestedDetail] response:`, data);
      return data;
    }

    if (msg.type === "sendReply") {
      const headerMessageId = (msg.headerMessageId || "").trim();
      const body = msg.body || "";
      const replyType = msg.replyType || "sender";
      if (!headerMessageId) throw new Error("Missing headerMessageId");
      const messageId = await resolveHeaderMessageId(headerMessageId);
      const rt = replyType === "all" ? "replyToAll" : "replyToSender";
      const composeTab = await browser.compose.beginReply(messageId, rt, {
        plainTextBody: body,
        isPlainText: true,
      });
      const saved = await browser.compose.saveMessage(composeTab.id, { mode: "draft" });
      await browser.tabs.remove(composeTab.id);
      return { ok: true, saved };
    }

    if (msg.type === "sendReplyNow") {
      const headerMessageId = (msg.headerMessageId || "").trim();
      const body = msg.body || "";
      const replyType = msg.replyType || "sender";
      if (!headerMessageId) throw new Error("Missing headerMessageId");
      const messageId = await resolveHeaderMessageId(headerMessageId);
      const rt = replyType === "all" ? "replyToAll" : "replyToSender";
      const composeTab = await browser.compose.beginReply(messageId, rt, {
        plainTextBody: body,
        isPlainText: true,
      });
      const result = await browser.compose.sendMessage(composeTab.id, { mode: "sendNow" });
      return { ok: true, result };
    }

    if (msg.type === "openCompose") {
      const details = {
        to: msg.to || "",
        cc: msg.cc || "",
        bcc: msg.bcc || "",
        subject: msg.subject || "",
        plainTextBody: msg.body || "",
        isPlainText: true,
      };
      if (msg.inReplyTo) {
        try {
          const messageId = await resolveHeaderMessageId(msg.inReplyTo);
          const rt = (msg.cc || "").trim() ? "replyToAll" : "replyToSender";
          const composeTab = await browser.compose.beginReply(messageId, rt, details);
          return { ok: true, tabId: composeTab.id };
        } catch (_e) {
          // Fall back to beginNew if the original message can't be resolved
        }
      }
      const composeTab = await browser.compose.beginNew(null, details);
      return { ok: true, tabId: composeTab.id };
    }

    if (msg.type === "sendCompose") {
      const details = {
        to: msg.to || "",
        cc: msg.cc || "",
        bcc: msg.bcc || "",
        subject: msg.subject || "",
        plainTextBody: msg.body || "",
        isPlainText: true,
      };
      let composeTab;
      if (msg.inReplyTo) {
        try {
          const messageId = await resolveHeaderMessageId(msg.inReplyTo);
          const rt = (msg.cc || "").trim() ? "replyToAll" : "replyToSender";
          composeTab = await browser.compose.beginReply(messageId, rt, details);
        } catch (_e) {
          composeTab = await browser.compose.beginNew(null, details);
        }
      } else {
        composeTab = await browser.compose.beginNew(null, details);
      }
      const result = await browser.compose.sendMessage(composeTab.id, { mode: "sendNow" });
      return { ok: true, result };
    }

    if (msg.type === "validateMessageIds") {
      const ids = Array.isArray(msg.ids) ? msg.ids : [];
      const results = {};
      for (const id of ids) {
        try {
          const hmid = (id || "").trim();
          if (!hmid) { results[id] = { exists: false, folder: "", folderType: "" }; continue; }
          const result = await browser.messages.query({ headerMessageId: hmid });
          let found = result?.messages?.[0];
          if (!found && hmid.startsWith("<") && hmid.endsWith(">")) {
            const result2 = await browser.messages.query({ headerMessageId: hmid.slice(1, -1) });
            found = result2?.messages?.[0];
          }
          if (!found) {
            results[id] = { exists: false, folder: "", folderType: "" };
          } else {
            results[id] = {
              exists: true,
              folder: found.folder?.path || "",
              folderType: found.folder?.type || "",
              junk: found.junk === true,
            };
          }
        } catch (_) {
          results[id] = { exists: false, folder: "", folderType: "" };
        }
      }
      return results;
    }

    if (msg.type === "ingestMessageByHeaderMessageId") {
      const headerMessageId = (msg.headerMessageId || "").trim();
      let endpoint = msg.endpoint;
      if (!endpoint || typeof endpoint !== "string") {
        throw new Error("Missing endpoint");
      }
      endpoint = endpoint.trim();

      const messageId = await resolveHeaderMessageId(headerMessageId);
      const raw = await getRawDecrypted(messageId);
      debugLog(`[ingestByHdrMsgId] headerMessageId=${headerMessageId} endpoint=${endpoint}`);

      const bytes = new TextEncoder().encode(raw);
      const blob = new Blob([bytes], { type: "message/rfc822" });
      const headers = new Headers();
      headers.set("Content-Type", "message/rfc822");
      headers.set("X-Thunderbird-Message-Id", headerMessageId);

      const resp = await fetch(endpoint, {
        method: "POST",
        headers,
        body: blob,
      });
      const text = await resp.text();
      debugLog(`[ingestByHdrMsgId] response: ${resp.status} ${text.slice(0, 200)}`);
      if (resp.ok) notifyTasksChanged();
      return { ok: resp.ok, status: resp.status, statusText: resp.statusText, body: text };
    }
  } catch (e) {
    console.error(e);
  }
});

/*
  Ingest queue processor (Approach B).

  The experiment API's applyAction enqueues encrypted messages that could not be
  decrypted in filter context.  This poller checks the queue every few seconds,
  processes each item using the background script's full WebExtension API access
  (messages.getRaw/getFull with decrypt:true), and removes completed items.

  For S/MIME emails, getRaw(decrypt:true) may return MIME with base64-encoded parts
  that the OCaml parser can't extract.  In that case we fall back to getFull(decrypt:true)
  which returns decoded body parts, then synthesize a clean RFC822.
*/
let ingestQueueInterval = null;
let ingestQueueProcessing = false;

/* Walk a messages.getFull() MIME tree and return the best readable body part,
   preferring text/plain over text/html.  Returns {kind, body} or null. */
function extractBestBodyFromFull(full) {
  const walk = (part) => {
    if (!part) return null;
    const ct = String(part.contentType || "").toLowerCase();
    const body =
      typeof part.body === "string"
        ? part.body
        : Array.isArray(part.body)
          ? part.body.join("")
          : "";
    if (body && ct.startsWith("text/plain")) return { kind: "text/plain", body };
    if (Array.isArray(part.parts)) {
      for (const p of part.parts) {
        const r = walk(p);
        if (r && r.kind === "text/plain") return r;
      }
      for (const p of part.parts) {
        const r = walk(p);
        if (r) return r;
      }
    }
    if (body && ct.startsWith("text/html")) return { kind: "text/html", body };
    return null;
  };
  return walk(full);
}

/* Synthesize a minimal RFC822 message from headers and a decoded body.
   Used when getFull(decrypt:true) provides the decoded content. */
function synthesizeRfc822(headerMessageId, msgHeaders, best) {
  const lines = [];
  if (msgHeaders?.author)     lines.push(`From: ${msgHeaders.author}`);
  if (msgHeaders?.recipients) lines.push(`To: ${msgHeaders.recipients}`);
  if (msgHeaders?.ccList)     lines.push(`Cc: ${msgHeaders.ccList}`);
  if (msgHeaders?.bccList)    lines.push(`Bcc: ${msgHeaders.bccList}`);
  if (msgHeaders?.subject)    lines.push(`Subject: ${msgHeaders.subject}`);
  if (msgHeaders?.date)       lines.push(`Date: ${new Date(msgHeaders.date).toUTCString()}`);
  const mid = headerMessageId || "";
  lines.push(`Message-Id: ${mid.startsWith("<") ? mid : "<" + mid + ">"}`);
  lines.push("MIME-Version: 1.0");
  lines.push(`Content-Type: ${best.kind}; charset=UTF-8`);
  lines.push("Content-Transfer-Encoding: 8bit");
  return `${lines.join("\r\n")}\r\n\r\n${best.body}`;
}

/* Check if raw RFC822 text still looks like S/MIME-wrapped or encrypted content. */
function rawLooksEncrypted(rawText) {
  const s = rawText.toLowerCase();
  if (s.includes("smime.p7m")) return true;
  if (s.includes("application/pkcs7-mime")) return true;
  if (s.includes("application/x-pkcs7-mime")) return true;
  if (s.includes("-----begin pgp message-----")) return true;
  if (s.includes("application/pgp-encrypted")) return true;
  return false;
}

/* Obtain the best RFC822 bytes for a message, using getFull fallback for S/MIME.
   Returns a string ready to POST to the OCaml server's /ingest endpoint. */
async function getDecryptedRfc822ForIngest(messageId, headerMessageId) {
  const raw = await getRawDecrypted(messageId);

  if (!rawLooksEncrypted(raw)) {
    return raw;
  }

  console.log(`[ThunderRAG] ingestQueue: getRaw still encrypted for ${headerMessageId}, trying getFull`);

  // Try getFull with decrypt — returns parsed/decoded MIME parts for S/MIME after decrypt.
  let best = null;
  try {
    const full = await browser.messages.getFull(messageId, { decrypt: true });
    best = extractBestBodyFromFull(full);
    if (best && best.body?.trim()) {
      console.log(`[ThunderRAG] getFull(decrypt:true) succeeded for ${headerMessageId}: ${best.kind}, ${best.body.length} chars`);
    } else {
      console.log(`[ThunderRAG] getFull(decrypt:true) returned no readable body for ${headerMessageId}. Top-level contentType: ${full?.contentType || '?'}`);
    }
  } catch (e) {
    console.warn(`[ThunderRAG] getFull(decrypt:true) threw for ${headerMessageId}: ${e}`);
  }

  // If decrypt variant failed, try getFull without decrypt.
  if (!best || !best.body?.trim()) {
    try {
      const full2 = await browser.messages.getFull(messageId);
      best = extractBestBodyFromFull(full2);
      if (best && best.body?.trim()) {
        console.log(`[ThunderRAG] getFull(no-decrypt) succeeded for ${headerMessageId}: ${best.kind}, ${best.body.length} chars`);
      } else {
        console.log(`[ThunderRAG] getFull(no-decrypt) also returned no readable body for ${headerMessageId}. Top-level contentType: ${full2?.contentType || '?'}`);
      }
    } catch (e) {
      console.warn(`[ThunderRAG] getFull(no-decrypt) threw for ${headerMessageId}: ${e}`);
    }
  }

  if (best && typeof best.body === "string" && best.body.trim() !== "") {
    // Get message headers for synthesis
    let msgHeaders = {};
    try {
      const msg = await browser.messages.get(messageId);
      msgHeaders = msg || {};
    } catch (_e) {
      // use empty headers
    }
    const synth = synthesizeRfc822(headerMessageId, msgHeaders, best);
    console.log(`[ThunderRAG] ingestQueue: synthesized RFC822 from getFull for ${headerMessageId} (${best.kind}, ${best.body.length} chars)`);
    return synth;
  }

  // Fallback: try the experiment API's MsgHdrToMimeMessage-based decryption.
  if (browser.ragFilterAction?.getDecryptedBodyText) {
    try {
      const decrypted = await browser.ragFilterAction.getDecryptedBodyText(messageId);
      if (decrypted && typeof decrypted.body === "string" && decrypted.body.trim() !== "") {
        let msgHeaders = {};
        try {
          const msg = await browser.messages.get(messageId);
          msgHeaders = msg || {};
        } catch (_e) {
          // use empty headers
        }
        const synth = synthesizeRfc822(headerMessageId, msgHeaders, decrypted);
        console.log(`[ThunderRAG] getDecryptedBodyText succeeded for ${headerMessageId} (${decrypted.kind}, ${decrypted.body.length} chars)`);
        return synth;
      }
      console.log(`[ThunderRAG] getDecryptedBodyText returned no body for ${headerMessageId}`);
    } catch (e) {
      console.warn(`[ThunderRAG] getDecryptedBodyText threw for ${headerMessageId}: ${e}`);
    }
  }

  // Last resort: return raw even though it looks encrypted.
  console.warn(`[ThunderRAG] all decryption fallbacks failed for ${headerMessageId}, using raw as-is`);
  return raw;
}

async function processIngestQueue() {
  if (ingestQueueProcessing) return;
  if (!browser.ragFilterAction?.getIngestQueue) return;

  ingestQueueProcessing = true;
  try {
    const queue = await browser.ragFilterAction.getIngestQueue();
    if (!queue || !queue.length) return;

    console.log(`[ThunderRAG] ingestQueue: processing ${queue.length} item(s)`);

    for (const item of queue) {
      try {
        const headerMessageId = (item.headerMessageId || "").trim();
        const endpoint = (item.endpoint || "").trim();
        if (!headerMessageId || !endpoint) {
          await browser.ragFilterAction.completeIngestItem(item.id);
          continue;
        }

        const messageId = await resolveHeaderMessageId(headerMessageId);
        const rfc822 = await getDecryptedRfc822ForIngest(messageId, headerMessageId);

        const bytes = new TextEncoder().encode(rfc822);
        const blob = new Blob([bytes], { type: "message/rfc822" });
        const headers = new Headers();
        headers.set("Content-Type", "message/rfc822");
        const mid = headerMessageId;
        headers.set("X-Thunderbird-Message-Id", mid.startsWith("<") ? mid : "<" + mid + ">");

        const resp = await fetch(endpoint, { method: "POST", headers, body: blob });
        if (resp.ok) {
          console.log(`[ThunderRAG] ingestQueue: success for ${headerMessageId}`);
          notifyTasksChanged();
        } else {
          console.warn(`[ThunderRAG] ingestQueue: POST ${resp.status} for ${headerMessageId}`);
        }
      } catch (e) {
        console.warn(`[ThunderRAG] ingestQueue: failed for ${item.headerMessageId}: ${e}`);
      }
      // Always dequeue — retrying indefinitely would be worse than skipping.
      try {
        await browser.ragFilterAction.completeIngestItem(item.id);
      } catch (_e) {
        // ignore
      }
    }
  } catch (e) {
    // getIngestQueue may not be available yet; silently ignore.
    if (!String(e).includes("not a function")) {
      console.warn(`[ThunderRAG] ingestQueue poll error: ${e}`);
    }
  } finally {
    ingestQueueProcessing = false;
  }
}

function startIngestQueuePoller() {
  if (ingestQueueInterval) return;
  // Poll every 5 seconds.  Lightweight when the queue is empty (single API call).
  ingestQueueInterval = setInterval(processIngestQueue, 5000);
  // Also run immediately after a short delay (give the experiment API time to initialize).
  setTimeout(processIngestQueue, 2000);
}

function stopIngestQueuePoller() {
  if (ingestQueueInterval) {
    clearInterval(ingestQueueInterval);
    ingestQueueInterval = null;
  }
}

/*
  Task evidence queue poller.

  Periodically polls GET /task/needs_evidence to discover task_emails rows
  that need raw RFC822 bodies uploaded.  For each doc_id, fetches the raw
  message from Thunderbird and POSTs it to /task/evidence.  After all
  uploads for a task complete, signals /task/evidence_done.
*/
let taskEvidenceProcessing = false;
let taskEvidenceInterval = null;

async function processTaskEvidenceQueue() {
  if (taskEvidenceProcessing) return;
  taskEvidenceProcessing = true;
  try {
    const base = await getServerBase();
    const resp = await fetch(`${base}/task/needs_evidence`);
    if (!resp.ok) return;
    const data = await resp.json();
    const tasks = data.tasks || [];
    if (tasks.length === 0) return;

    debugLog(`[ThunderRAG] taskEvidence: ${tasks.length} task(s) need evidence`);

    for (const task of tasks) {
      const taskId = task.task_id;
      const docIds = task.doc_ids || [];
      let uploadedCount = 0;

      for (const docId of docIds) {
        try {
          // Resolve header message ID and fetch raw RFC822
          const messageId = await resolveHeaderMessageId(docId);
          if (!messageId) {
            debugWarn(`[ThunderRAG] taskEvidence: cannot resolve ${docId}`);
            continue;
          }
          const raw = await getRawDecrypted(messageId);
          if (!raw) {
            debugWarn(`[ThunderRAG] taskEvidence: no raw for ${docId}`);
            continue;
          }

          const bytes = new TextEncoder().encode(raw);
          const blob = new Blob([bytes], { type: "message/rfc822" });
          const headers = new Headers();
          headers.set("Content-Type", "message/rfc822");
          headers.set("X-Task-Id", taskId);
          headers.set("X-Thunderbird-Message-Id", docId.startsWith("<") ? docId : "<" + docId + ">");

          const uploadResp = await fetch(`${base}/task/evidence`, {
            method: "POST", headers, body: blob
          });
          if (uploadResp.ok) {
            uploadedCount++;
            debugLog(`[ThunderRAG] taskEvidence: uploaded ${docId} for task ${taskId}`);
          } else {
            debugWarn(`[ThunderRAG] taskEvidence: POST ${uploadResp.status} for ${docId}`);
          }
        } catch (e) {
          debugWarn(`[ThunderRAG] taskEvidence: error uploading ${docId}: ${e}`);
        }
      }

      // Signal that we've attempted all uploads for this task
      if (uploadedCount > 0) {
        try {
          await fetch(`${base}/task/evidence_done`, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ task_id: taskId })
          });
          debugLog(`[ThunderRAG] taskEvidence: signaled evidence_done for task ${taskId} (${uploadedCount}/${docIds.length})`);
          notifyTasksChanged();
        } catch (e) {
          debugWarn(`[ThunderRAG] taskEvidence: evidence_done error for ${taskId}: ${e}`);
        }
      }
    }
  } catch (e) {
    // Server may not be running — silently ignore connection errors
    if (!String(e).includes("NetworkError") && !String(e).includes("Failed to fetch")) {
      debugWarn(`[ThunderRAG] taskEvidence poll error: ${e}`);
    }
  } finally {
    taskEvidenceProcessing = false;
  }
}

function startTaskEvidencePoller() {
  if (taskEvidenceInterval) return;
  // Poll every 15 seconds — lightweight when queue is empty (single GET).
  taskEvidenceInterval = setInterval(processTaskEvidenceQueue, 15000);
  setTimeout(processTaskEvidenceQueue, 5000);
}

function stopTaskEvidencePoller() {
  if (taskEvidenceInterval) {
    clearInterval(taskEvidenceInterval);
    taskEvidenceInterval = null;
  }
}

/*
  OCaml server base URL — single source of truth is browser.storage.local.
  Configurable via the add-on options page (ui/options.html).
*/
const DEFAULT_SERVER_BASE = "http://localhost:8080";

async function getServerBase() {
  try {
    const data = await browser.storage.local.get("ragServerBase");
    const url = (data.ragServerBase || "").trim();
    return url || DEFAULT_SERVER_BASE;
  } catch (_e) {
    return DEFAULT_SERVER_BASE;
  }
}

// whoami is always read from settings.json on the server side.
// The TB add-on does not need to know or send it.

/* Remote logging: POST plain-text messages to the OCaml server's
   /debug/stdout or /debug/stderr endpoints so they appear in the
   server's terminal instead of the hard-to-reach TB debug console. */
async function _debugPost(path, args) {
  try {
    const base = await getServerBase();
    const msg = args.map(a => typeof a === "string" ? a : JSON.stringify(a, null, 2)).join(" ");
    fetch(`${base}${path}`, { method: "POST", body: msg }).catch(() => {});
  } catch (_e) { /* ignore */ }
}
function debugLog(...args)  { console.log(...args);  _debugPost("/debug/stdout", args); }
function debugWarn(...args) { console.warn(...args); _debugPost("/debug/stderr", args); }

/*
  Context menu items for the message list pane.

  - "Ingest selected emails": sends selected messages through the same
    decryption-aware pipeline as the filter action, then POSTs to /ingest.
  - "Show ingested data": queries /admin/ingested_detail for a single
    selected message and displays the result in a detail viewer tab.
*/
browser.menus.create({
  id: "thunderrag-ingest-selected",
  title: "Ingest selected emails",
  contexts: ["message_list"],
});

browser.menus.create({
  id: "thunderrag-deingest",
  title: "De-ingest selected emails",
  contexts: ["message_list"],
});

browser.menus.create({
  id: "thunderrag-show-ingested",
  title: "Show ingested data",
  contexts: ["message_list"],
});

browser.menus.create({
  id: "thunderrag-mark-processed",
  title: "Mark as processed",
  contexts: ["message_list"],
});

browser.menus.create({
  id: "thunderrag-mark-unprocessed",
  title: "Mark as unprocessed",
  contexts: ["message_list"],
});

browser.menus.create({
  id: "thunderrag-show-tasks",
  title: "Show tasks",
  contexts: ["message_list"],
});

browser.menus.create({
  id: "thunderrag-recompute-tasks",
  title: "Recompute tasks",
  contexts: ["message_list"],
});


browser.menus.onShown.addListener(async (info) => {
  if (!info.contexts.includes("message_list")) return;
  try {
    const tabs = await browser.mailTabs.query({ active: true, currentWindow: true });
    if (!tabs.length) return;
    const selected = await browser.mailTabs.getSelectedMessages(tabs[0].id);
    const msgs = selected?.messages || [];
    const multi = msgs.length > 1;

    if (multi) {
      // Multiple selection: show all items
      await Promise.all([
        browser.menus.update("thunderrag-ingest-selected", { visible: true }),
        browser.menus.update("thunderrag-deingest", { visible: true }),
        browser.menus.update("thunderrag-show-ingested", { visible: true }),
        browser.menus.update("thunderrag-mark-processed", { visible: true }),
        browser.menus.update("thunderrag-mark-unprocessed", { visible: true }),
        browser.menus.update("thunderrag-show-tasks", { visible: true }),
        browser.menus.update("thunderrag-recompute-tasks", { visible: true }),
      ]);
    } else if (msgs.length === 1) {
      const mid = msgs[0].headerMessageId || "";
      const status = ingestStatusCache.get(mid);
      const isIngested = status?.ingested || false;
      const isProcessed = status?.processed || false;

      // Not ingested: only show Ingest
      // Ingested, not processed: show De-ingest, Show, Mark processed
      // Ingested, processed: show De-ingest, Show, Mark unprocessed
      await Promise.all([
        browser.menus.update("thunderrag-ingest-selected", { visible: !isIngested }),
        browser.menus.update("thunderrag-deingest", { visible: isIngested }),
        browser.menus.update("thunderrag-show-ingested", { visible: isIngested }),
        browser.menus.update("thunderrag-mark-processed", { visible: isIngested && !isProcessed }),
        browser.menus.update("thunderrag-mark-unprocessed", { visible: isIngested && isProcessed }),
        browser.menus.update("thunderrag-show-tasks", { visible: true }),
        browser.menus.update("thunderrag-recompute-tasks", { visible: isIngested }),
      ]);
    }
    browser.menus.refresh();
  } catch (_e) {
    // Ignore — don't break the menu
  }
});

browser.menus.onClicked.addListener(async (info) => {
  try {
    if (info.menuItemId === "thunderrag-ingest-selected") {
      await handleIngestSelected();
    } else if (info.menuItemId === "thunderrag-show-ingested") {
      await handleShowIngested();
    } else if (info.menuItemId === "thunderrag-deingest") {
      await handleDeingest();
    } else if (info.menuItemId === "thunderrag-mark-processed") {
      await handleMarkProcessed(true);
    } else if (info.menuItemId === "thunderrag-mark-unprocessed") {
      await handleMarkProcessed(false);
    } else if (info.menuItemId === "thunderrag-show-tasks") {
      await handleShowTasks();
    } else if (info.menuItemId === "thunderrag-recompute-tasks") {
      await handleRecomputeTasks();
    }
  } catch (e) {
    console.error(`[ThunderRAG] menu handler error: ${e}`);
  }
});

async function handleShowTasks() {
  const tabs = await browser.mailTabs.query({ active: true, currentWindow: true });
  if (!tabs.length) return;
  let page = await browser.mailTabs.getSelectedMessages(tabs[0].id);
  if (!page?.messages?.length) return;
  const allMessages = [...page.messages];
  while (page.id) {
    page = await browser.messages.continueList(page.id);
    if (page?.messages?.length) allMessages.push(...page.messages);
  }
  const ids = allMessages
    .map(m => m.headerMessageId || "")
    .filter(Boolean)
    .map(id => id.startsWith("<") ? id : `<${id}>`);
  if (!ids.length) return;
  openTasksTab(ids);
}

async function handleIngestSelected() {
  const tabs = await browser.mailTabs.query({ active: true, currentWindow: true });
  if (!tabs.length) return;
  let page = await browser.mailTabs.getSelectedMessages(tabs[0].id);
  if (!page?.messages?.length) return;

  // Collect all pages (getSelectedMessages returns max 100 per page).
  const allMessages = [...page.messages];
  while (page.id) {
    page = await browser.messages.continueList(page.id);
    if (page?.messages?.length) allMessages.push(...page.messages);
  }

  const serverBase = await getServerBase();
  const endpoint = `${serverBase}/ingest`;
  debugLog(`[ingestSelected] endpoint=${endpoint} count=${allMessages.length}`);
  let ok = 0, fail = 0;

  for (const msg of allMessages) {
    try {
      const headerMessageId = msg.headerMessageId || "";
      if (!headerMessageId) { fail++; continue; }
      const mid = headerMessageId.startsWith("<") ? headerMessageId : `<${headerMessageId}>`;

      const rfc822 = await getDecryptedRfc822ForIngest(msg.id, headerMessageId);
      const bytes = new TextEncoder().encode(rfc822);
      const blob = new Blob([bytes], { type: "message/rfc822" });
      const headers = new Headers();
      headers.set("Content-Type", "message/rfc822");
      headers.set("X-Thunderbird-Message-Id", mid);

      const resp = await fetch(endpoint, { method: "POST", headers, body: blob });
      const respText = await resp.text();
      debugLog(`[ingestSelected] ${mid} -> ${resp.status} ${respText.slice(0, 200)}`);
      if (resp.ok) { ok++; } else { fail++; }
    } catch (e) {
      debugWarn(`[ingestSelected] failed for ${msg.headerMessageId}: ${e}`);
      fail++;
    }
  }

  debugLog(`[ingestSelected] done: ${ok} ok, ${fail} failed out of ${allMessages.length}`);

  // Refresh the ingestion status cache for the affected messages.
  refreshIngestStatusForFolder();
}

async function handleRecomputeTasks() {
  const tabs = await browser.mailTabs.query({ active: true, currentWindow: true });
  if (!tabs.length) return;
  let page = await browser.mailTabs.getSelectedMessages(tabs[0].id);
  if (!page?.messages?.length) return;

  const allMessages = [...page.messages];
  while (page.id) {
    page = await browser.messages.continueList(page.id);
    if (page?.messages?.length) allMessages.push(...page.messages);
  }

  const serverBase = await getServerBase();
  let ok = 0, fail = 0;

  for (const msg of allMessages) {
    try {
      const headerMessageId = msg.headerMessageId || "";
      if (!headerMessageId) { fail++; continue; }
      const mid = headerMessageId.startsWith("<") ? headerMessageId : `<${headerMessageId}>`;

      const rfc822 = await getDecryptedRfc822ForIngest(msg.id, headerMessageId);
      const resp = await fetch(`${serverBase}/email/recompute_tasks`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ doc_id: mid, raw: rfc822 }),
      });
      const respText = await resp.text();
      debugLog(`[recomputeTasks] ${mid} -> ${resp.status} ${respText.slice(0, 200)}`);
      if (resp.ok) { ok++; } else { fail++; }
    } catch (e) {
      debugWarn(`[recomputeTasks] failed for ${msg.headerMessageId}: ${e}`);
      fail++;
    }
  }

  debugLog(`[recomputeTasks] done: ${ok} ok, ${fail} failed out of ${allMessages.length}`);
  refreshIngestStatusForFolder();
  if (ok > 0) notifyTasksChanged();
}

async function handleDeingest() {
  const tabs = await browser.mailTabs.query({ active: true, currentWindow: true });
  if (!tabs.length) return;
  let page = await browser.mailTabs.getSelectedMessages(tabs[0].id);
  if (!page?.messages?.length) return;

  const allMessages = [...page.messages];
  while (page.id) {
    page = await browser.messages.continueList(page.id);
    if (page?.messages?.length) allMessages.push(...page.messages);
  }

  let ok = 0, fail = 0;
  for (const msg of allMessages) {
    try {
      const headerMessageId = msg.headerMessageId || "";
      if (!headerMessageId) { fail++; continue; }
      const mid = headerMessageId.startsWith("<") ? headerMessageId : `<${headerMessageId}>`;

      const serverBase = await getServerBase();
      const resp = await fetch(`${serverBase}/admin/delete`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ id: mid }),
      });
      if (resp.ok) { ok++; } else { fail++; }
    } catch (e) {
      console.warn(`[ThunderRAG] de-ingest: failed for ${msg.headerMessageId}: ${e}`);
      fail++;
    }
  }

  console.log(`[ThunderRAG] de-ingest: ${ok} ok, ${fail} failed out of ${allMessages.length}`);
  refreshIngestStatusForFolder();
  if (ok > 0) notifyTasksChanged();
}

async function handleMarkProcessed(processed) {
  const tabs = await browser.mailTabs.query({ active: true, currentWindow: true });
  if (!tabs.length) return;
  let page = await browser.mailTabs.getSelectedMessages(tabs[0].id);
  if (!page?.messages?.length) return;

  const allMessages = [...page.messages];
  while (page.id) {
    page = await browser.messages.continueList(page.id);
    if (page?.messages?.length) allMessages.push(...page.messages);
  }

  const serverBase = await getServerBase();
  const path = processed ? "/admin/mark_processed" : "/admin/mark_unprocessed";
  let ok = 0, fail = 0;

  for (const msg of allMessages) {
    try {
      const headerMessageId = msg.headerMessageId || "";
      if (!headerMessageId) { fail++; continue; }
      const mid = headerMessageId.startsWith("<") ? headerMessageId : `<${headerMessageId}>`;

      const resp = await fetch(`${serverBase}${path}`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ id: mid }),
      });
      if (resp.ok) { ok++; } else { fail++; }
    } catch (e) {
      console.warn(`[ThunderRAG] mark ${processed ? "processed" : "unprocessed"}: failed for ${msg.headerMessageId}: ${e}`);
      fail++;
    }
  }

  const label = processed ? "processed" : "unprocessed";
  console.log(`[ThunderRAG] mark ${label}: ${ok} ok, ${fail} failed out of ${allMessages.length}`);
  refreshIngestStatusForFolder();
}

async function handleShowIngested() {
  const tabs = await browser.mailTabs.query({ active: true, currentWindow: true });
  if (!tabs.length) return;
  const selected = await browser.mailTabs.getSelectedMessages(tabs[0].id);
  if (!selected?.messages?.length) return;

  const serverBase = await getServerBase();
  // Collect selected messages with basic TB metadata (for non-ingested display).
  const msgs = selected.messages
    .filter(m => m.headerMessageId)
    .map(m => ({
      id: m.headerMessageId,
      from: m.author || "",
      subject: m.subject || "",
      date: m.date ? new Date(m.date).toISOString() : "",
    }));
  if (!msgs.length) return;

  const url = browser.runtime.getURL("ui/ingested-detail.html")
    + `?msgs=${encodeURIComponent(JSON.stringify(msgs))}&endpoint=${encodeURIComponent(serverBase)}`;
  browser.tabs.create({ url });
}

/*
  Ingestion status cache and folder polling.

  The background script periodically queries the OCaml server for which
  messages in the current folder have been ingested.  Results are cached
  and pushed to the experiment API so the custom column handler can read
  them synchronously.
*/
const ingestStatusCache = new Map();   // headerMessageId → { ingested: bool, processed: bool, partial: bool, trigger_active: bool }
let currentFolderUri = null;
let ingestStatusPollInterval = null;

async function refreshIngestStatusForFolder() {
  try {
    const tabs = await browser.mailTabs.query({ active: true, currentWindow: true });
    if (!tabs.length) return;
    const tab = tabs[0];
    const folder = tab.displayedFolder;
    if (!folder) return;

    // Collect all message IDs in the folder (paginated).
    const ids = [];
    let page = await browser.messages.list(folder.id || folder);
    while (page) {
      for (const msg of page.messages) {
        if (msg.headerMessageId) ids.push(msg.headerMessageId);
      }
      if (page.id) {
        page = await browser.messages.continueList(page.id);
      } else {
        break;
      }
    }

    if (!ids.length) return;

    // Batch query (chunks of 500 to avoid huge requests).
    const chunkSize = 500;
    const ingested = new Set();
    const processed = new Set();
    const partial = new Set();
    const triggerActive = new Set();
    const replyByMap = new Map();
    for (let i = 0; i < ids.length; i += chunkSize) {
      const batch = ids.slice(i, i + chunkSize);
      try {
        const serverBase = await getServerBase();
        const resp = await fetch(`${serverBase}/admin/ingested_status`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ ids: batch }),
        });
        if (resp.ok) {
          const data = await resp.json();
          if (Array.isArray(data.ingested)) {
            for (const id of data.ingested) ingested.add(id);
          }
          if (Array.isArray(data.processed)) {
            for (const id of data.processed) processed.add(id);
          }
          if (Array.isArray(data.partial)) {
            for (const id of data.partial) partial.add(id);
          }
          if (Array.isArray(data.trigger_active)) {
            for (const id of data.trigger_active) triggerActive.add(id);
          }
          if (data.reply_by && typeof data.reply_by === "object") {
            for (const [id, dt] of Object.entries(data.reply_by)) {
              if (dt) replyByMap.set(id, String(dt));
            }
          }
        }
      } catch (_e) {
        // Server may be down; leave cache as-is for this batch.
      }
    }

    // Update cache.
    const greenCount = [...ingested].length;
    for (const id of ids) {
      ingestStatusCache.set(id, { ingested: ingested.has(id), processed: processed.has(id), partial: partial.has(id), trigger_active: triggerActive.has(id), reply_by: replyByMap.get(id) || "" });
    }
    console.log(`[ThunderRAG] status poll: ${ids.length} ids checked, ${greenCount} ingested`);

    // Push to experiment API for the column handler.
    if (browser.ragFilterAction?.updateIngestStatusCache) {
      const obj = {};
      for (const [k, v] of ingestStatusCache) { obj[k] = { ingested: v.ingested, processed: v.processed, partial: v.partial || false, trigger_active: v.trigger_active || false, reply_by: v.reply_by || "" }; }
      try {
        await browser.ragFilterAction.updateIngestStatusCache(JSON.stringify(obj));
      } catch (_e) {
        // Experiment API may not be ready yet.
      }
    }
  } catch (e) {
    // Silently ignore — server may be offline or folder not ready.
    if (!String(e).includes("Trash")) {
      console.warn(`[ThunderRAG] status poll error: ${e}`);
    }
  }
}

function startIngestStatusPoller() {
  if (ingestStatusPollInterval) return;
  // Poll every 15 seconds.
  ingestStatusPollInterval = setInterval(refreshIngestStatusForFolder, 15000);
  // Initial poll after 3 seconds.
  setTimeout(refreshIngestStatusForFolder, 3000);
}

/*
  Proactive cleanup: automatically de-ingest emails that are permanently
  deleted or moved to Trash / Junk.
*/
function proactiveDelete(headerMessageId, reason) {
  if (!headerMessageId) return;
  getServerBase().then(serverBase => {
    fetch(`${serverBase}/admin/delete`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ id: headerMessageId }),
    })
      .then(() => console.log(`[ThunderRAG] proactive delete (${reason}): ${headerMessageId}`))
      .catch(() => {});
  }).catch(() => {});
}

browser.messages.onDeleted.addListener((messages) => {
  for (const msg of (messages?.messages || [])) {
    proactiveDelete(msg.headerMessageId, "permanently deleted");
  }
});

browser.messages.onMoved.addListener((_originalMessages, movedMessages) => {
  for (const msg of (movedMessages?.messages || [])) {
    const ft = msg.folder?.type || "";
    if (ft === "trash" || ft === "junk") {
      proactiveDelete(msg.headerMessageId, `moved to ${ft}`);
    } else if (ft === "archives") {
      // Auto-mark as processed when archived
      const hmid = msg.headerMessageId || "";
      if (!hmid) continue;
      const mid = hmid.startsWith("<") ? hmid : `<${hmid}>`;
      getServerBase().then(base => {
        fetch(`${base}/admin/mark_processed`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ id: mid }),
        }).then(resp => {
          if (resp.ok) {
            console.log(`[ThunderRAG] auto-marked processed (archived): ${hmid}`);
            notifyTasksChanged();
          }
        }).catch(e => console.warn(`[ThunderRAG] auto-mark processed failed for ${hmid}:`, e));
      });
    }
  }
});

startup().then(() => {
  startIngestQueuePoller();
  startTaskEvidencePoller();
  startIngestStatusPoller();
});
