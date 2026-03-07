/*
  ThunderRAG unified task manager + conversation UI

  3-pane layout:
  - Left pane: permanent "General chat" at top + task list from /task/list
  - Mid pane: RAG conversation (General chat) or per-task LLM conversation
  - Right pane: compose form (To/Cc/Bcc/Subject/Body) for task drafts

  Entry points:
  - tasks.html                     — opens with General chat selected
  - tasks.html?task_id=<id>        — open specific task
  - tasks.html?email_ids=[...]     — tasks referencing specific emails
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

let tasks = [];           // Array of task summary objects from /task/list
let activeTaskId = "general";  // Currently selected task_id ("general" = RAG conversation)
let activeTask = null;    // Full task detail from /task/get (conversation, drafts, emails)
let activeDraftIdx = 0;   // Which draft tab is selected (0-based)
let isLoading = false;    // Whether an LLM call is in progress

/* ── Initialization ── */

function parseUrlParams() {
  const params = new URLSearchParams(window.location.search);
  return {
    taskId: params.get("task_id") || "",
    emailIds: (() => {
      const raw = params.get("email_ids");
      if (!raw) return null;
      try { return JSON.parse(decodeURIComponent(raw)); } catch (_) { return null; }
    })(),
  };
}

async function init() {
  const params = parseUrlParams();

  // Set up filter/sort controls
  document.getElementById("statusFilter").addEventListener("change", () => loadTaskList());
  document.getElementById("sortBy").addEventListener("change", () => loadTaskList());

  // Load task list
  await loadTaskList(params.emailIds);

  // Auto-select task if specified, otherwise General chat
  if (params.taskId) {
    selectTask(params.taskId);
  } else if (params.emailIds && tasks.length > 0) {
    selectTask(tasks[0].task_id);
  } else {
    selectTask("general");
  }
}

/* ── Task list (left pane) ── */

async function loadTaskList(emailIds) {
  try {
    const base = await getServerBase();
    const statusFilter = document.getElementById("statusFilter").value;
    const sortBy = document.getElementById("sortBy").value;

    const body = {};
    if (statusFilter) body.status = statusFilter;
    if (sortBy) body.sort_by = sortBy;
    if (emailIds) body.email_ids = emailIds;

    // Default: show open + in_progress if no explicit filter
    if (!statusFilter && !emailIds) {
      // Don't filter — the default sort by updated_at will show active tasks first
    }

    const resp = await fetch(`${base}/task/list`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    if (!resp.ok) throw new Error(`Server error: ${resp.status}`);
    const data = await resp.json();
    tasks = data.tasks || [];
  } catch (e) {
    console.error("[tasks.list]", e);
    tasks = [];
  }

  renderTaskList();
}

function renderTaskList() {
  const list = document.getElementById("taskList");
  list.innerHTML = "";

  // Always-present "General chat" pseudo-task at top
  const gcEl = document.createElement("div");
  gcEl.className = "task-item" + (activeTaskId === "general" ? " active" : "");
  gcEl.dataset.id = "general";
  gcEl.innerHTML = `
    <div class="ti-title">💬 General chat</div>
    <div class="ti-desc">RAG conversation</div>
  `;
  gcEl.addEventListener("click", () => selectTask("general"));
  list.appendChild(gcEl);

  if (tasks.length === 0) {
    const emptyEl = document.createElement("div");
    emptyEl.className = "empty-state";
    emptyEl.style.cssText = "padding:20px;font-size:12px;";
    emptyEl.textContent = "No tasks yet";
    list.appendChild(emptyEl);
    return;
  }

  for (const t of tasks) {
    const el = document.createElement("div");
    el.className = "task-item" + (t.task_id === activeTaskId ? " active" : "");
    el.dataset.id = t.task_id;

    const badge = statusBadge(t.status);
    const deadline = t.deadline ? `<span style="font-size:10px;">📅 ${esc(t.deadline)}</span>` : "";
    const pip = importancePip(t.importance_score);

    el.innerHTML = `
      <div class="ti-title">${esc(t.title || "(untitled)")}</div>
      <div class="ti-desc">${esc(t.description || "")}</div>
      <div class="ti-meta">${badge} ${pip} ${deadline}</div>
    `;
    el.addEventListener("click", () => selectTask(t.task_id));
    list.appendChild(el);
  }
}

function statusBadge(status) {
  const labels = {
    open: "Open",
    in_progress: "In progress",
    done: "Done",
    dismissed: "Dismissed",
  };
  return `<span class="badge badge-${status}">${labels[status] || status}</span>`;
}

function importancePip(score) {
  if (score == null) return "";
  let color;
  if (score >= 70) color = "#dc2626";
  else if (score >= 40) color = "#f59e0b";
  else color = "#22c55e";
  return `<span class="importance-pip" style="background:${color};" title="Importance: ${score}"></span>`;
}

function esc(s) {
  const el = document.createElement("span");
  el.textContent = s;
  return el.innerHTML;
}

/* ── Task selection ── */

async function selectTask(taskId) {
  activeTaskId = taskId;
  activeDraftIdx = 0;
  renderTaskList();

  if (taskId === "general") {
    activeTask = null;
    renderMidPane();
    renderRightPane();
    return;
  }

  // Load full task detail from server
  try {
    const base = await getServerBase();
    const resp = await fetch(`${base}/task/get`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ task_id: taskId }),
    });
    if (!resp.ok) throw new Error(`Server error: ${resp.status}`);
    activeTask = await resp.json();
  } catch (e) {
    console.error("[tasks.get]", e);
    activeTask = null;
  }

  renderMidPane();
  renderRightPane();
}

/* ── Mid pane: conversation ── */

function renderMidPane() {
  const pane = document.getElementById("midPane");

  // General chat mode: embed the RAG query UI
  if (activeTaskId === "general") {
    pane.innerHTML = '';
    const iframe = document.createElement("iframe");
    iframe.src = "query.html";
    iframe.style.cssText = "width:100%;height:100%;border:none;";
    pane.appendChild(iframe);
    return;
  }

  if (!activeTask) {
    pane.innerHTML = '<div class="empty-state">Select a task on the left</div>';
    return;
  }

  pane.innerHTML = "";

  // Header: task metadata + linked emails
  const header = document.createElement("div");
  header.className = "mid-header";

  const titleEl = document.createElement("div");
  titleEl.className = "mh-title";
  titleEl.textContent = activeTask.title || "(untitled)";
  header.appendChild(titleEl);

  const descEl = document.createElement("div");
  descEl.className = "mh-desc";
  descEl.textContent = activeTask.description || "";
  header.appendChild(descEl);

  const emails = activeTask.emails || [];
  if (emails.length) {
    const emailsDiv = document.createElement("div");
    emailsDiv.className = "mh-emails";
    for (const e of emails) {
      const row = document.createElement("div");
      row.className = "mh-email-row";
      row.style.position = "relative";

      const sender = (e.sender || "").replace(/<[^>]+>/g, "").trim() || e.doc_id;
      const subject = e.subject || "(no subject)";
      const date = e.date || "";
      const roleTag = e.role && e.role !== "trigger" ? ` [${e.role}]` : "";

      const link = document.createElement("a");
      link.className = "email-link";
      link.href = "#";
      link.textContent = `${sender} — ${subject}${date ? " (" + date + ")" : ""}${roleTag}`;
      link.addEventListener("click", async (ev) => {
        ev.preventDefault();
        try {
          await browser.runtime.sendMessage({
            type: "openMessageByHeaderMessageId",
            headerMessageId: e.doc_id,
          });
        } catch (_) {}
      });

      // Oil tank icon — opens ingested-detail in a new tab
      const tankBtn = document.createElement("span");
      tankBtn.className = "email-tank-icon";
      tankBtn.textContent = "\uD83D\uDEE2\uFE0F";
      tankBtn.title = "Show ingested data";
      tankBtn.addEventListener("click", async (ev) => {
        ev.stopPropagation();
        try {
          const base = await getServerBase();
          const msgs = [{ id: e.doc_id, from: e.sender || "", subject: e.subject || "", date: e.date || "" }];
          const url = browser.runtime.getURL("ui/ingested-detail.html")
            + `?msgs=${encodeURIComponent(JSON.stringify(msgs))}&endpoint=${encodeURIComponent(base)}`;
          browser.tabs.create({ url });
        } catch (_) {}
      });

      // Hover popup with ingested data (same content as ingested-detail page)
      let popup = null;
      let hideTimer = null;
      const showPopup = async () => {
        if (hideTimer) { clearTimeout(hideTimer); hideTimer = null; }
        if (popup) return;
        popup = document.createElement("div");
        popup.className = "email-hover-popup";
        popup.textContent = "Loading…";
        row.appendChild(popup);
        try {
          const base = await getServerBase();
          const resp = await fetch(`${base}/admin/email_detail`, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ doc_id: e.doc_id }),
          });
          if (!resp.ok) throw new Error("not found");
          const detail = await resp.json();
          if (!popup || !popup.parentNode) return;
          popup.textContent = "";
          const lines = [];
          if (detail.sender) lines.push("From: " + detail.sender);
          if (detail.recipient) lines.push("To: " + detail.recipient);
          if (detail.cc) lines.push("Cc: " + detail.cc);
          if (detail.subject) lines.push("Subject: " + detail.subject);
          if (detail.email_date) lines.push("Date: " + detail.email_date);
          if (detail.attachments && detail.attachments.length) lines.push("Attachments: " + detail.attachments.join(", "));
          if (detail.action_score != null) lines.push("Action: " + detail.action_score + "/100");
          if (detail.importance_score != null) lines.push("Importance: " + detail.importance_score + "/100");
          if (detail.reply_by) lines.push("Reply by: " + detail.reply_by);
          lines.push(detail.processed ? "✔ Processed" : "✗ Not processed");
          if (detail.body_text) {
            const preview = detail.body_text.length > 400 ? detail.body_text.slice(0, 400) + "…" : detail.body_text;
            lines.push("───────────");
            lines.push(preview);
          }
          popup.textContent = lines.join("\n");
        } catch (_) {
          if (popup && popup.parentNode) popup.textContent = "(no ingested data)";
        }
      };
      const dismissPopup = () => {
        hideTimer = setTimeout(() => {
          if (popup && popup.parentNode) popup.remove();
          popup = null;
        }, 200);
      };
      link.addEventListener("mouseenter", showPopup);
      link.addEventListener("mouseleave", dismissPopup);
      tankBtn.addEventListener("mouseenter", showPopup);
      tankBtn.addEventListener("mouseleave", dismissPopup);

      row.appendChild(link);
      row.appendChild(tankBtn);
      emailsDiv.appendChild(row);
    }
    header.appendChild(emailsDiv);
  }

  const actions = document.createElement("div");
  actions.className = "mh-actions";
  actions.innerHTML = `
    <button id="markDoneBtn">Mark done</button>
    <button id="dismissBtn" class="danger">Dismiss</button>
  `;
  header.appendChild(actions);
  pane.appendChild(header);

  // Wire up action buttons
  header.querySelector("#markDoneBtn").addEventListener("click", () => updateTaskStatus("done"));
  header.querySelector("#dismissBtn").addEventListener("click", () => updateTaskStatus("dismissed"));

  // Chat area
  const chat = document.createElement("div");
  chat.className = "mid-chat";

  const conversation = activeTask.conversation || [];
  for (const m of conversation) {
    const role = m.role || "assistant";
    const content = m.content || "";
    const row = document.createElement("div");
    row.className = "msg msg-" + role;
    const bubble = document.createElement("div");
    bubble.className = "bubble";
    bubble.textContent = role === "assistant" ? stripMarkers(content) : content;
    row.appendChild(bubble);
    chat.appendChild(row);
  }

  // Show typing indicator if loading
  if (isLoading) {
    const row = document.createElement("div");
    row.className = "msg msg-assistant";
    row.innerHTML = `<div class="bubble"><span class="typing"><span class="dot"></span><span class="dot"></span><span class="dot"></span></span></div>`;
    chat.appendChild(row);
  }
  pane.appendChild(chat);

  // Scroll chat to bottom
  requestAnimationFrame(() => { chat.scrollTop = chat.scrollHeight; });

  // Composer
  if (activeTask.status !== "done" && activeTask.status !== "dismissed") {
    const composer = document.createElement("div");
    composer.className = "mid-composer";
    composer.innerHTML = `
      <textarea id="chatInput" rows="1" placeholder="Type a message…"></textarea>
      <button id="sendBtn">Send</button>
    `;
    pane.appendChild(composer);

    const input = composer.querySelector("#chatInput");
    const btn = composer.querySelector("#sendBtn");
    btn.addEventListener("click", () => sendMessage(input));
    input.addEventListener("keydown", (e) => {
      if (e.key === "Enter" && !e.shiftKey && !e.metaKey && !e.ctrlKey) {
        e.preventDefault();
        sendMessage(input);
      }
    });
    requestAnimationFrame(() => input.focus());
  }
}

function stripMarkers(text) {
  let s = text;
  // Remove [DRAFT]...[/DRAFT] blocks
  s = s.replace(/\[DRAFT[^\]]*\][\s\S]*?\[\/DRAFT\]/g, "");
  // Remove single-line markers
  s = s.replace(/^\[SCORE [^\]]*\]\s*$/gm, "");
  s = s.replace(/^\[DEADLINE [^\]]*\]\s*$/gm, "");
  s = s.replace(/^\[TITLE [^\]]*\]\s*$/gm, "");
  s = s.replace(/^\[DESCRIPTION [^\]]*\]\s*$/gm, "");
  s = s.replace(/^\[DONE\]\s*$/gm, "");
  s = s.replace(/^\[TASK_NEW [^\]]*\]\s*$/gm, "");
  s = s.replace(/^\[LINK [^\]]*\]\s*$/gm, "");
  return s.trim() || text;
}

/* ── Send message (mid pane) ── */

async function sendMessage(inputEl) {
  const text = inputEl.value.trim();
  if (!text || isLoading || !activeTask) return;

  isLoading = true;
  // Optimistically add user message to conversation for display
  activeTask.conversation = activeTask.conversation || [];
  activeTask.conversation.push({ role: "user", content: text });
  inputEl.value = "";
  renderMidPane();

  try {
    const base = await getServerBase();
    const userName = await getWhoAmI();
    const resp = await fetch(`${base}/task/chat`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        task_id: activeTaskId,
        user_message: text,
        user_name: userName,
      }),
    });
    if (!resp.ok) {
      const errBody = await resp.text().catch(() => "");
      throw new Error(`Server ${resp.status}: ${errBody}`);
    }
    const data = await resp.json();

    // Server has persisted the updated conversation; reload full task
    await selectTask(activeTaskId);

    // Process side effects
    if (data.side_effects) {
      for (const se of data.side_effects) {
        if (se.type === "task_new") {
          // Reload task list to show the new task
          await loadTaskList();
        }
        if (se.type === "done") {
          await loadTaskList();
        }
      }
    }
  } catch (e) {
    console.error("[tasks.chat]", e);
    activeTask.conversation.push({
      role: "assistant",
      content: `Error: ${e.message}`,
    });
  }

  isLoading = false;
  renderMidPane();
  renderRightPane();
}

/* ── Task status update ── */

async function updateTaskStatus(newStatus) {
  if (!activeTask) return;
  if (newStatus === "dismissed" && !confirm("Dismiss this task?")) return;

  try {
    const base = await getServerBase();
    await fetch(`${base}/task/update`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ task_id: activeTaskId, status: newStatus }),
    });
    // Reload
    await loadTaskList();
    await selectTask(activeTaskId);
  } catch (e) {
    console.error("[tasks.update]", e);
    alert(`Failed to update task: ${e.message}`);
  }
}

/* ── Right pane: compose form ── */

function renderRightPane() {
  const pane = document.getElementById("rightPane");

  // Hide right pane for General chat
  if (activeTaskId === "general") {
    pane.style.display = "none";
    return;
  }
  pane.style.display = "";

  if (!activeTask) {
    pane.innerHTML = '<div class="empty-state">Compose form will appear here</div>';
    return;
  }

  const drafts = activeTask.drafts || [];
  if (drafts.length === 0) {
    pane.innerHTML = '<div class="empty-state">No drafts yet — continue the conversation</div>';
    return;
  }

  pane.innerHTML = "";

  // Draft tabs (if multiple)
  const header = document.createElement("div");
  header.className = "right-header";
  if (drafts.length > 1) {
    const tabs = document.createElement("div");
    tabs.className = "draft-tabs";
    drafts.forEach((d, i) => {
      const tab = document.createElement("div");
      tab.className = "draft-tab" + (i === activeDraftIdx ? " active" : "");
      tab.textContent = d.subject ? `Draft ${i+1}: ${d.subject.substring(0, 20)}` : `Draft ${i+1}`;
      tab.addEventListener("click", () => { activeDraftIdx = i; renderRightPane(); });
      tabs.appendChild(tab);
    });
    header.appendChild(tabs);
  } else {
    header.textContent = "Compose";
  }
  pane.appendChild(header);

  const draft = drafts[activeDraftIdx] || drafts[0];
  if (!draft) return;

  // Compose fields
  const fields = document.createElement("div");
  fields.className = "compose-fields";
  fields.innerHTML = `
    <div class="cf-row"><span class="cf-label">To:</span><input id="composeTo" value="${esc(draft.to || "")}"></div>
    <div class="cf-row"><span class="cf-label">Cc:</span><input id="composeCc" value="${esc(draft.cc || "")}"></div>
    <div class="cf-row"><span class="cf-label">Bcc:</span><input id="composeBcc" value="${esc(draft.bcc || "")}"></div>
    <div class="cf-row"><span class="cf-label">Subject:</span><input id="composeSubject" value="${esc(draft.subject || "")}"></div>
  `;
  pane.appendChild(fields);

  // Body
  const bodyDiv = document.createElement("div");
  bodyDiv.className = "compose-body";
  const ta = document.createElement("textarea");
  ta.id = "composeBody";
  ta.value = draft.body || "";
  bodyDiv.appendChild(ta);
  pane.appendChild(bodyDiv);

  // Actions
  const actions = document.createElement("div");
  actions.className = "right-actions";
  actions.innerHTML = `
    <button id="openComposeBtn">Open in Thunderbird</button>
    <button id="sendNowBtn" class="primary">Send now</button>
  `;
  pane.appendChild(actions);

  actions.querySelector("#openComposeBtn").addEventListener("click", () => openInCompose(draft));
  actions.querySelector("#sendNowBtn").addEventListener("click", () => sendDraftNow(draft));
}

/* ── Send / Compose ── */

function getComposeFields() {
  return {
    to: document.getElementById("composeTo")?.value || "",
    cc: document.getElementById("composeCc")?.value || "",
    bcc: document.getElementById("composeBcc")?.value || "",
    subject: document.getElementById("composeSubject")?.value || "",
    body: document.getElementById("composeBody")?.value || "",
  };
}

async function openInCompose(draft) {
  const fields = getComposeFields();
  try {
    await browser.runtime.sendMessage({
      type: "openCompose",
      to: fields.to,
      cc: fields.cc,
      bcc: fields.bcc,
      subject: fields.subject,
      body: fields.body,
      inReplyTo: draft.in_reply_to || "",
    });
  } catch (e) {
    console.error("[openCompose]", e);
    alert(`Failed to open compose window: ${e.message}`);
  }
}

async function sendDraftNow(draft) {
  const fields = getComposeFields();
  if (!fields.body.trim()) return;
  if (!confirm("Send this email now?")) return;

  const btn = document.getElementById("sendNowBtn");
  if (btn) { btn.disabled = true; btn.textContent = "Sending…"; }

  try {
    await browser.runtime.sendMessage({
      type: "sendCompose",
      to: fields.to,
      cc: fields.cc,
      bcc: fields.bcc,
      subject: fields.subject,
      body: fields.body,
      inReplyTo: draft.in_reply_to || "",
    });
    if (btn) { btn.textContent = "Sent ✓"; }
  } catch (e) {
    console.error("[sendNow]", e);
    if (btn) { btn.disabled = false; btn.textContent = "Send now"; }
    alert(`Failed to send: ${e.message}`);
  }
}

/* ── Boot ── */
init();
