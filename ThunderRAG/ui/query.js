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
    right.className = "muted";
    right.textContent = date;

    header.appendChild(left);
    header.appendChild(right);

    const meta = document.createElement("div");
    meta.className = "source-meta";
    const metaLines = [];
    if (from) metaLines.push(`From: ${from}`);
    meta.textContent = metaLines.join("\n");

    card.appendChild(header);
    if (meta.textContent.trim()) {
      card.appendChild(meta);
    }
    container.appendChild(card);
  }
}

function setAssistantMessage(bubble, answer, sources, retrievalSql) {
  /*
    Renders a single assistant "bubble" with three pieces:
    - A debug-only collapsible triangle (no label) that expands the full sources list.
      If retrievalSql is provided, it is shown inline on the same line as the triangle.
    - The final answer text, with citations post-processed into clickable links.
    - Below the answer: tiles for only the sources actually cited as [Email N].

    bubble.__rag is used to keep references to the progress bar + answer element for updates.
  */
  bubble.textContent = "";

  const meta = document.createElement("div");
  meta.className = "assistant-meta";

  const details = document.createElement("details");
  const summary = document.createElement("summary");
  const summaryRow = document.createElement("div");
  summaryRow.className = "summary-row";

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
  summaryRow.appendChild(summaryProgress);

  if (retrievalSql) {
    const sqlLabel = document.createElement("span");
    sqlLabel.className = "retrieval-sql";
    sqlLabel.textContent = retrievalSql.replace(/\s+/g, " ").trim();
    sqlLabel.title = retrievalSql;
    summaryRow.appendChild(sqlLabel);
  }

  summary.appendChild(summaryRow);
  details.appendChild(summary);

  const sourcesContainer = document.createElement("div");
  sourcesContainer.className = "sources";
  renderSourcesInto(sourcesContainer, sources || []);
  details.appendChild(sourcesContainer);

  meta.appendChild(details);
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
    Show and update the inline progress bar inside the Sources summary header.
    This remains visible even while the Sources <details> is collapsed.
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

function setTypingDots(bubble) {
  /*
    Replace the answer area with an animated typing indicator while we wait for /query/complete.
  */
  const s = bubble && bubble.__rag;
  if (!s) return;
  s.answerEl.textContent = "";
  const t = document.createElement("span");
  t.className = "typing";
  t.appendChild(document.createElement("span")).className = "dot";
  t.appendChild(document.createElement("span")).className = "dot";
  t.appendChild(document.createElement("span")).className = "dot";
  s.answerEl.appendChild(t);
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

  const mode = String($("mode").value || "assistive");
  localStorage.setItem("rag.mode", mode);

  const question = ($("question").value || "").trim();
  const topK = parseInt($("topK").value || "8", 10);

  if (!question) {
    return;
  }

  $("question").value = "";
  appendMessage("user", question);
  const assistant = appendMessage("assistant", "...");
  inFlight = true;
  $("askBtn").disabled = true;
  $("status").textContent = "Querying...";

  try {
    const session_id = getSessionId();
    let user_name = "";
    try {
      const d = await browser.storage.local.get("ragWhoAmI");
      user_name = (d.ragWhoAmI || "").trim();
    } catch (_e) { /* ignore */ }
    const res = await fetchJson(`${base}/query`, {
      session_id,
      question,
      top_k: topK,
      mode,
      user_name,
    });

    const srcs = Array.isArray(res?.sources) ? res.sources : [];

    const status = String(res?.status || "");
    if (status === "need_messages" || status === "no_retrieval") {
      const requestId = String(res?.request_id || "");
      const messageIds = Array.isArray(res?.message_ids) ? res.message_ids : [];

      const retrievalSql = String(res?.retrieval_sql || "");
      setAssistantMessage(assistant.bubble, "", srcs, retrievalSql);

      if (!requestId) {
        throw new Error("Server did not return request_id");
      }

      if (messageIds.length > 0) {
        setSourcesProgress(assistant.bubble, 0, messageIds.length);

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

        for (let i = 0; i < messageIds.length; i++) {
          const mid = String(messageIds[i] || "").trim();
          if (!mid) continue;
          $("status").textContent = `Fetching evidence ${i + 1}/${messageIds.length}...`;
          const got = await browser.runtime.sendMessage({
            type: "getRawMessageByHeaderMessageId",
            headerMessageId: mid,
          });
          const raw = got?.raw;
          await postEvidence(mid, raw);
          setSourcesProgress(assistant.bubble, i + 1, messageIds.length);
        }

        hideSourcesProgress(assistant.bubble);
      }
      setTypingDots(assistant.bubble);

      const chatModel = $("chatModel").value || "";
      localStorage.setItem("rag.chatModel", chatModel);

      const final = await fetchJson(`${base}/query/complete`, {
        session_id,
        request_id: requestId,
        chat_model: chatModel,
      });

      const answer = String(final?.answer || "");
      const sources = Array.isArray(final?.sources) ? final.sources : srcs;
      setAssistantMessage(assistant.bubble, answer, sources, retrievalSql);
      $("status").textContent = "";
      return;
    } else {
      const answer = res?.answer || "";
      setAssistantMessage(assistant.bubble, answer, srcs);
      $("status").textContent = "";
    }
  } catch (e) {
    $("status").textContent = "";
    $("error").textContent = String(e && e.message ? e.message : e);
    assistant.bubble.textContent = "(error)";
  } finally {
    inFlight = false;
    $("askBtn").disabled = false;
  }
}

/*
  Fetch the list of available Ollama models from the OCaml server and populate
  the chatModel <select> dropdown.  Selects either the previously-saved model
  (from localStorage) or the server's default_chat_model.
*/
async function fetchModels() {
  const base = await getServerBase();
  const sel = $("chatModel");
  try {
    const resp = await fetch(`${base}/admin/models`);
    const data = await resp.json();
    const models = Array.isArray(data?.models) ? data.models : [];
    const defaultModel = String(data?.default_chat_model || "");
    const savedModel = localStorage.getItem("rag.chatModel") || "";

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
    // Select saved model if still available, else default, else first.
    if (savedModel && models.includes(savedModel)) {
      sel.value = savedModel;
    } else if (defaultModel && models.includes(defaultModel)) {
      sel.value = defaultModel;
    } else {
      sel.value = models[0];
    }
  } catch (e) {
    sel.innerHTML = "";
    const opt = document.createElement("option");
    opt.value = "";
    opt.textContent = "(error loading models)";
    sel.appendChild(opt);
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
  const savedMode = localStorage.getItem("rag.mode");
  $("mode").value = savedMode === "grounded" ? "grounded" : "assistive";

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

  // Persist selected model.
  $("chatModel").addEventListener("change", () => {
    localStorage.setItem("rag.chatModel", $("chatModel").value);
  });

  // Re-fetch models if the server URL changes in options.
  browser.storage.onChanged.addListener((changes, area) => {
    if (area === "local" && changes.ragServerBase) {
      fetchModels();
    }
  });

  // Fetch models on startup.
  fetchModels();
}

init();
