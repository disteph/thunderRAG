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
let selectedTaskIds = new Set();  // Multi-select for bulk actions
let lastClickedTaskIdx = -1;     // For shift-click range selection
let filterEmailIds = null;       // Email IDs filter from URL params (persisted across refreshes)

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
  for (const cb of document.querySelectorAll(".status-cb")) {
    cb.addEventListener("change", () => loadTaskList(filterEmailIds));
  }
  document.getElementById("sortBy").addEventListener("change", () => loadTaskList(filterEmailIds));

  // General chat click handler (static HTML element)
  document.getElementById("generalChatItem").addEventListener("click", () => {
    selectedTaskIds.clear();
    selectTask("general");
  });

  // Memories click handler
  document.getElementById("memoriesItem").addEventListener("click", () => {
    selectedTaskIds.clear();
    selectTask("memories");
  });

  // DB Stats click handler
  document.getElementById("dbStatsItem").addEventListener("click", () => {
    selectedTaskIds.clear();
    selectTask("dbstats");
  });

  // Load models into the left-pane dropdowns
  await fetchModels();

  // Persist model selections & notify iframe on change
  for (const [id, key] of [["chatModel", "rag.chatModel"], ["summarizeModel", "rag.summarizeModel"], ["rewriteModel", "rag.rewriteModel"]]) {
    document.getElementById(id).addEventListener("change", () => {
      localStorage.setItem(key, document.getElementById(id).value);
      notifyIframeModels();
    });
  }

  // Load task list
  filterEmailIds = params.emailIds || null;
  await loadTaskList(filterEmailIds);

  // Auto-select task if specified, otherwise General chat
  if (params.taskId) {
    selectTask(params.taskId);
  } else if (params.emailIds && tasks.length > 0) {
    selectTask(tasks[0].task_id);
  } else {
    selectTask("general");
  }

  // Live refresh: listen for background.js notifications (instant)
  browser.runtime.onMessage.addListener((msg) => {
    if (msg && msg.type === "tasksChanged") {
      refreshTaskList();
    }
  });

  // Fallback poll every 15s for async changes (prefetch daemon, context readiness)
  setInterval(refreshTaskList, 15000);
}

/* ── Model management ── */

function populateSelect(sel, models, defaultModel, storageKey) {
  const savedModel = localStorage.getItem(storageKey) || "";
  sel.innerHTML = "";
  if (models.length === 0) {
    const opt = document.createElement("option");
    opt.value = "";
    opt.textContent = "(no models)";
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
    { el: document.getElementById("chatModel"),       key: "rag.chatModel",       defaultKey: "default_chat_model" },
    { el: document.getElementById("summarizeModel"),  key: "rag.summarizeModel",  defaultKey: "default_summarize_model" },
    { el: document.getElementById("rewriteModel"),    key: "rag.rewriteModel",    defaultKey: "default_rewrite_model" },
  ];
  try {
    const resp = await fetch(`${base}/admin/models`);
    const data = await resp.json();
    const models = Array.isArray(data?.models) ? data.models : [];
    for (const s of selectors) {
      populateSelect(s.el, models, String(data?.[s.defaultKey] || ""), s.key);
    }
  } catch (_) {
    for (const s of selectors) {
      s.el.innerHTML = '<option value="">(error)</option>';
    }
  }
}

function notifyIframeModels() {
  const iframe = document.querySelector("#midPane iframe");
  if (!iframe || !iframe.contentWindow) return;
  iframe.contentWindow.postMessage({
    type: "setModels",
    chatModel: document.getElementById("chatModel").value,
    summarizeModel: document.getElementById("summarizeModel").value,
    rewriteModel: document.getElementById("rewriteModel").value,
  }, "*");
}

async function refreshTaskList() {
  const prevIds = new Set(tasks.map(t => t.task_id));
  await loadTaskList(filterEmailIds);
  // If the active task is a real task (not "general"), refresh its detail too
  if (activeTaskId && activeTaskId !== "general") {
    try {
      const base = await getServerBase();
      const resp = await fetch(`${base}/task/get`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ task_id: activeTaskId }),
      });
      if (resp.ok) {
        const updated = await resp.json();
        // Re-render mid pane if context_ready changed
        const wasReady = activeTask?.context_ready;
        activeTask = updated;
        if (wasReady !== updated.context_ready) {
          renderMidPane();
          renderRightPane();
        }
      }
    } catch (_) {}
  }
}

/* ── Task list (left pane) ── */

function getCheckedStatuses() {
  return [...document.querySelectorAll(".status-cb:checked")].map(cb => cb.value);
}

async function loadTaskList(emailIds) {
  try {
    const base = await getServerBase();
    const statuses = getCheckedStatuses();
    const sortBy = document.getElementById("sortBy").value;

    const body = {};
    if (statuses.length > 0) body.statuses = statuses;
    if (sortBy) body.sort_by = sortBy;
    if (emailIds) body.email_ids = emailIds;

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

  // Update General chat, Memories, and DB Stats active states
  const gcEl = document.getElementById("generalChatItem");
  if (gcEl) {
    gcEl.className = "task-item" + (activeTaskId === "general" ? " active" : "");
  }
  const memEl = document.getElementById("memoriesItem");
  if (memEl) {
    memEl.className = "task-item" + (activeTaskId === "memories" ? " active" : "");
  }
  const dbEl = document.getElementById("dbStatsItem");
  if (dbEl) {
    dbEl.className = "task-item" + (activeTaskId === "dbstats" ? " active" : "");
  }

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
    const isActive = t.task_id === activeTaskId;
    const isSelected = selectedTaskIds.has(t.task_id);
    el.className = "task-item" + (isActive ? " active" : "") + (isSelected ? " selected" : "");
    el.dataset.id = t.task_id;

    const badge = statusBadge(t.status);
    const deadline = t.deadline ? `<span style="font-size:10px;">${esc(t.deadline)}</span>` : "";
    const pip = readinessPip(t.context_ready);

    const displayTitle = (t.title || "(untitled)").replace(/^(?:Respond|Reply) to\b/i, "↩");
    el.innerHTML = `
      <div class="ti-title">${esc(displayTitle)}</div>
      <div class="ti-meta">${badge} ${pip} ${deadline}</div>
    `;
    const taskIdx = tasks.indexOf(t);
    el.addEventListener("click", (ev) => {
      if (ev.shiftKey && lastClickedTaskIdx >= 0) {
        // Range selection from lastClickedTaskIdx to taskIdx
        const from = Math.min(lastClickedTaskIdx, taskIdx);
        const to = Math.max(lastClickedTaskIdx, taskIdx);
        for (let i = from; i <= to; i++) {
          selectedTaskIds.add(tasks[i].task_id);
        }
        renderTaskList();
      } else if (ev.metaKey || ev.ctrlKey) {
        // Toggle selection
        if (selectedTaskIds.has(t.task_id)) selectedTaskIds.delete(t.task_id);
        else selectedTaskIds.add(t.task_id);
        lastClickedTaskIdx = taskIdx;
        renderTaskList();
      } else {
        selectedTaskIds.clear();
        lastClickedTaskIdx = taskIdx;
        selectTask(t.task_id);
      }
    });
    el.addEventListener("contextmenu", (ev) => {
      // If right-clicking a non-selected task with no multi-select, select it
      if (!selectedTaskIds.has(t.task_id) && selectedTaskIds.size === 0) {
        selectedTaskIds.add(t.task_id);
        renderTaskList();
      }
      showTaskContextMenu(ev, t.task_id, t.title);
    });
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

function readinessPip(contextReady) {
  const cls = contextReady ? "ready-yes" : "ready-no";
  const tip = contextReady ? "Ready" : "Processing…";
  return `<span class="readiness-pip ${cls}" title="${tip}"></span>`;
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

  if (taskId === "memories") {
    activeTask = null;
    await loadMemories();
    renderMidPane();
    renderRightPane();
    return;
  }

  if (taskId === "dbstats") {
    activeTask = null;
    await loadDbStats();
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

/* ── Email row helpers ── */

function buildEmailRow(e) {
  const row = document.createElement("div");
  row.className = "mh-email-row";
  row.style.position = "relative";

  const sender = (e.sender || "").replace(/<[^>]+>/g, "").trim() || e.doc_id;
  const subject = e.subject || "(no subject)";
  const date = e.date || "";

  const link = document.createElement("a");
  link.className = "email-link";
  link.href = "#";
  link.textContent = `${sender} — ${subject}${date ? " (" + date + ")" : ""}`;
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

  // Hover popup with ingested data
  let popup = null;
  let hideTimer = null;
  const showPopup = async (ev) => {
    if (hideTimer) { clearTimeout(hideTimer); hideTimer = null; }
    if (popup) return;
    popup = document.createElement("div");
    popup.className = "email-hover-popup";
    popup.textContent = "Loading…";
    document.body.appendChild(popup);
    const rect = (ev.target || link).getBoundingClientRect();
    popup.style.left = Math.max(0, rect.left + 120) + "px";
    popup.style.top = (rect.bottom + 4) + "px";
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
        lines.push("───────────");
        lines.push(detail.body_text);
      }
      popup.textContent = lines.join("\n");
    } catch (_) {
      if (popup && popup.parentNode) popup.textContent = "(no ingested data)";
    }
  };
  const keepPopup = () => {
    if (hideTimer) { clearTimeout(hideTimer); hideTimer = null; }
  };
  const dismissPopup = () => {
    hideTimer = setTimeout(() => {
      if (popup) { popup.remove(); popup = null; }
    }, 200);
  };
  const showAndWire = async (ev) => {
    await showPopup(ev);
    if (popup) {
      popup.addEventListener("mouseenter", keepPopup);
      popup.addEventListener("mouseleave", dismissPopup);
    }
  };
  link.addEventListener("mouseenter", showAndWire);
  link.addEventListener("mouseleave", dismissPopup);
  tankBtn.addEventListener("mouseenter", showAndWire);
  tankBtn.addEventListener("mouseleave", dismissPopup);

  row.appendChild(link);
  row.appendChild(tankBtn);
  return row;
}

function buildCollapsibleSection(label, emailList) {
  const section = document.createElement("div");
  section.className = "mh-email-section";

  const toggle = document.createElement("div");
  toggle.className = "mh-email-toggle";

  const triangle = document.createElement("span");
  triangle.className = "triangle";
  triangle.textContent = "▶";

  const labelSpan = document.createElement("span");
  labelSpan.textContent = label;

  toggle.appendChild(triangle);
  toggle.appendChild(labelSpan);

  const body = document.createElement("div");
  body.className = "mh-email-section-body";
  for (const e of emailList) {
    body.appendChild(buildEmailRow(e));
  }

  toggle.addEventListener("click", () => {
    triangle.classList.toggle("open");
    body.classList.toggle("open");
  });

  section.appendChild(toggle);
  section.appendChild(body);
  return section;
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
    iframe.addEventListener("load", () => notifyIframeModels());
    pane.appendChild(iframe);
    return;
  }

  // DB Stats mode
  if (activeTaskId === "dbstats") {
    renderDbStatsPane();
    return;
  }

  // Memories mode
  if (activeTaskId === "memories") {
    renderMemoriesPane();
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
    const triggerEmails = emails.filter(e => e.role === "trigger");
    const contextEmails = emails.filter(e => e.role === "context");
    const styleEmails = emails.filter(e => e.role === "style");

    const emailsDiv = document.createElement("div");
    emailsDiv.className = "mh-emails";

    // Trigger emails — always visible
    for (const e of triggerEmails) {
      emailsDiv.appendChild(buildEmailRow(e));
    }

    // Context emails — collapsible
    if (contextEmails.length) {
      emailsDiv.appendChild(buildCollapsibleSection(
        `Context emails (${contextEmails.length})`, contextEmails));
    }

    // Style emails — collapsible
    if (styleEmails.length) {
      emailsDiv.appendChild(buildCollapsibleSection(
        `Style emails (${styleEmails.length})`, styleEmails));
    }

    header.appendChild(emailsDiv);
  }

  const actions = document.createElement("div");
  actions.className = "mh-actions";
  actions.innerHTML = `
    <button id="markDoneBtn">Mark done</button>
    <button id="dismissBtn" class="danger">Dismiss</button>
    <button id="recomputeBtn">Recompute</button>
    <button id="deleteTaskBtn" class="danger">Delete</button>
  `;
  header.appendChild(actions);
  pane.appendChild(header);

  // Wire up action buttons
  header.querySelector("#markDoneBtn").addEventListener("click", () => updateTaskStatus("done"));
  header.querySelector("#dismissBtn").addEventListener("click", () => updateTaskStatus("dismissed"));
  header.querySelector("#recomputeBtn").addEventListener("click", () => bulkRecompute([activeTaskId]));
  header.querySelector("#deleteTaskBtn").addEventListener("click", () => updateTaskStatus("delete"));

  // Context readiness banner
  if (!activeTask.context_ready) {
    const banner = document.createElement("div");
    banner.className = "context-banner";
    if (activeTask.context_prefetched) {
      banner.textContent = "⏳ Waiting for email bodies to be uploaded…";
    } else {
      banner.textContent = "⏳ Selecting relevant context emails…";
    }
    pane.appendChild(banner);
  }

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
    // Debug icon for assistant messages with _llm_debug
    if (role === "assistant" && m._llm_debug) {
      const debugBtn = document.createElement("span");
      debugBtn.className = "llm-debug-icon";
      debugBtn.title = "Inspect LLM call";
      debugBtn.textContent = "\uD83D\uDD0D";
      const debugData = m._llm_debug;
      debugBtn.addEventListener("click", (ev) => {
        ev.stopPropagation();
        localStorage.setItem("llm_debug_data", JSON.stringify(debugData));
        const url = browser.runtime.getURL("ui/llm-debug.html");
        browser.tabs.create({ url });
      });
      bubble.style.position = "relative";
      bubble.appendChild(debugBtn);
    }
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

function normalizeWhitespace(text) {
  // Replace exotic Unicode spaces (narrow no-break space, thin space, etc.) with regular spaces
  return text.replace(/[\u00A0\u2002\u2003\u2004\u2005\u2006\u2007\u2008\u2009\u200A\u202F\u205F]/g, " ");
}

function stripMarkers(text) {
  let s = normalizeWhitespace(text);
  const draftPlaceholder = "*(See the draft in the right-hand pane.)*";
  // Replace [DRAFT]...[/DRAFT] blocks (closed)
  s = s.replace(/\[DRAFT[^\]]*\][\s\S]*?\[\/DRAFT\]/g, draftPlaceholder);
  // Replace unclosed [DRAFT ...] ... (to end of text)
  s = s.replace(/\[DRAFT[^\]]*\][\s\S]*/g, draftPlaceholder);
  // Remove single-line markers
  s = s.replace(/^\[SCORE [^\]]*\]\s*$/gm, "");
  s = s.replace(/^\[DEADLINE [^\]]*\]\s*$/gm, "");
  s = s.replace(/^\[TITLE [^\]]*\]\s*$/gm, "");
  s = s.replace(/^\[DESCRIPTION [^\]]*\]\s*$/gm, "");
  s = s.replace(/^\[DONE\]\s*$/gm, "");
  s = s.replace(/^\[TASK_NEW [^\]]*\]\s*$/gm, "");
  s = s.replace(/^\[LINK [^\]]*\]\s*$/gm, "");
  const hadMemory = /^\[MEMORY[\s\]]/m.test(s);
  s = s.replace(/^\[MEMORY [^\]]*\]\s*$/gm, "");
  s = s.replace(/^\[MEMORY\].*$/gm, "");
  const trimmed = s.trim();
  if (trimmed === "" && hadMemory)
    return "Thank you, your input has been recorded as a permanent memory.";
  return trimmed || text;
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
        chat_model: document.getElementById("chatModel")?.value || "",
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

/* ── Task context menu (right-click) ── */

function showTaskContextMenu(ev, taskId, title) {
  ev.preventDefault();
  dismissTaskContextMenu();

  // Determine target task IDs — multi-select or single
  const targetIds = selectedTaskIds.size > 0
    ? [...selectedTaskIds]
    : [taskId];
  const count = targetIds.length;
  const label = count > 1 ? `${count} tasks` : `"${title || taskId}"`;

  const menu = document.createElement("div");
  menu.className = "task-context-menu";
  menu.id = "taskCtxMenu";

  const addItem = (text, cls, handler) => {
    const item = document.createElement("div");
    item.className = "ctx-item" + (cls ? " " + cls : "");
    item.textContent = text;
    item.addEventListener("click", () => { dismissTaskContextMenu(); handler(); });
    menu.appendChild(item);
  };
  const addSep = () => {
    const sep = document.createElement("div");
    sep.className = "ctx-sep";
    menu.appendChild(sep);
  };

  addItem("Mark done", "", () => bulkUpdateStatus(targetIds, "done"));
  addItem("Dismiss", "", () => bulkUpdateStatus(targetIds, "dismissed"));
  addItem("Recompute", "", () => bulkRecompute(targetIds));
  addSep();
  addItem("Delete " + (count > 1 ? `${count} tasks` : "task"), "danger",
    () => bulkDeleteTasks(targetIds, label));

  menu.style.left = ev.clientX + "px";
  menu.style.top = ev.clientY + "px";
  document.body.appendChild(menu);

  // Dismiss on any click outside
  setTimeout(() => {
    document.addEventListener("click", dismissTaskContextMenu, { once: true });
  }, 0);
}

function dismissTaskContextMenu() {
  const m = document.getElementById("taskCtxMenu");
  if (m) m.remove();
}

async function deleteTask(taskId, title) {
  if (!confirm(`Delete task "${title || taskId}"? This cannot be undone.`)) return;
  try {
    const base = await getServerBase();
    await fetch(`${base}/task/delete`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ task_id: taskId }),
    });
    if (activeTaskId === taskId) {
      activeTaskId = "general";
      activeTask = null;
    }
    await loadTaskList();
    renderMidPane();
    renderRightPane();
  } catch (e) {
    console.error("[tasks.delete]", e);
    alert(`Failed to delete task: ${e.message}`);
  }
}

/* ── Bulk task actions ── */

async function bulkUpdateStatus(taskIds, newStatus) {
  // Optimistic UI update
  for (const tid of taskIds) {
    const t = tasks.find(t => t.task_id === tid);
    if (t) t.status = newStatus;
  }
  if (activeTask && taskIds.includes(activeTaskId)) activeTask.status = newStatus;
  selectedTaskIds.clear();
  renderTaskList();
  renderMidPane();

  // Fire server calls in background
  try {
    const base = await getServerBase();
    for (const tid of taskIds) {
      const resp = await fetch(`${base}/task/update`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ task_id: tid, status: newStatus }),
      });
      if (!resp.ok) throw new Error(`Server ${resp.status}`);
    }
  } catch (e) {
    console.error("[tasks.bulkUpdate]", e);
    // Revert on failure
    loadTaskList().then(() => { if (taskIds.includes(activeTaskId)) selectTask(activeTaskId); });
  }
}

async function bulkDeleteTasks(taskIds, label) {
  if (!confirm(`Delete ${label}? This cannot be undone.`)) return;
  try {
    const base = await getServerBase();
    for (const tid of taskIds) {
      await fetch(`${base}/task/delete`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ task_id: tid }),
      });
    }
    if (taskIds.includes(activeTaskId)) {
      activeTaskId = "general";
      activeTask = null;
    }
    selectedTaskIds.clear();
    await loadTaskList();
    renderMidPane();
    renderRightPane();
  } catch (e) {
    console.error("[tasks.bulkDelete]", e);
    alert(`Failed to delete tasks: ${e.message}`);
  }
}

async function bulkRecompute(taskIds) {
  try {
    const base = await getServerBase();
    for (const tid of taskIds) {
      await fetch(`${base}/task/recompute`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ task_id: tid }),
      });
    }
    selectedTaskIds.clear();
    await loadTaskList();
    if (taskIds.includes(activeTaskId)) await selectTask(activeTaskId);
  } catch (e) {
    console.error("[tasks.recompute]", e);
    alert(`Failed to recompute tasks: ${e.message}`);
  }
}

/* ── Task status update (single, from mid-pane buttons) ── */

async function updateTaskStatus(newStatus) {
  if (!activeTask) return;
  if (newStatus === "dismissed" && !confirm("Dismiss this task?")) return;
  if (newStatus === "delete") {
    return deleteTask(activeTaskId, activeTask.title);
  }

  // Optimistic UI update
  activeTask.status = newStatus;
  const tid = activeTaskId;
  const t = tasks.find(t => t.task_id === tid);
  if (t) t.status = newStatus;
  renderTaskList();
  renderMidPane();

  // Fire server call in background
  try {
    const base = await getServerBase();
    const resp = await fetch(`${base}/task/update`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ task_id: tid, status: newStatus }),
    });
    if (!resp.ok) throw new Error(`Server ${resp.status}`);
  } catch (e) {
    console.error("[tasks.update]", e);
    // Revert on failure
    loadTaskList().then(() => selectTask(tid));
  }
}

/* ── Right pane: compose form ── */

function renderRightPane() {
  const pane = document.getElementById("rightPane");

  // Hide right pane for General chat, Memories, and DB Stats
  if (activeTaskId === "general" || activeTaskId === "memories" || activeTaskId === "dbstats") {
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
    <div class="cf-row"><span class="cf-label">To:</span><input id="composeTo"></div>
    <div class="cf-row"><span class="cf-label">Cc:</span><input id="composeCc"></div>
    <div class="cf-row"><span class="cf-label">Bcc:</span><input id="composeBcc"></div>
    <div class="cf-row"><span class="cf-label">Subject:</span><input id="composeSubject"></div>
  `;
  pane.appendChild(fields);
  fields.querySelector("#composeTo").value = draft.to || "";
  fields.querySelector("#composeCc").value = draft.cc || "";
  fields.querySelector("#composeBcc").value = draft.bcc || "";
  fields.querySelector("#composeSubject").value = draft.subject || "";

  // Body — draft reply + quoted trigger email below
  const bodyDiv = document.createElement("div");
  bodyDiv.className = "compose-body";
  const ta = document.createElement("textarea");
  ta.id = "composeBody";

  // Build quoted trigger email text to show below the draft
  let quotedText = "";
  if (activeTask && draft.in_reply_to) {
    const triggerEmails = (activeTask.emails || []).filter(e => e.role === "trigger");
    // Find the trigger email matching in_reply_to, or use the first trigger
    const triggerEmail = triggerEmails.find(e => e.doc_id === draft.in_reply_to)
                      || triggerEmails[0];
    if (triggerEmail && triggerEmail.compressed_body) {
      const header = [
        triggerEmail.sender ? `From: ${triggerEmail.sender}` : "",
        triggerEmail.date ? `Date: ${triggerEmail.date}` : "",
        triggerEmail.subject ? `Subject: ${triggerEmail.subject}` : "",
      ].filter(Boolean).join("\n");
      const body = triggerEmail.compressed_body.trim();
      if (body) {
        const quoted = (header ? header + "\n\n" : "") + body;
        quotedText = "\n\n" + quoted.split("\n").map(l => "> " + l).join("\n");
      }
    }
  }

  ta.value = (draft.body || "") + quotedText;
  bodyDiv.appendChild(ta);
  pane.appendChild(bodyDiv);

  // Actions
  const actions = document.createElement("div");
  actions.className = "right-actions";
  actions.innerHTML = `
    <button id="dismissDraftBtn" class="danger">Dismiss draft</button>
    <button id="openComposeBtn">Open in Thunderbird</button>
    <button id="sendNowBtn" class="primary">Send now</button>
  `;
  pane.appendChild(actions);

  actions.querySelector("#dismissDraftBtn").addEventListener("click", () => dismissDraft(activeDraftIdx));
  actions.querySelector("#openComposeBtn").addEventListener("click", () => openInCompose(draft));
  actions.querySelector("#sendNowBtn").addEventListener("click", () => sendDraftNow(draft));
}

async function dismissDraft(idx) {
  if (!activeTask) return;
  const drafts = activeTask.drafts || [];
  if (idx < 0 || idx >= drafts.length) return;

  drafts.splice(idx, 1);
  activeDraftIdx = Math.min(activeDraftIdx, Math.max(0, drafts.length - 1));

  try {
    const base = await getServerBase();
    await fetch(`${base}/task/update`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ task_id: activeTaskId, drafts: drafts }),
    });
  } catch (e) {
    console.error("[dismissDraft]", e);
  }

  renderRightPane();
}

/* ── Send / Compose ── */

function getComposeFields(stripQuote) {
  let body = document.getElementById("composeBody")?.value || "";
  // When sending via beginReply, strip the quoted preview we appended
  // (TB will add its own proper quote from the original email)
  if (stripQuote) {
    const lines = body.split("\n");
    // Find last non-quote, non-blank line before the trailing quote block
    let cutIdx = lines.length;
    for (let i = lines.length - 1; i >= 0; i--) {
      if (lines[i].startsWith("> ") || lines[i].trim() === "") {
        cutIdx = i;
      } else {
        break;
      }
    }
    body = lines.slice(0, cutIdx).join("\n").trimEnd();
  }
  return {
    to: document.getElementById("composeTo")?.value || "",
    cc: document.getElementById("composeCc")?.value || "",
    bcc: document.getElementById("composeBcc")?.value || "",
    subject: document.getElementById("composeSubject")?.value || "",
    body,
  };
}

async function openInCompose(draft) {
  const fields = getComposeFields(false);
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
  const fields = getComposeFields(false);
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

/* ── Pane resize drag logic ── */

function setupPaneResizing() {
  function setupDivider(divider, getLeftW, setLeftW, getRightW, setRightW) {
    if (!divider) return;
    divider.addEventListener('mousedown', (e) => {
      e.preventDefault();
      e.stopPropagation();
      const startX = e.clientX;
      const startLeftW = getLeftW();
      const startRightW = getRightW();
      divider.classList.add('active');
      document.body.classList.add('resizing-cols');
      const overlay = document.createElement('div');
      overlay.className = 'resize-overlay';
      document.body.appendChild(overlay);
      function onMove(ev) {
        const dx = ev.clientX - startX;
        setLeftW(Math.max(0, startLeftW + dx));
        setRightW(Math.max(0, startRightW - dx));
      }
      function onUp() {
        overlay.remove();
        divider.classList.remove('active');
        document.body.classList.remove('resizing-cols');
        document.removeEventListener('mousemove', onMove, true);
        document.removeEventListener('mouseup', onUp, true);
      }
      document.addEventListener('mousemove', onMove, true);
      document.addEventListener('mouseup', onUp, true);
    });
  }
  const left = document.querySelector('.left-pane');
  const right = document.querySelector('.right-pane');
  setupDivider(
    document.getElementById('dividerLeft'),
    () => left.getBoundingClientRect().width,
    (w) => { left.style.width = w + 'px'; },
    () => 0,
    (_) => {}
  );
  setupDivider(
    document.getElementById('dividerRight'),
    () => 0,
    (_) => {},
    () => right.getBoundingClientRect().width,
    (w) => { right.style.width = w + 'px'; }
  );
}

/* ── Memory management (mid pane) ── */

let memories = [];
let showCreateForm = false;
let editingMemoryId = null;

async function loadMemories() {
  try {
    const base = await getServerBase();
    const resp = await fetch(`${base}/memory/list`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: "{}",
    });
    if (!resp.ok) throw new Error(`Server error: ${resp.status}`);
    const data = await resp.json();
    memories = data.memories || [];
  } catch (e) {
    console.error("[memories.list]", e);
    memories = [];
  }
}

function renderMemoriesPane() {
  const pane = document.getElementById("midPane");
  pane.innerHTML = "";
  pane.style.display = "flex";
  pane.style.flexDirection = "column";

  // Toolbar
  const toolbar = document.createElement("div");
  toolbar.className = "memory-toolbar";
  toolbar.innerHTML = `<h3>Memories</h3>`;
  const addBtn = document.createElement("button");
  addBtn.textContent = showCreateForm ? "Cancel" : "+ New memory";
  addBtn.addEventListener("click", () => {
    showCreateForm = !showCreateForm;
    editingMemoryId = null;
    renderMemoriesPane();
  });
  toolbar.appendChild(addBtn);
  pane.appendChild(toolbar);

  // Create / edit form
  if (showCreateForm || editingMemoryId) {
    const form = document.createElement("div");
    form.className = "memory-create-form";
    const ta = document.createElement("textarea");
    ta.placeholder = "Describe what to remember (e.g. 'Always reply to invoices from Acme within 2 days')";
    ta.rows = 3;
    if (editingMemoryId) {
      const mem = memories.find(m => m.memory_id === editingMemoryId);
      if (mem) ta.value = mem.text;
    }
    form.appendChild(ta);
    const actions = document.createElement("div");
    actions.className = "mcf-actions";
    const cancelBtn = document.createElement("button");
    cancelBtn.textContent = "Cancel";
    cancelBtn.addEventListener("click", () => {
      showCreateForm = false;
      editingMemoryId = null;
      renderMemoriesPane();
    });
    const saveBtn = document.createElement("button");
    saveBtn.className = "primary";
    saveBtn.textContent = editingMemoryId ? "Save" : "Create";
    saveBtn.addEventListener("click", async () => {
      const text = ta.value.trim();
      if (!text) return;
      try {
        const base = await getServerBase();
        if (editingMemoryId) {
          await fetch(`${base}/memory/update`, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ memory_id: editingMemoryId, text }),
          });
        } else {
          await fetch(`${base}/memory/create`, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ text }),
          });
        }
        showCreateForm = false;
        editingMemoryId = null;
        await loadMemories();
        renderMemoriesPane();
      } catch (e) {
        console.error("[memories.save]", e);
        alert(`Failed to save memory: ${e.message}`);
      }
    });
    actions.appendChild(cancelBtn);
    actions.appendChild(saveBtn);
    form.appendChild(actions);
    pane.appendChild(form);
  }

  // Memory list
  const list = document.createElement("div");
  list.className = "memory-list";

  if (memories.length === 0) {
    list.innerHTML = '<div class="empty-state" style="padding:20px">No memories yet. Create one above or use [MEMORY ...] in task chat.</div>';
  } else {
    for (const m of memories) {
      const card = document.createElement("div");
      card.className = "memory-card" + (m.enabled === false ? " disabled" : "");

      const textEl = document.createElement("div");
      textEl.className = "mc-text";
      textEl.textContent = m.text;
      card.appendChild(textEl);

      // Rule display
      if (m.rule && m.rule !== null) {
        const ruleEl = document.createElement("div");
        ruleEl.className = "mc-rule";
        ruleEl.textContent = typeof m.rule === "string" ? m.rule : JSON.stringify(m.rule, null, 2);
        card.appendChild(ruleEl);
      }

      const meta = document.createElement("div");
      meta.className = "mc-meta";
      const parts = [];
      if (m.memory_id) parts.push(m.memory_id);
      if (m.created_at) parts.push(m.created_at.substring(0, 16));
      if (m.enabled === false) parts.push("DISABLED");
      if (m.source_task_id) parts.push(`task: ${m.source_task_id.substring(0, 12)}`);
      meta.textContent = parts.join(" · ");
      card.appendChild(meta);

      const actions = document.createElement("div");
      actions.className = "mc-actions";

      const toggleBtn = document.createElement("button");
      toggleBtn.textContent = m.enabled === false ? "Enable" : "Disable";
      toggleBtn.addEventListener("click", async () => {
        try {
          const base = await getServerBase();
          await fetch(`${base}/memory/update`, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ memory_id: m.memory_id, enabled: !(m.enabled !== false) }),
          });
          await loadMemories();
          renderMemoriesPane();
        } catch (e) {
          console.error("[memories.toggle]", e);
        }
      });
      actions.appendChild(toggleBtn);

      const editBtn = document.createElement("button");
      editBtn.textContent = "Edit";
      editBtn.addEventListener("click", () => {
        editingMemoryId = m.memory_id;
        showCreateForm = false;
        renderMemoriesPane();
      });
      actions.appendChild(editBtn);

      const delBtn = document.createElement("button");
      delBtn.className = "danger";
      delBtn.textContent = "Delete";
      delBtn.addEventListener("click", async () => {
        if (!confirm(`Delete memory "${m.text.substring(0, 60)}..."?`)) return;
        try {
          const base = await getServerBase();
          await fetch(`${base}/memory/delete`, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ memory_id: m.memory_id }),
          });
          await loadMemories();
          renderMemoriesPane();
        } catch (e) {
          console.error("[memories.delete]", e);
          alert(`Failed to delete memory: ${e.message}`);
        }
      });
      actions.appendChild(delBtn);

      card.appendChild(actions);
      list.appendChild(card);
    }
  }

  pane.appendChild(list);
}

/* ── DB Stats (mid pane) ── */

let dbStatsData = [];

async function loadDbStats() {
  try {
    const base = await getServerBase();
    const resp = await fetch(`${base}/admin/db_stats`, { method: "GET" });
    if (!resp.ok) throw new Error(`Server error: ${resp.status}`);
    const data = await resp.json();
    dbStatsData = data.tables || [];
  } catch (e) {
    console.error("[db_stats]", e);
    dbStatsData = [];
  }
}

function renderDbStatsPane() {
  const pane = document.getElementById("midPane");
  pane.innerHTML = "";
  pane.style.display = "flex";

  const wrapper = document.createElement("div");
  wrapper.style.cssText = "padding:16px;width:100%;overflow-y:auto;";

  const header = document.createElement("h3");
  header.textContent = "Database Statistics";
  header.style.cssText = "margin:0 0 12px 0;font-size:15px;";
  wrapper.appendChild(header);

  if (dbStatsData.length === 0) {
    const empty = document.createElement("div");
    empty.style.cssText = "color:var(--muted);font-size:13px;";
    empty.textContent = "No tables found or server unavailable.";
    wrapper.appendChild(empty);
    pane.appendChild(wrapper);
    return;
  }

  // Compute total rows and prepare display
  let totalRows = 0;
  for (const t of dbStatsData) totalRows += t.rows;

  const table = document.createElement("table");
  table.style.cssText = "width:100%;border-collapse:collapse;font-size:13px;";

  // Header row
  const thead = document.createElement("thead");
  thead.innerHTML = `<tr style="border-bottom:2px solid var(--border,#ddd);text-align:left;">
    <th style="padding:6px 12px 6px 0;">Table</th>
    <th style="padding:6px 12px;text-align:right;">Rows</th>
    <th style="padding:6px 0 6px 12px;text-align:right;">Size</th>
  </tr>`;
  table.appendChild(thead);

  const tbody = document.createElement("tbody");
  for (const t of dbStatsData) {
    const tr = document.createElement("tr");
    tr.style.borderBottom = "1px solid var(--border,#eee)";
    tr.innerHTML = `
      <td style="padding:5px 12px 5px 0;font-family:monospace;font-size:12px;">${esc(t.name)}</td>
      <td style="padding:5px 12px;text-align:right;">${t.rows.toLocaleString()}</td>
      <td style="padding:5px 0 5px 12px;text-align:right;">${esc(t.size)}</td>
    `;
    tbody.appendChild(tr);
  }

  // Total row
  const totalTr = document.createElement("tr");
  totalTr.style.cssText = "border-top:2px solid var(--border,#ddd);font-weight:bold;";
  totalTr.innerHTML = `
    <td style="padding:6px 12px 6px 0;">Total</td>
    <td style="padding:6px 12px;text-align:right;">${totalRows.toLocaleString()}</td>
    <td style="padding:6px 0 6px 12px;text-align:right;"></td>
  `;
  tbody.appendChild(totalTr);

  table.appendChild(tbody);
  wrapper.appendChild(table);

  // Refresh button
  const refreshBtn = document.createElement("button");
  refreshBtn.textContent = "Refresh";
  refreshBtn.style.cssText = "margin-top:12px;font-size:12px;";
  refreshBtn.addEventListener("click", async () => {
    refreshBtn.disabled = true;
    refreshBtn.textContent = "Loading…";
    await loadDbStats();
    renderDbStatsPane();
  });
  wrapper.appendChild(refreshBtn);

  pane.appendChild(wrapper);
}

/* ── Boot ── */
setupPaneResizing();
init();
