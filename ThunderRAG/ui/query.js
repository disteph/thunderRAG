/*
  ThunderRAG query UI

  This page implements a 2-phase RAG query flow:
  1) POST /query (OCaml server)
     - Server runs retrieval only (vector search via PostgreSQL/pgvector).
     - Response includes status=need_messages, request_id, message_ids, and source metadata.
  2) For each message_id:
     - UI asks background.js to fetch raw RFC822 via browser.messages.getRaw.
     - UI uploads evidence to OCaml server via POST /query/evidence with headers:
       - X-RAG-Request-Id
       - X-Thunderbird-Message-Id
  3) POST /query/complete
     - Server builds final prompt (includes SOURCES INDEX + evidence), calls Ollama chat,
       updates session state, and returns answer + metadata-only sources.

  UI responsibilities
  - Render the Sources block above the final answer.
  - Show progress ("Fetching emails X/Y") while evidence is being uploaded.
  - Show typing dots while waiting for /query/complete.
  - Convert citations like [Source N] into clickable links that open the corresponding email.
*/

/* Short alias for getElementById, used throughout the UI. */
function $(id) {
  return document.getElementById(id);
}

/*
  Read the OCaml server base URL from browser.storage.local (set in add-on options).
  Falls back to http://localhost:8080 if not configured.
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

/* Format an email date string into a locale-aware short format for source tiles. */
function formatEmailDate(s) {
  const raw = String(s || "").trim();
  if (!raw) return "";
  const d = new Date(raw);
  if (Number.isNaN(d.getTime())) return raw;
  try {
    return new Intl.DateTimeFormat(undefined, {
      year: "numeric",
      month: "short",
      day: "2-digit",
      hour: "2-digit",
      minute: "2-digit",
    }).format(d);
  } catch (_e) {
    return d.toLocaleString();
  }
}

async function fetchJson(url, body) {
  /*
    JSON POST helper.
    The OCaml server consistently returns JSON (or an error status + text).
  */
  const resp = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });

  const text = await resp.text();
  let parsed = null;
  try {
    parsed = text ? JSON.parse(text) : null;
  } catch (e) {
    parsed = null;
  }

  if (!resp.ok) {
    const detail = parsed ? JSON.stringify(parsed) : text;
    throw new Error(`HTTP ${resp.status}: ${detail}`);
  }

  return parsed;
}

function clearError() {
  $("error").textContent = "";
}

function scrollChatToBottom() {
  const chat = $("chat");
  chat.scrollTop = chat.scrollHeight;
}

function appendMessage(role, text) {
  const chat = $("chat");

  const msg = document.createElement("div");
  msg.className = role === "user" ? "msg msg-user" : "msg msg-assistant";

  const bubble = document.createElement("div");
  bubble.className = "bubble";
  bubble.textContent = text;

  msg.appendChild(bubble);
  chat.appendChild(msg);
  scrollChatToBottom();

  return { msg, bubble };
}

function renderSourcesInto(container, sources) {
  /*
    Render a set of lightweight source tiles.
    Each tile is clickable (opens the message), but intentionally does NOT show
    message bodies or attachment contents.
  */
  container.innerHTML = "";

  if (!Array.isArray(sources) || sources.length === 0) {
    const empty = document.createElement("div");
    empty.className = "muted";
    empty.textContent = "(no sources)";
    container.appendChild(empty);
    return;
  }

  for (const s of sources) {
    const docId = s?.doc_id || "";
    const md = s?.metadata || {};

    const from = String(md?.from || "").trim();
    const subject = String(md?.subject || "").trim();
    const date = formatEmailDate(md?.date);

    const card = document.createElement("div");
    card.className = s?.in_prompt === false ? "source not-in-prompt" : "source";
    card.tabIndex = 0;

    const open = async () => {
      if (!docId) return;
      try {
        await browser.runtime.sendMessage({
          type: "openMessageByHeaderMessageId",
          headerMessageId: docId,
        });
      } catch (e) {
        $("error").textContent = String(e && e.message ? e.message : e);
      }
    };

    if (docId) {
      card.addEventListener("click", open);
      card.addEventListener("keydown", (e) => {
        if (e.key === "Enter" || e.key === " ") {
          e.preventDefault();
          open();
        }
      });
    }

    const header = document.createElement("div");
    header.className = "source-header";

    const left = document.createElement("div");
    const title = document.createElement("div");
    title.className = "source-title";
    const label = s?._label || "";
    title.textContent = label
      ? `[${label}] ${subject || "(no subject)"}`
      : subject || "(no subject)";
    left.appendChild(title);

    const right = document.createElement("div");
    right.className = "source-header-right";
    const dateSpan = document.createElement("span");
    dateSpan.className = "muted";
    dateSpan.textContent = date;
    right.appendChild(dateSpan);

    if (docId) {
      const tankBtn = document.createElement("span");
      tankBtn.className = "source-tank-icon";
      tankBtn.textContent = "\uD83D\uDEE2\uFE0F";
      tankBtn.title = "Show ingested data";
      tankBtn.addEventListener("click", async (e) => {
        e.stopPropagation();
        try {
          const serverBase = await getServerBase();
          const msgs = [{ id: docId, from, subject, date }];
          const url = browser.runtime.getURL("ui/ingested-detail.html")
            + `?msgs=${encodeURIComponent(JSON.stringify(msgs))}&endpoint=${encodeURIComponent(serverBase)}`;
          browser.tabs.create({ url });
        } catch (err) {
          $("error").textContent = String(err?.message || err);
        }
      });
      right.appendChild(tankBtn);
    }

    header.appendChild(left);
    header.appendChild(right);

    const to_ = String(md?.to || "").trim();
    const cc = String(md?.cc || "").trim();
    const score = s?.score;
    const actionScore = md?.action_score;
    const importanceScore = md?.importance_score;
    const replyBy = String(md?.reply_by || "").trim();
    const attachments = Array.isArray(md?.attachments) ? md.attachments : [];
    const rehydrated = s?.rehydrated === true;
    const bodyText = String(s?.text || "").trim();

    const meta = document.createElement("div");
    meta.className = "source-meta";
    const metaLines = [];
    if (from) metaLines.push(`From: ${from}`);
    if (to_) metaLines.push(`To: ${to_}`);
    if (cc) metaLines.push(`Cc: ${cc}`);
    const folder = String(s?.folder || "").trim();
    if (folder) metaLines.push(`Folder: ${folder}`);
    if (typeof score === "number") metaLines.push(`Score: ${score.toFixed(4)}`);
    if (typeof actionScore === "number" || typeof importanceScore === "number") {
      const parts = [];
      if (typeof actionScore === "number") parts.push(`action=${actionScore}/100`);
      if (typeof importanceScore === "number") parts.push(`importance=${importanceScore}/100`);
      metaLines.push(parts.join("  "));
    }
    const replyByDisplay = (replyBy && replyBy !== "none") ? replyBy : "None";
    metaLines.push(`Reply by: ${replyByDisplay}`);
    const isProcessed = md?.processed === true;
    metaLines.push(isProcessed ? "✔ Processed" : "✗ Not processed");
    if (attachments.length > 0) metaLines.push(`Attachments: ${attachments.join(", ")}`);
    meta.textContent = metaLines.join("\n");

    card.appendChild(header);
    if (meta.textContent.trim()) {
      card.appendChild(meta);
    }

    if (rehydrated && bodyText) {
      const bodyToggle = document.createElement("details");
      bodyToggle.className = "source-body-toggle";
      const bodySummary = document.createElement("summary");
      bodySummary.textContent = "Body";
      bodyToggle.appendChild(bodySummary);
      const bodyContent = document.createElement("div");
      bodyContent.className = "source-body-content";
      bodyContent.textContent = bodyText;
      bodyToggle.appendChild(bodyContent);
      bodyToggle.addEventListener("click", (e) => e.stopPropagation());
      card.appendChild(bodyToggle);
    }

    container.appendChild(card);
  }
}

function setAssistantMessage(bubble, answer, sources, retrievalInfo) {
  /*
    Renders a single assistant "bubble" with three pieces:
    - A debug-only collapsible triangle (no label) that expands the full sources list.
      retrievalInfo = { sql, queries } is shown inline on the same line as the triangle.
    - The final answer text, with citations post-processed into clickable links.
    - Below the answer: tiles for only the sources actually cited as [Email N].

    bubble.__rag is used to keep references to the progress bar + answer element for updates.
  */
  const retrievalSql = retrievalInfo?.sql || "";
  const retrievalQueries = Array.isArray(retrievalInfo?.queries) ? retrievalInfo.queries : [];
  bubble.textContent = "";

  const meta = document.createElement("div");
  meta.className = "assistant-meta";

  const summaryProgress = document.createElement("span");
  summaryProgress.className = "summary-progress";
  summaryProgress.style.display = "none";

  const progressLabel = document.createElement("span");
  progressLabel.textContent = "Fetching emails";

  const progress = document.createElement("progress");
  progress.max = 100;
  progress.value = 0;

  summaryProgress.appendChild(progressLabel);
  summaryProgress.appendChild(progress);
  meta.appendChild(summaryProgress);

  const details = document.createElement("details");
  const summary = document.createElement("summary");
  summary.textContent = "";
  details.appendChild(summary);

  if (retrievalQueries.length > 0 || retrievalSql) {
    /* -- query blocks: one per embedded query -- */
    if (retrievalQueries.length > 0) {
      for (const q of retrievalQueries) {
        const qBlock = document.createElement("div");
        qBlock.className = "retrieval-block retrieval-query";
        qBlock.textContent = `\u201c${q}\u201d`;
        details.appendChild(qBlock);
      }
    }

    /* -- parse SQL segments, deduplicate WHERE and ORDER BY -- */
    if (retrievalSql) {
      const segments = retrievalSql.split("|").map(s => s.trim()).filter(Boolean);
      const whereClauses = new Set();
      const orderClauses = new Set();
      for (const seg of segments) {
        const whereMatch = seg.match(/WHERE\s+(.+?)(?:\s+ORDER\s+BY\s|$)/i);
        const orderMatch = seg.match(/ORDER\s+BY\s+(.+?)(?:\s+LIMIT\s|$)/i);
        if (whereMatch) whereClauses.add(whereMatch[1].trim());
        if (orderMatch) orderClauses.add(orderMatch[1].trim());
      }
      for (const w of whereClauses) {
        const wBlock = document.createElement("div");
        wBlock.className = "retrieval-block retrieval-where";
        wBlock.textContent = `WHERE ${w}`;
        details.appendChild(wBlock);
      }
      for (const o of orderClauses) {
        const oBlock = document.createElement("div");
        oBlock.className = "retrieval-block retrieval-order";
        oBlock.textContent = `ORDER BY ${o}`;
        details.appendChild(oBlock);
      }
    }
  }

  const sourcesContainer = document.createElement("div");
  sourcesContainer.className = "sources";
  renderSourcesInto(sourcesContainer, sources || []);
  details.appendChild(sourcesContainer);

  const hasAnswer = String(answer || "").trim() !== "";
  if (hasAnswer) {
    meta.appendChild(details);
  }
  bubble.appendChild(meta);

  const answerEl = document.createElement("div");
  const srcs = Array.isArray(sources) ? sources : [];
  const text = String(answer || "");

  // Pass 1: collect unique cited original indices (0-based) in order of appearance.
  const citedOriginal = [];
  {
    const seen = new Set();
    const re = /\[Email\s+(\d+)\]/g;
    let m;
    while ((m = re.exec(text))) {
      const idx = parseInt(m[1], 10) - 1;
      if (idx >= 0 && idx < srcs.length && srcs[idx]?.doc_id && !seen.has(idx)) {
        seen.add(idx);
        citedOriginal.push(idx);
      }
    }
  }
  // Build renumber map: original 0-based index → new 1-based number.
  const renumber = new Map();
  citedOriginal.forEach((origIdx, i) => renumber.set(origIdx, i + 1));

  // Pass 2: render answer text with renumbered citations.
  {
    const re = /\[Email\s+(\d+)\]/g;
    let last = 0;
    let m;
    while ((m = re.exec(text))) {
      const start = m.index;
      const end = re.lastIndex;
      if (start > last) {
        answerEl.appendChild(document.createTextNode(text.slice(last, start)));
      }

      const origN = parseInt(m[1], 10);
      const idx = origN - 1;
      const newN = renumber.get(idx);

      if (newN !== undefined) {
        const docId = String(srcs[idx]?.doc_id || "");
        const a = document.createElement("a");
        a.href = "#";
        a.className = "citation";
        a.textContent = `[Email ${newN}]`;
        a.addEventListener("click", async (e) => {
          e.preventDefault();
          try {
            await browser.runtime.sendMessage({
              type: "openMessageByHeaderMessageId",
              headerMessageId: docId,
            });
          } catch (err) {
            $("error").textContent = String(err && err.message ? err.message : err);
          }
        });
        answerEl.appendChild(a);
      } else {
        answerEl.appendChild(document.createTextNode(m[0]));
      }

      last = end;
    }
    if (last < text.length) {
      answerEl.appendChild(document.createTextNode(text.slice(last)));
    }
  }
  bubble.appendChild(answerEl);

  // Render cited sources below the answer (always visible, no collapse), renumbered.
  if (citedOriginal.length > 0) {
    const citedContainer = document.createElement("div");
    citedContainer.className = "cited-sources";
    const citedWithLabels = citedOriginal.map((origIdx, i) => ({
      ...srcs[origIdx],
      _label: `Email ${i + 1}`,
    }));
    renderSourcesInto(citedContainer, citedWithLabels);
    bubble.appendChild(citedContainer);
  }

  bubble.__rag = {
    details,
    summaryProgress,
    progress,
    progressLabel,
    answerEl,
  };
}

function setSourcesProgress(bubble, current, total) {
  /*
    Show and update the inline progress bar above the answer area.
    Visible during evidence upload, hidden once complete.
  */
  const s = bubble && bubble.__rag;
  if (!s) return;
  const cur = Math.max(0, Number(current || 0));
  const tot = Math.max(0, Number(total || 0));
  if (!tot) {
    s.summaryProgress.style.display = "none";
    return;
  }
  s.summaryProgress.style.display = "";
  s.progress.value = Math.max(0, Math.min(100, Math.round((cur / tot) * 100)));
  s.progressLabel.textContent = `Fetching emails ${cur}/${tot}`;
}

function hideSourcesProgress(bubble) {
  const s = bubble && bubble.__rag;
  if (!s) return;
  s.summaryProgress.style.display = "none";
}

function setTypingDots(bubble, phaseText) {
  /*
    Replace the answer area with an animated typing indicator + phase label.
    phaseText is optional — shown next to the dots when provided.
    Works both before and after __rag is set up.
  */
  const target = (bubble && bubble.__rag) ? bubble.__rag.answerEl : bubble;
  if (!target) return;
  target.textContent = "";
  const t = document.createElement("span");
  t.className = "typing";
  t.appendChild(document.createElement("span")).className = "dot";
  t.appendChild(document.createElement("span")).className = "dot";
  t.appendChild(document.createElement("span")).className = "dot";
  const label = document.createElement("span");
  label.className = "typing-phase";
  label.textContent = phaseText || "";
  t.appendChild(label);
  target.appendChild(t);
}

function setTypingPhase(bubble, phaseText) {
  /*
    Update the phase label on an existing typing indicator without recreating it.
    Works both before and after __rag is set up.
  */
  const target = (bubble && bubble.__rag) ? bubble.__rag.answerEl : bubble;
  if (!target) return;
  const label = target.querySelector(".typing-phase");
  if (label) label.textContent = phaseText || "";
}

/* Guards against concurrent queries — only one query can be in flight at a time. */
let inFlight = false;

/* Get or create a persistent session ID stored in localStorage.
   The session ID ties together multi-turn conversation state on the OCaml server. */
function getSessionId() {
  const key = "rag.sessionId";
  let v = localStorage.getItem(key);
  if (v && String(v).trim()) return String(v);
  let fresh = "";
  try {
    fresh = crypto.randomUUID();
  } catch (_e) {
    fresh = "s_" + Math.random().toString(16).slice(2) + Date.now().toString(16);
  }
  localStorage.setItem(key, fresh);
  return fresh;
}

async function onAsk() {
  /*
    Main user action handler:
    - sends the question
    - orchestrates retrieval, evidence upload, and final completion
    - updates the UI to reflect progress and results
  */
  clearError();
  if (inFlight) return;

  const base = await getServerBase();

  const mode = "assistive";

  const question = ($("question").value || "").trim();
  const topK = parseInt($("topK").value || "8", 10);

  if (!question) {
    return;
  }

  $("question").value = "";
  appendMessage("user", question);
  const assistant = appendMessage("assistant", "");
  inFlight = true;
  $("askBtn").disabled = true;

  /* Poll /query/progress every 500ms to update the phase label.
     Defined outside try so catch/finally can call stopProgressPolling. */
  const session_id = getSessionId();
  let progressTimer = null;
  setTypingDots(assistant.bubble, "Building vector DB query\u2026");

  function startProgressPolling() {
    progressTimer = setInterval(async () => {
      try {
        const r = await fetch(`${base}/query/progress?session_id=${encodeURIComponent(session_id)}`);
        if (r.ok) {
          const d = await r.json();
          const phase = String(d?.phase || "");
          if (phase) setTypingPhase(assistant.bubble, phase + "\u2026");
        }
      } catch (_) { /* ignore polling errors */ }
    }, 500);
  }
  function stopProgressPolling() {
    if (progressTimer) { clearInterval(progressTimer); progressTimer = null; }
  }

  try {
    let user_name = "";
    try {
      const d = await browser.storage.local.get("ragWhoAmI");
      user_name = (d.ragWhoAmI || "").trim();
    } catch (_e) { /* ignore */ }

    const chatModel = ($("chatModel").value || "").trim();
    const summarizeModel = ($("summarizeModel").value || "").trim();
    const rewriteModel = ($("rewriteModel").value || "").trim();

    startProgressPolling();
    const res = await fetchJson(`${base}/query`, {
      session_id,
      question,
      top_k: topK,
      mode,
      user_name,
      rewrite_model: rewriteModel,
    });
    stopProgressPolling();

    const srcs = Array.isArray(res?.sources) ? res.sources : [];

    const status = String(res?.status || "");
    if (status === "need_messages" || status === "no_retrieval") {
      const requestId = String(res?.request_id || "");
      const messageIds = Array.isArray(res?.message_ids) ? res.message_ids : [];

      const retrievalInfo = {
        sql: String(res?.retrieval_sql || ""),
        queries: Array.isArray(res?.retrieval_queries) ? res.retrieval_queries : [],
      };
      setAssistantMessage(assistant.bubble, "", srcs, retrievalInfo);

      const serverWarnings = Array.isArray(res?.warnings) ? res.warnings : [];
      if (serverWarnings.length > 0) {
        const warnEl = document.createElement("div");
        warnEl.className = "retrieval-warning";
        warnEl.textContent = "\u26A0 " + serverWarnings.join(" | ");
        const rag = assistant.bubble.__rag;
        if (rag && rag.answerEl) {
          rag.answerEl.parentElement.insertBefore(warnEl, rag.answerEl);
        } else {
          assistant.bubble.prepend(warnEl);
        }
      }

      setTypingDots(assistant.bubble, "Validating emails\u2026");

      if (!requestId) {
        throw new Error("Server did not return request_id");
      }

      // Lazy validation: check which retrieved emails still exist in TB
      // and are not in Trash/Junk.  Stale entries are deleted from the
      // server DB so they won't pollute future queries.
      const allDocIds = srcs.map(s => String(s?.doc_id || "")).filter(Boolean);
      let validation = {};
      try {
        validation = await browser.runtime.sendMessage({
          type: "validateMessageIds",
          ids: allDocIds,
        }) || {};
      } catch (_) {}

      const staleIds = [];
      const folderByDocId = {};
      for (const [id, info] of Object.entries(validation)) {
        if (!info.exists || info.folderType === "trash" || info.folderType === "junk" || info.junk) {
          staleIds.push(id);
        } else {
          folderByDocId[id] = info.folder || "";
        }
      }

      // Delete stale entries from server DB
      if (staleIds.length > 0) {
        for (const id of staleIds) {
          try {
            await fetch(`${base}/admin/delete`, {
              method: "POST",
              headers: { "Content-Type": "application/json" },
              body: JSON.stringify({ id }),
            });
          } catch (_) {}
        }
      }

      // Attach folder info to sources for UI display; mark stale
      const staleSet = new Set(staleIds);
      for (const s of srcs) {
        const did = String(s?.doc_id || "");
        if (folderByDocId[did]) s.folder = folderByDocId[did];
        if (staleSet.has(did)) s.stale = true;
      }

      // Filter stale IDs from the evidence upload list
      const validMessageIds = messageIds.filter(id => !staleSet.has(id));

      setTypingDots(assistant.bubble, "Fetching emails\u2026");

      if (validMessageIds.length > 0) {

        async function postEvidence(headerMessageId, raw) {
          const enc = new TextEncoder();
          const bytes = enc.encode(String(raw || ""));
          const blob = new Blob([bytes], { type: "message/rfc822" });
          const headers = new Headers();
          headers.set("Content-Type", "message/rfc822");
          headers.set("X-Thunderbird-Message-Id", headerMessageId);
          headers.set("X-RAG-Request-Id", requestId);

          const resp = await fetch(`${base}/query/evidence`, {
            method: "POST",
            headers,
            body: blob,
          });
          const text = await resp.text();
          if (!resp.ok) {
            throw new Error(`Evidence upload failed: HTTP ${resp.status}: ${text}`);
          }
        }

        for (let i = 0; i < validMessageIds.length; i++) {
          const mid = String(validMessageIds[i] || "").trim();
          if (!mid) continue;
          setTypingPhase(assistant.bubble, `Fetching emails (${i + 1}/${validMessageIds.length})\u2026`);
          const got = await browser.runtime.sendMessage({
            type: "getRawMessageByHeaderMessageId",
            headerMessageId: mid,
          });
          const raw = got?.raw;
          await postEvidence(mid, raw);
        }
      }
      setTypingDots(assistant.bubble, "Compressing emails\u2026");

      startProgressPolling();
      const final = await fetchJson(`${base}/query/complete`, {
        session_id,
        request_id: requestId,
        chat_model: chatModel,
        summarize_model: summarizeModel,
        stale_ids: staleIds,
      });
      stopProgressPolling();

      const answer = String(final?.answer || "");
      const sources = Array.isArray(final?.sources) ? final.sources : srcs;
      // Merge folder info from TB validation into server-returned sources
      for (const s of sources) {
        const did = String(s?.doc_id || "");
        if (did && folderByDocId[did]) s.folder = folderByDocId[did];
      }
      setAssistantMessage(assistant.bubble, answer, sources, retrievalInfo);
      return;
    } else {
      const answer = res?.answer || "";
      setAssistantMessage(assistant.bubble, answer, srcs);
    }
  } catch (e) {
    stopProgressPolling();
    $("error").textContent = String(e && e.message ? e.message : e);
    assistant.bubble.textContent = "(error)";
  } finally {
    stopProgressPolling();
    inFlight = false;
    $("askBtn").disabled = false;
  }
}

/*
  Fetch the list of available Ollama models from the OCaml server and populate
  all model <select> dropdowns.  Selects either the previously-saved model
  (from localStorage) or the server's default for each dropdown.
*/
function populateSelect(sel, models, defaultModel, storageKey) {
  const savedModel = localStorage.getItem(storageKey) || "";
  sel.innerHTML = "";
  if (models.length === 0) {
    const opt = document.createElement("option");
    opt.value = "";
    opt.textContent = "(no models found)";
    sel.appendChild(opt);
    return;
  }
  for (const m of models) {
    const opt = document.createElement("option");
    opt.value = m;
    opt.textContent = m;
    sel.appendChild(opt);
  }
  if (savedModel && models.includes(savedModel)) {
    sel.value = savedModel;
  } else if (defaultModel && models.includes(defaultModel)) {
    sel.value = defaultModel;
  } else {
    sel.value = models[0];
  }
}

async function fetchModels() {
  const base = await getServerBase();
  const selectors = [
    { el: $("chatModel"),       key: "rag.chatModel",       defaultKey: "default_chat_model" },
    { el: $("summarizeModel"),  key: "rag.summarizeModel",  defaultKey: "default_summarize_model" },
    { el: $("rewriteModel"),    key: "rag.rewriteModel",    defaultKey: "default_rewrite_model" },
  ];
  try {
    const resp = await fetch(`${base}/admin/models`);
    const data = await resp.json();
    const models = Array.isArray(data?.models) ? data.models : [];
    for (const s of selectors) {
      populateSelect(s.el, models, String(data?.[s.defaultKey] || ""), s.key);
    }
  } catch (e) {
    for (const s of selectors) {
      s.el.innerHTML = "";
      const opt = document.createElement("option");
      opt.value = "";
      opt.textContent = "(error loading models)";
      s.el.appendChild(opt);
    }
  }
}

/* Load the default top-K from add-on storage (set in options page) into the query input. */
async function loadDefaultTopK() {
  try {
    const data = await browser.storage.local.get("ragDefaultTopK");
    const val = parseInt(data.ragDefaultTopK, 10);
    if (val && val >= 1 && val <= 50) {
      $("topK").value = val;
    }
  } catch (_e) { /* keep hardcoded default */ }
}

/* Initialize the UI: restore saved settings from localStorage and wire up event listeners. */
function init() {
  loadDefaultTopK();

  $("askBtn").addEventListener("click", onAsk);

  $("question").addEventListener("keydown", (e) => {
    if (e.key !== "Enter") return;

    // Enter sends; Cmd+Enter inserts a newline.
    if (e.metaKey) {
      return;
    }

    // Any other modifier should behave like a normal textarea (insert newline).
    if (e.ctrlKey || e.shiftKey || e.altKey) {
      return;
    }

    e.preventDefault();
    onAsk();
  });

  // Persist selected models.
  for (const [id, key] of [["chatModel", "rag.chatModel"], ["summarizeModel", "rag.summarizeModel"], ["rewriteModel", "rag.rewriteModel"]]) {
    $(id).addEventListener("change", () => {
      localStorage.setItem(key, $(id).value);
    });
  }

  // Re-fetch models if the server URL changes in options.
  browser.storage.onChanged.addListener((changes, area) => {
    if (area === "local" && changes.ragServerBase) {
      fetchModels();
    }
  });

  // ── Auto-focus the question textarea ──
  // Thunderbird tabs may not hand keyboard focus to web content immediately.
  // Strategy: poll aggressively for the first few seconds, re-focus after
  // async init, and as a last resort capture the first user interaction.
  const q = $("question");

  function tryFocus() {
    try { window.focus(); } catch (_) {}
    q.focus();
  }

  // 1. Fetch models (populates <select> → can steal focus), then re-focus.
  fetchModels().then(() => { tryFocus(); });

  // 2. Poll every 200 ms for up to 5 seconds.
  tryFocus();
  let focusAttempts = 0;
  const focusTimer = setInterval(() => {
    tryFocus();
    focusAttempts++;
    if (focusAttempts >= 25 || document.activeElement === q) {
      clearInterval(focusTimer);
    }
  }, 200);

  // 3. Re-focus when the window/tab gains focus.
  window.addEventListener("focus", tryFocus);

  // 4. Ultimate fallback: capture first keydown anywhere and redirect to
  //    textarea so the user can just start typing without clicking.
  function onFirstKey(e) {
    const active = document.activeElement;
    if (active && (active.tagName === "TEXTAREA" || active.tagName === "INPUT" || active.tagName === "SELECT")) return;
    q.focus();
    document.removeEventListener("keydown", onFirstKey, true);
  }
  document.addEventListener("keydown", onFirstKey, true);
}

init();
