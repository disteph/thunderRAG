/*
  ThunderRAG task manager UI logic

  Manages task list and per-task conversation across a 3-pane layout:
  - Left pane: task list from /task/list (filterable, sortable)
  - Mid pane: conversation with LLM loaded from server (persistent state)
  - Right pane: compose form (To/Cc/Bcc/Subject/Body) populated by [DRAFT] markers

  Entry points:
  - tasks.html                     — full task list
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
let activeTaskId = null;  // Currently selected task_id
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

  // Auto-select task if specified
  if (params.taskId) {
    selectTask(params.taskId);
  } else if (tasks.length > 0) {
    selectTask(tasks[0].task_id);
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

  if (tasks.length === 0) {
    list.innerHTML = '<div class="empty-state" style="padding:20px;font-size:12px;">No tasks found</div>';
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
  if (!activeTask) {
    pane.innerHTML = '<div class="empty-state">Select a task on the left</div>';
    return;
  }

  pane.innerHTML = "";

  // Header: task metadata + linked emails
  const header = document.createElement("div");
  header.className = "mid-header";

  const emails = activeTask.emails || [];
  const emailLines = emails.map((e, i) =>
    `<a class="email-link" data-doc-id="${esc(e.doc_id)}">${esc(`E${i+1}`)}</a>: ${esc(e.doc_id)} (${esc(e.role)})`
  ).join("<br>");

  header.innerHTML = `
    <div class="mh-title">${esc(activeTask.title || "(untitled)")}</div>
    <div class="mh-desc">${esc(activeTask.description || "")}</div>
    ${emails.length ? `<div class="mh-emails">${emailLines}</div>` : ""}
    <div class="mh-actions">
      <button id="markDoneBtn">Mark done</button>
      <button id="dismissBtn" class="danger">Dismiss</button>
    </div>
  `;
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
