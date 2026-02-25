/*
  ThunderRAG reply-drafting UI logic

  Manages per-email state across a 3-pane layout:
  - Left pane: list of emails, click to switch
  - Mid pane: conversation with LLM (interview questions)
  - Right pane: draft editor + send button

  Each email has its own state object tracking conversation history,
  draft text, and status (pending/interviewing/no_reply/drafted/sent).
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

async function getWhoAmI() {
  try {
    const data = await browser.storage.local.get("ragWhoAmI");
    return (data.ragWhoAmI || "").trim();
  } catch (_e) {
    return "";
  }
}

/* ── State ── */

// emailStates: Map<headerMessageId, EmailState>
// EmailState = {
//   headerMessageId: string,
//   status: "pending" | "loading" | "no_reply" | "interviewing" | "drafted" | "sent",
//   metadata: { from, to, cc, subject, date } | null,
//   bodyPreview: string,
//   systemPrompt: string,       // from /reply/start
//   firstUserMessage: string,   // hidden first message from /reply/start
//   messages: [{role, content}], // conversation (excluding system prompt; includes hidden first msg)
//   draftBody: string,
//   replyType: "sender" | "all",
//   noReplyReason: string,
// }
const emailStates = new Map();
let activeId = null; // currently selected headerMessageId

/* ── Initialization ── */

function parseUrlIds() {
  const params = new URLSearchParams(window.location.search);
  const raw = params.get("ids");
  if (!raw) return [];
  try {
    return JSON.parse(decodeURIComponent(raw));
  } catch (_) {
    return [];
  }
}

async function init() {
  const ids = parseUrlIds();
  if (!ids.length) return;

  for (const id of ids) {
    emailStates.set(id, {
      headerMessageId: id,
      status: "pending",
      metadata: null,
      bodyPreview: "",
      systemPrompt: "",
      firstUserMessage: "",
      messages: [],
      draftBody: "",
      replyType: "sender",
      noReplyReason: "",
    });
  }

  renderEmailList();
  selectEmail(ids[0]);

  // Kick off /reply/start for all emails in parallel
  for (const id of ids) {
    startReplyFlow(id);
  }
}

/* ── Left pane ── */

function renderEmailList() {
  const list = document.getElementById("emailList");
  list.innerHTML = "";
  for (const [id, st] of emailStates) {
    const el = document.createElement("div");
    el.className = "email-item" + (id === activeId ? " active" : "");
    el.dataset.id = id;

    const from = st.metadata?.from || id;
    const subject = st.metadata?.subject || "(loading…)";
    const badge = statusBadge(st.status);

    el.innerHTML = `
      <div class="ei-from">${esc(shortFrom(from))}</div>
      <div class="ei-subject">${esc(subject)}</div>
      <div class="ei-status">${badge}</div>
    `;
    el.addEventListener("click", () => selectEmail(id));
    list.appendChild(el);
  }
}

function shortFrom(from) {
  // "Name <email>" → "Name"; bare email stays as-is
  const m = from.match(/^(.+?)\s*<[^>]+>$/);
  return m ? m[1].trim() : from;
}

function statusBadge(status) {
  const labels = {
    pending: "Pending",
    loading: "Loading…",
    no_reply: "No reply needed",
    interviewing: "Interviewing",
    drafted: "Draft ready",
    sent: "Sent ✓",
  };
  return `<span class="badge badge-${status}">${labels[status] || status}</span>`;
}

function esc(s) {
  const el = document.createElement("span");
  el.textContent = s;
  return el.innerHTML;
}

function selectEmail(id) {
  activeId = id;
  renderEmailList();
  renderMidPane();
  renderRightPane();
}

/* ── Mid pane ── */

function renderMidPane() {
  const pane = document.getElementById("midPane");
  const st = emailStates.get(activeId);
  if (!st) {
    pane.innerHTML = '<div class="empty-state">Select an email</div>';
    return;
  }

  pane.innerHTML = "";

  // Header: email metadata + body preview
  const header = document.createElement("div");
  header.className = "mid-header";
  if (st.metadata) {
    header.innerHTML = `
      <div class="mh-subject">${esc(st.metadata.subject || "(no subject)")}</div>
      <div class="mh-meta">
        From: ${esc(st.metadata.from || "")}${st.metadata.to ? "<br>To: " + esc(st.metadata.to) : ""}${st.metadata.cc ? "<br>Cc: " + esc(st.metadata.cc) : ""}${st.metadata.date ? "<br>Date: " + esc(st.metadata.date) : ""}
      </div>
      ${st.bodyPreview ? `<div class="mh-body">${esc(st.bodyPreview)}</div>` : ""}
    `;
  } else {
    header.innerHTML = `<div class="mh-meta">${esc(st.headerMessageId)}</div>`;
  }
  pane.appendChild(header);

  // No-reply banner
  if (st.status === "no_reply") {
    const banner = document.createElement("div");
    banner.className = "no-reply-banner";
    banner.innerHTML = `
      <div>${esc(st.noReplyReason || "The LLM determined no reply is needed for this email.")}</div>
      <button id="overrideNoReply">Still draft a reply</button>
    `;
    pane.appendChild(banner);
    banner.querySelector("#overrideNoReply").addEventListener("click", () => overrideNoReply(st));
    return;
  }

  // Chat area
  const chat = document.createElement("div");
  chat.className = "mid-chat";
  // Skip the first message (hidden context) when rendering
  const visibleMsgs = st.messages.slice(1);
  for (const m of visibleMsgs) {
    const row = document.createElement("div");
    row.className = "msg msg-" + m.role;
    const bubble = document.createElement("div");
    bubble.className = "bubble";
    bubble.textContent = cleanMessageForDisplay(m.content, m.role);
    row.appendChild(bubble);
    chat.appendChild(row);
  }
  // Show typing indicator if loading
  if (st.status === "loading") {
    const row = document.createElement("div");
    row.className = "msg msg-assistant";
    row.innerHTML = `<div class="bubble"><span class="typing"><span class="dot"></span><span class="dot"></span><span class="dot"></span></span></div>`;
    chat.appendChild(row);
  }
  pane.appendChild(chat);

  // Scroll chat to bottom
  requestAnimationFrame(() => { chat.scrollTop = chat.scrollHeight; });

  // Composer (only if interviewing)
  if (st.status === "interviewing") {
    const composer = document.createElement("div");
    composer.className = "mid-composer";
    composer.innerHTML = `
      <textarea id="replyInput" rows="1" placeholder="Your answer…"></textarea>
      <button id="sendAnswer">Send</button>
    `;
    pane.appendChild(composer);

    const input = composer.querySelector("#replyInput");
    const btn = composer.querySelector("#sendAnswer");
    btn.addEventListener("click", () => sendAnswer(st, input));
    input.addEventListener("keydown", (e) => {
      if (e.key === "Enter" && !e.shiftKey && !e.metaKey && !e.ctrlKey) {
        e.preventDefault();
        sendAnswer(st, input);
      }
    });
    requestAnimationFrame(() => input.focus());
  }
}

function cleanMessageForDisplay(content, role) {
  if (role !== "assistant") return content;
  // Strip [DRAFT]...[/DRAFT] and [REPLY_TYPE] markers from display
  let s = content;
  const draftStart = s.indexOf("[DRAFT]");
  if (draftStart >= 0) {
    s = s.substring(0, draftStart).trim();
  }
  s = s.replace(/\[NO_REPLY_NEEDED\]\s*/g, "").trim();
  return s || content;
}

/* ── Right pane ── */

function renderRightPane() {
  const pane = document.getElementById("rightPane");
  const st = emailStates.get(activeId);
  if (!st) {
    pane.innerHTML = '<div class="empty-state">Draft will appear here</div>';
    return;
  }

  pane.innerHTML = "";

  if (st.status === "sent") {
    const hdr = document.createElement("div");
    hdr.className = "right-header";
    hdr.textContent = "Reply sent";
    pane.appendChild(hdr);

    const body = document.createElement("div");
    body.className = "right-body";
    const ta = document.createElement("textarea");
    ta.value = st.draftBody;
    ta.disabled = true;
    body.appendChild(ta);
    pane.appendChild(body);

    const banner = document.createElement("div");
    banner.className = "sent-banner";
    banner.textContent = "✓ Reply sent";
    pane.appendChild(banner);
    return;
  }

  if (st.status === "no_reply" || st.status === "pending" || st.status === "loading") {
    pane.innerHTML = '<div class="empty-state">Draft will appear here</div>';
    return;
  }

  // Draft editor
  const hdr = document.createElement("div");
  hdr.className = "right-header";
  hdr.textContent = `Draft reply (${st.replyType === "all" ? "reply all" : "reply to sender"})`;
  pane.appendChild(hdr);

  const body = document.createElement("div");
  body.className = "right-body";
  const ta = document.createElement("textarea");
  ta.id = "draftEditor";
  ta.value = st.draftBody;
  ta.addEventListener("input", () => { st.draftBody = ta.value; });
  body.appendChild(ta);
  pane.appendChild(body);

  const actions = document.createElement("div");
  actions.className = "right-actions";
  actions.innerHTML = `
    <button id="saveDraftBtn">Save as draft</button>
    <button id="sendNowBtn" class="primary">Send now</button>
  `;
  pane.appendChild(actions);

  actions.querySelector("#saveDraftBtn").addEventListener("click", () => saveDraft(st));
  actions.querySelector("#sendNowBtn").addEventListener("click", () => sendNow(st));
}

/* ── Reply flow ── */

async function startReplyFlow(id) {
  const st = emailStates.get(id);
  if (!st) return;

  st.status = "loading";
  if (id === activeId) { renderEmailList(); renderMidPane(); renderRightPane(); }

  try {
    // Fetch raw email from TB
    const rawResult = await browser.runtime.sendMessage({
      type: "getRawMessageByHeaderMessageId",
      headerMessageId: id,
    });
    const emailRaw = rawResult?.raw || "";
    if (!emailRaw) throw new Error("Could not fetch email");

    const base = await getServerBase();
    const userName = await getWhoAmI();

    const resp = await fetch(`${base}/reply/start`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ email_raw: emailRaw, user_name: userName }),
    });
    if (!resp.ok) throw new Error(`Server error: ${resp.status}`);
    const data = await resp.json();

    st.metadata = data.email_metadata || null;
    st.systemPrompt = data.system_prompt || "";
    st.firstUserMessage = data.first_user_message || "";

    // Extract body preview from the first user message
    const bodyMarker = "NEW CONTENT:\n";
    const bodyIdx = st.firstUserMessage.indexOf(bodyMarker);
    if (bodyIdx >= 0) {
      const afterBody = st.firstUserMessage.substring(bodyIdx + bodyMarker.length);
      const ctxIdx = afterBody.indexOf("\n\nCONTEXT EMAILS");
      st.bodyPreview = (ctxIdx >= 0 ? afterBody.substring(0, ctxIdx) : afterBody).trim().substring(0, 500);
    }

    // Set up conversation
    st.messages = [
      { role: "user", content: st.firstUserMessage },
      { role: "assistant", content: data.message || "" },
    ];

    if (!data.needs_reply) {
      st.status = "no_reply";
      // Extract reason from after [NO_REPLY_NEEDED]
      const msg = data.message || "";
      const marker = "[NO_REPLY_NEEDED]";
      const idx = msg.indexOf(marker);
      st.noReplyReason = idx >= 0 ? msg.substring(idx + marker.length).trim() : msg;
    } else if (data.done && data.draft_body) {
      st.status = "drafted";
      st.draftBody = data.draft_body;
      st.replyType = data.reply_type || "sender";
    } else {
      st.status = "interviewing";
    }
  } catch (e) {
    console.error(`[reply.start] ${id}:`, e);
    st.status = "interviewing";
    st.messages = [
      { role: "user", content: "(failed to load email)" },
      { role: "assistant", content: `Error starting reply flow: ${e.message}. You can still type here.` },
    ];
  }

  renderEmailList();
  if (id === activeId) { renderMidPane(); renderRightPane(); }
}

async function sendAnswer(st, inputEl) {
  const text = inputEl.value.trim();
  if (!text || st.status !== "interviewing") return;

  st.messages.push({ role: "user", content: text });
  st.status = "loading";
  renderMidPane();
  renderRightPane();

  try {
    const base = await getServerBase();
    // Send full conversation (excluding system prompt — server prepends it)
    const resp = await fetch(`${base}/reply/chat`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        system_prompt: st.systemPrompt,
        messages: st.messages.map(m => ({ role: m.role, content: m.content })),
      }),
    });
    if (!resp.ok) throw new Error(`Server error: ${resp.status}`);
    const data = await resp.json();

    st.messages.push({ role: "assistant", content: data.message || "" });

    if (data.done && data.draft_body) {
      st.status = "drafted";
      st.draftBody = data.draft_body;
      st.replyType = data.reply_type || "sender";
    } else if (!data.needs_reply) {
      st.status = "no_reply";
      st.noReplyReason = (data.message || "").replace(/\[NO_REPLY_NEEDED\]\s*/g, "").trim();
    } else {
      st.status = "interviewing";
    }
  } catch (e) {
    console.error(`[reply.chat] ${st.headerMessageId}:`, e);
    st.messages.push({ role: "assistant", content: `Error: ${e.message}` });
    st.status = "interviewing";
  }

  renderEmailList();
  if (st.headerMessageId === activeId) { renderMidPane(); renderRightPane(); }
}

async function overrideNoReply(st) {
  // User wants a reply even though LLM said no
  st.status = "loading";
  renderMidPane();

  st.messages.push({ role: "user", content: "Actually, I do want to reply to this email. Please ask me your questions." });

  try {
    const base = await getServerBase();
    const resp = await fetch(`${base}/reply/chat`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        system_prompt: st.systemPrompt,
        messages: st.messages.map(m => ({ role: m.role, content: m.content })),
      }),
    });
    if (!resp.ok) throw new Error(`Server error: ${resp.status}`);
    const data = await resp.json();

    st.messages.push({ role: "assistant", content: data.message || "" });

    if (data.done && data.draft_body) {
      st.status = "drafted";
      st.draftBody = data.draft_body;
      st.replyType = data.reply_type || "sender";
    } else {
      st.status = "interviewing";
    }
  } catch (e) {
    console.error(`[reply.override] ${st.headerMessageId}:`, e);
    st.messages.push({ role: "assistant", content: `Error: ${e.message}` });
    st.status = "interviewing";
  }

  renderEmailList();
  if (st.headerMessageId === activeId) { renderMidPane(); renderRightPane(); }
}

/* ── Send / Save ── */

async function saveDraft(st) {
  if (!st.draftBody.trim()) return;
  const btn = document.getElementById("saveDraftBtn");
  if (btn) { btn.disabled = true; btn.textContent = "Saving…"; }

  try {
    await browser.runtime.sendMessage({
      type: "sendReply",
      headerMessageId: st.headerMessageId,
      body: st.draftBody,
      replyType: st.replyType,
    });
    if (btn) { btn.textContent = "Saved ✓"; }
    setTimeout(() => { if (btn) { btn.disabled = false; btn.textContent = "Save as draft"; } }, 2000);
  } catch (e) {
    console.error(`[saveDraft]`, e);
    if (btn) { btn.disabled = false; btn.textContent = "Save as draft"; }
    alert(`Failed to save draft: ${e.message}`);
  }
}

async function sendNow(st) {
  if (!st.draftBody.trim()) return;
  if (!confirm("Send this reply now?")) return;

  const btn = document.getElementById("sendNowBtn");
  if (btn) { btn.disabled = true; btn.textContent = "Sending…"; }

  try {
    await browser.runtime.sendMessage({
      type: "sendReplyNow",
      headerMessageId: st.headerMessageId,
      body: st.draftBody,
      replyType: st.replyType,
    });
    st.status = "sent";
    renderEmailList();
    renderMidPane();
    renderRightPane();
  } catch (e) {
    console.error(`[sendNow]`, e);
    if (btn) { btn.disabled = false; btn.textContent = "Send now"; }
    alert(`Failed to send: ${e.message}`);
  }
}

/* ── Boot ── */
init();
