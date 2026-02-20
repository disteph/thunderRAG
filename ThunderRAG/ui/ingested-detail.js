const params = new URLSearchParams(location.search);

/* Parse message list: new multi-msg format, or legacy single-id. */
let msgList = []; // Array of { id, from?, subject?, date? }
const msgsParam = params.get("msgs");
const singleId = params.get("id");
if (msgsParam) {
  try { msgList = JSON.parse(msgsParam); } catch (_) {}
} else if (singleId) {
  msgList = [{ id: singleId }];
}

/* Read the server URL from the URL param (legacy) or browser.storage.local (preferred). */
async function getEndpoint() {
  const fromParam = (params.get("endpoint") || "").trim();
  if (fromParam) return fromParam;
  try {
    const data = await browser.storage.local.get("ragServerBase");
    return (data.ragServerBase || "").trim() || "http://localhost:8080";
  } catch (_e) {
    return "http://localhost:8080";
  }
}

/* Remote debug logging — mirrors to OCaml server stdout. */
async function debugLog(...args) {
  console.log(...args);
  try {
    const base = await getEndpoint();
    const msg = args.map(a => typeof a === "string" ? a : JSON.stringify(a, null, 2)).join(" ");
    fetch(`${base}/debug/stdout`, { method: "POST", body: msg }).catch(() => {});
  } catch (_e) { /* ignore */ }
}

function esc(s) {
  const d = document.createElement("div");
  d.textContent = String(s);
  return d.innerHTML;
}

/* Render the metadata tiles for a single email.  Returns HTML string.
   Does NOT include the body-text card (caller decides based on isSingle). */
function renderMetadataHtml(data, entry) {
  const msgId = entry.id;

  // Not ingested at all
  if (!data || (!data.embed_model && !data.metadata && !data.ingested)) {
    let h = "";
    if (entry.from || entry.subject) {
      h += `<div class="card"><div class="label">Email</div><div class="meta-grid">`;
      if (entry.from) h += `<div class="meta-key">from</div><div>${esc(entry.from)}</div>`;
      if (entry.subject) h += `<div class="meta-key">subject</div><div>${esc(entry.subject)}</div>`;
      if (entry.date) h += `<div class="meta-key">date</div><div>${esc(entry.date)}</div>`;
      h += `<div class="meta-key">message_id</div><div>${esc(msgId)}</div>`;
      h += `</div></div>`;
    }
    h += `<div class="card"><div class="label">Status</div><div class="value not-ingested">Not ingested</div></div>`;
    return h;
  }

  if (data.detail === null && data.ingested === false) {
    let h = "";
    if (entry.from || entry.subject) {
      h += `<div class="card"><div class="label">Email</div><div class="meta-grid">`;
      if (entry.from) h += `<div class="meta-key">from</div><div>${esc(entry.from)}</div>`;
      if (entry.subject) h += `<div class="meta-key">subject</div><div>${esc(entry.subject)}</div>`;
      if (entry.date) h += `<div class="meta-key">date</div><div>${esc(entry.date)}</div>`;
      h += `<div class="meta-key">message_id</div><div>${esc(msgId)}</div>`;
      h += `</div></div>`;
    }
    h += `<div class="card"><div class="label">Status</div><div class="value not-ingested">Not ingested</div></div>`;
    return h;
  }

  if (data.detail === null && data.ingested === true) {
    return `<div class="card"><div class="label">Status</div>
      <div class="value">Ingested (detail not available — ingested before detail tracking was enabled)</div></div>`;
  }

  const md = data.metadata;
  let html = "";

  // ── Tile 1: Metadata (basic email headers) ──
  if (md && typeof md === "object") {
    html += `<div class="card"><div class="label">Metadata</div><div class="meta-grid">`;
    for (const key of ["from", "to", "cc", "bcc", "subject", "date", "message_id"]) {
      const val = md[key];
      if (val && typeof val === "string" && val.trim()) {
        html += `<div class="meta-key">${esc(key)}</div><div>${esc(val)}</div>`;
      }
    }
    if (Array.isArray(md.attachments) && md.attachments.length) {
      html += `<div class="meta-key">attachments</div><div>${esc(md.attachments.join(", "))}</div>`;
    }
    html += `</div></div>`;
  }

  // ── Tile 2: Status (ingestion info + triage + processed — all in one card) ──
  html += `<div class="card"><div class="label">Status</div><div class="meta-grid">`;
  if (md && md.ingested_at) {
    html += `<div class="meta-key">ingested at</div><div>${esc(md.ingested_at)}</div>`;
  }
  if (data.embed_model) {
    html += `<div class="meta-key">embedding model</div><div>${esc(data.embed_model)}</div>`;
  }
  if (data.triage_model) {
    html += `<div class="meta-key">triage model</div><div>${esc(data.triage_model)}</div>`;
  }
  if (md) {
    if (typeof md.action_score === "number") {
      html += `<div class="meta-key">action score</div><div>${md.action_score}/100</div>`;
    }
    if (typeof md.importance_score === "number") {
      html += `<div class="meta-key">importance score</div><div>${md.importance_score}/100</div>`;
    }
    if (md.reply_by && typeof md.reply_by === "string" && md.reply_by !== "none") {
      html += `<div class="meta-key">reply by</div><div>${esc(md.reply_by)}</div>`;
    }
    if (typeof md.processed === "boolean") {
      const processedText = md.processed
        ? (md.processed_at ? `Processed on ${esc(md.processed_at)}` : "Processed")
        : "Not processed";
      html += `<div class="meta-key">processed</div><div>${processedText}</div>`;
    }
  }
  html += `</div></div>`;

  // ── Catch-all for unknown metadata keys ──
  if (md && typeof md === "object") {
    const knownKeys = new Set(["from","to","cc","bcc","subject","date","message_id","attachments","processed","action_score","importance_score","reply_by","ingested_at","processed_at"]);
    const extraKeys = Object.keys(md).filter(k => !knownKeys.has(k));
    if (extraKeys.length) {
      html += `<div class="card"><div class="label">Other Metadata</div><div class="meta-grid">`;
      for (const k of extraKeys) {
        const v = md[k];
        const display = typeof v === "object" ? JSON.stringify(v) : String(v);
        html += `<div class="meta-key">${esc(k)}</div><div>${esc(display)}</div>`;
      }
      html += `</div></div>`;
    }
  }

  return html;
}

/* Fire progressive body-text extraction for a single email. */
function startBodyExtraction(msgId, endpoint) {
  (async () => {
    const statusEl = document.getElementById("body-status");
    const bodyTextEl = document.getElementById("body-text");
    const bodyValueEl = document.getElementById("body-value");
    if (!statusEl || !bodyTextEl || !bodyValueEl) return;
    try {
      // Phase 1: fast extraction (no LLM summarization)
      const raw = await browser.runtime.sendMessage({
        type: "extractBody",
        headerMessageId: msgId,
        endpoint,
        summarize: false,
      });
      if (raw && raw.body_text) {
        bodyValueEl.textContent = raw.body_text;
        bodyTextEl.style.display = "block";
        statusEl.textContent = "Re-computing with LLM summarization for quoted text and attachments…";
      }
      // Phase 2: full extraction with LLM summarization
      const full = await browser.runtime.sendMessage({
        type: "extractBody",
        headerMessageId: msgId,
        endpoint,
        summarize: true,
      });
      if (full && full.body_text) {
        bodyValueEl.textContent = full.body_text;
        bodyTextEl.style.display = "block";
        statusEl.textContent = "";
        const labelEl = bodyTextEl.querySelector(".label");
        const hasQuoteSummary = full.body_text.includes("QUOTED CONTEXT (older, summarized):");
        const hasAttSummary = full.body_text.includes("ATTACHMENTS (summaries):");
        if (hasQuoteSummary || hasAttSummary) {
          const modelSuffix = full.summarize_model ? ` using model ${full.summarize_model}` : "";
          if (labelEl) labelEl.textContent = `Content (with LLM summarization${modelSuffix})`;
        } else {
          if (labelEl) labelEl.textContent = "Content";
        }
      } else {
        statusEl.textContent = "(LLM summarization returned no result; showing raw)";
      }
    } catch (err) {
      statusEl.textContent = `Error: ${err.message}`;
    }
  })();
}

async function load() {
  const loadingEl = document.getElementById("loading");
  const errorEl = document.getElementById("error");
  const contentEl = document.getElementById("content");

  if (!msgList.length) {
    loadingEl.style.display = "none";
    errorEl.textContent = "No message ID provided.";
    errorEl.style.display = "block";
    return;
  }

  const isSingle = msgList.length === 1;
  const endpoint = await getEndpoint();

  loadingEl.style.display = "none";
  contentEl.style.display = "block";

  for (let i = 0; i < msgList.length; i++) {
    const entry = msgList[i];
    const msgId = entry.id;
    let sectionHtml = "";

    // Section title for multi-email view
    if (!isSingle) {
      const title = entry.subject
        ? `${esc(entry.subject)} — ${esc(entry.from || entry.id)}`
        : esc(entry.id);
      sectionHtml += `<div class="email-section-title">${i + 1}. ${title}</div>`;
    }

    try {
      const data = await browser.runtime.sendMessage({
        type: "fetchIngestedDetail",
        id: msgId,
        endpoint,
      });
      debugLog("[ingested-detail] raw server response:", data);

      sectionHtml += renderMetadataHtml(data, entry);

      // Body text card — only for single-email view of ingested messages
      if (isSingle && data && (data.embed_model || data.metadata)) {
        sectionHtml += `<div class="card" id="body-card">
          <div id="body-status" style="font-size:12px; color:var(--label);">Extracting body…</div>
          <div id="body-text" style="display:none; margin-top:8px;">
            <div class="label">Recomputing content from Thunderbird…</div>
            <div class="value" id="body-value"></div>
          </div>
        </div>`;
      }
    } catch (e) {
      sectionHtml += `<div class="card"><div class="label">Error</div><div class="value">${esc(e.message)}</div></div>`;
    }

    const section = document.createElement("div");
    if (!isSingle) section.className = "email-section";
    section.innerHTML = sectionHtml;
    contentEl.appendChild(section);
  }

  // Start body extraction for single-email view
  if (isSingle && document.getElementById("body-card")) {
    startBodyExtraction(msgList[0].id, endpoint);
  }
}

load();
