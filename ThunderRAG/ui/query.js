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

function decodeRfc2047(s) {
  const input = String(s || "");
  if (!input.includes("=?")) return input;

  const td = new TextDecoder("utf-8", { fatal: false });

  function decodeQ(payload) {
    const bytes = [];
    for (let i = 0; i < payload.length; i++) {
      const ch = payload[i];
      if (ch === "_") {
        bytes.push(0x20);
        continue;
      }
      if (ch === "=" && i + 2 < payload.length) {
        const h = payload.slice(i + 1, i + 3);
        if (/^[0-9A-Fa-f]{2}$/.test(h)) {
          bytes.push(parseInt(h, 16));
          i += 2;
          continue;
        }
      }
      bytes.push(ch.charCodeAt(0) & 0xff);
    }
    return td.decode(new Uint8Array(bytes));
  }

  function decodeB(payload) {
    let bin = "";
    try {
      bin = atob(payload.replace(/\s+/g, ""));
    } catch (_e) {
      return null;
    }
    const bytes = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i) & 0xff;
    return td.decode(bytes);
  }

  return input.replace(/=\?([^?]+)\?([bqBQ])\?([^?]*)\?=/g, (_m, charset, enc, payload) => {
    const cs = String(charset || "").trim().toLowerCase();
    if (cs !== "utf-8" && cs !== "utf8") return _m;
    const e = String(enc || "").toLowerCase();
    if (e === "q") return decodeQ(String(payload || ""));
    if (e === "b") {
      const out = decodeB(String(payload || ""));
      return out == null ? _m : out;
    }
    return _m;
  });
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
    const text = String(s?.text || "");
    const md = s?.metadata || {};

    const from = decodeRfc2047(String(md?.from || "")).trim();
    const subject = decodeRfc2047(String(md?.subject || "")).trim();
    const date = formatEmailDate(md?.date);
    const to = decodeRfc2047(String(md?.to || "")).trim();
    const cc = decodeRfc2047(String(md?.cc || "")).trim();
    const bcc = decodeRfc2047(String(md?.bcc || "")).trim();
    const attachments = Array.isArray(md?.attachments)
      ? md.attachments.filter((x) => typeof x === "string" && x.trim())
      : [];

    let snippetText = text;
    {
      const lines = snippetText.split("\n");
      let blankIdx = -1;
      for (let i = 0; i < Math.min(lines.length, 30); i++) {
        if (!String(lines[i] || "").trim()) {
          blankIdx = i;
          break;
        }
      }

      // If the chunk begins with an email header block, remove it so we don't duplicate meta.
      // We can't rely on Message-Id always being present in the chunk (chunking can cut it off).
      if (blankIdx >= 0) {
        const headerLines = lines.slice(0, blankIdx);
        const headerCount = headerLines.reduce((n, l) => {
          const t = String(l || "").trim();
          if (!t) return n;
          if (/^(From|To|Cc|Bcc|Subject|Date)\s*:/i.test(t)) return n + 1;
          return n;
        }, 0);

        // Heuristic: if we see multiple header-like lines before the first blank line,
        // treat it as the indexed header prefix.
        if (headerCount >= 2) {
          snippetText = lines.slice(blankIdx + 1).join("\n").trim();
        }
      }

      if (blankIdx < 0) {
        let headerCount = 0;
        let cut = 0;
        for (let i = 0; i < Math.min(lines.length, 20); i++) {
          const t = String(lines[i] || "").trim();
          if (!t) break;
          if (/^(From|To|Cc|Bcc|Subject|Date|Message-Id|Attachments)\s*:/i.test(t)) {
            headerCount += 1;
            cut = i + 1;
          } else {
            break;
          }
        }
        if (headerCount >= 2 && cut > 0) {
          snippetText = lines.slice(cut).join("\n").trim();
        }
      }
    }

    snippetText = snippetText
      .split("\n")
      .filter((line) => !/^Message-Id\s*:/i.test(String(line || "").trim()))
      .join("\n")
      .trim();

    const card = document.createElement("div");
    card.className = "source";
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
    title.textContent = subject || "(no subject)";
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
    if (to) metaLines.push(`To: ${to}`);
    if (cc) metaLines.push(`Cc: ${cc}`);
    if (bcc) metaLines.push(`Bcc: ${bcc}`);
    if (attachments.length) metaLines.push(`Attachments: ${attachments.join(", ")}`);
    meta.textContent = metaLines.join("\n");

    const body = document.createElement("div");
    body.className = "source-text";
    body.textContent = snippetText;

    card.appendChild(header);
    if (meta.textContent.trim()) {
      card.appendChild(meta);
    }
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
const history = [];

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
  clearError();
  if (inFlight) return;

  const base = normalizeBaseUrl($("serverBase").value);
  localStorage.setItem("rag.serverBase", base);

  const mode = String($("mode").value || "assistive");
  localStorage.setItem("rag.mode", mode);

  const question = ($("question").value || "").trim();
  const topK = parseInt($("topK").value || "8", 10);

  if (!question) {
    return;
  }

  $("question").value = "";
  appendMessage("user", question);
  history.push({ role: "user", content: question });
  const assistant = appendMessage("assistant", "...");
  inFlight = true;
  $("askBtn").disabled = true;
  $("status").textContent = "Querying...";

  try {
    const session_id = getSessionId();
    const res = await fetchJson(`${base}/query`, {
      session_id,
      question,
      top_k: topK,
      mode,
    });
    const answer = res?.answer || "";
    setAssistantMessage(assistant.bubble, answer, res?.sources || []);
    const srcs = Array.isArray(res?.sources) ? res.sources : [];
    const summary = srcs
      .slice(0, 12)
      .map((s, idx) => {
        const md = s?.metadata || {};
        const docId = s?.doc_id || "";
        const from = decodeRfc2047(md?.from || "");
        const subject = decodeRfc2047(md?.subject || "");
        const date = formatEmailDate(md?.date);
        const atts = Array.isArray(md?.attachments)
          ? md.attachments.filter((x) => typeof x === "string" && x.trim()).join(", ")
          : "";
        const attPart = atts ? ` attachments=${atts}` : "";
        return `[Source ${idx + 1}] doc_id=${docId} from=${from} subject=${subject} date=${date}${attPart}`;
      })
      .join("\n");
    history.push({ role: "assistant", content: answer });
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

function init() {
  const saved = localStorage.getItem("rag.serverBase");
  $("serverBase").value = saved || "http://localhost:8080";

  const savedMode = localStorage.getItem("rag.mode");
  $("mode").value = savedMode === "grounded" ? "grounded" : "assistive";

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
}

init();
