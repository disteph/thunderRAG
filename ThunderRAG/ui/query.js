function $(id) {
  return document.getElementById(id);
}

function normalizeBaseUrl(s) {
  const trimmed = (s || "").trim();
  if (!trimmed) {
    return "http://localhost:8080";
  }
  if (/^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(trimmed)) {
    return trimmed.replace(/\/+$/, "");
  }
  return ("http://" + trimmed).replace(/\/+$/, "");
}

async function fetchJson(url, body) {
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
    const score = typeof s?.score === "number" ? s.score : null;
    const text = s?.text || "";

    const card = document.createElement("div");
    card.className = "source";

    const header = document.createElement("div");
    header.className = "source-header";

    const left = document.createElement("div");
    const idEl = document.createElement("div");
    idEl.className = "source-id";
    idEl.textContent = docId;
    left.appendChild(idEl);

    const right = document.createElement("div");
    const btn = document.createElement("button");
    btn.textContent = "Open email";
    btn.disabled = !docId;
    btn.addEventListener("click", async () => {
      if (!docId) return;
      try {
        await browser.runtime.sendMessage({
          type: "openMessageByHeaderMessageId",
          headerMessageId: docId,
        });
      } catch (e) {
        $("error").textContent = String(e && e.message ? e.message : e);
      }
    });

    const scoreEl = document.createElement("span");
    scoreEl.className = "muted";
    scoreEl.textContent = score === null ? "" : `score=${score.toFixed(4)}`;

    right.appendChild(btn);
    right.appendChild(document.createTextNode(" "));
    right.appendChild(scoreEl);

    header.appendChild(left);
    header.appendChild(right);

    const body = document.createElement("div");
    body.className = "source-text";
    body.textContent = text;

    card.appendChild(header);
    card.appendChild(body);
    container.appendChild(card);
  }
}

function setAssistantMessage(bubble, answer, sources) {
  bubble.textContent = answer || "";

  const meta = document.createElement("div");
  meta.className = "assistant-meta";

  const details = document.createElement("details");
  const summary = document.createElement("summary");
  const n = Array.isArray(sources) ? sources.length : 0;
  summary.textContent = `Sources (${n})`;
  details.appendChild(summary);

  const sourcesContainer = document.createElement("div");
  sourcesContainer.className = "sources";
  renderSourcesInto(sourcesContainer, sources || []);
  details.appendChild(sourcesContainer);

  meta.appendChild(details);
  bubble.appendChild(meta);
}

let inFlight = false;

async function onAsk() {
  clearError();
  if (inFlight) return;

  const base = normalizeBaseUrl($("serverBase").value);
  localStorage.setItem("rag.serverBase", base);

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
    const res = await fetchJson(`${base}/query`, { question, top_k: topK });
    setAssistantMessage(assistant.bubble, res?.answer || "", res?.sources || []);
    $("status").textContent = "";
  } catch (e) {
    $("status").textContent = "";
    $("error").textContent = String(e && e.message ? e.message : e);
    assistant.bubble.textContent = "(error)";
  } finally {
    inFlight = false;
    $("askBtn").disabled = false;
  }
}

async function onReset() {
  clearError();
  $("status").textContent = "Resetting index...";

  const base = normalizeBaseUrl($("serverBase").value);
  localStorage.setItem("rag.serverBase", base);

  try {
    await fetchJson(`${base}/admin/reset`, {});
    $("status").textContent = "Reset complete.";
  } catch (e) {
    $("status").textContent = "";
    $("error").textContent = String(e && e.message ? e.message : e);
  }
}

function init() {
  const saved = localStorage.getItem("rag.serverBase");
  $("serverBase").value = saved || "http://localhost:8080";

  $("askBtn").addEventListener("click", onAsk);
  $("resetBtn").addEventListener("click", onReset);

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
}

init();
