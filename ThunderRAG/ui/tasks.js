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
const TASK_LIST_REFRESH_MS = 15000;
const FYI_REFRESH_MS = 5000;
const DB_STATS_REFRESH_MS = 10000;
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
let dragSourceTaskId = null;     // Task being dragged
let pauseState = { tasks_paused: false, ingest_paused: false };
let fyiEntries = [];      // Array of FYI email summaries from /fyi/list
let fyiSortAsc = false;   // Sort direction for FYI pane (false = newest first)
let selectedFyiIds = new Set();
let lastClickedFyiIdx = -1;
let activeEmailHoverPopup = null;
let dbStatsRefreshInFlight = false;

function stableJson(value) {
  try {
    return JSON.stringify(value);
  } catch (_) {
    return "";
  }
}

function formatLocalDateTime(value) {
  const s = String(value || "").trim();
  if (!s) return "";
  let normalized = s;
  if (/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}(:\d{2})?$/.test(normalized)) {
    normalized = normalized.replace(" ", "T") + "Z";
  } else if (/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2})?$/.test(normalized)) {
    normalized = normalized + "Z";
  }
  const d = new Date(normalized);
  if (Number.isNaN(d.getTime())) return s;
  return d.toLocaleString([], {
    year: "numeric",
    month: "short",
    day: "numeric",
    hour: "numeric",
    minute: "2-digit",
  });
}

function formatLocalDate(value) {
  const s = String(value || "").trim();
  if (!s) return "";
  let d;
  if (/^\d{4}-\d{2}-\d{2}$/.test(s)) {
    const [y, m, day] = s.split("-").map(Number);
    d = new Date(y, m - 1, day, 12, 0, 0);
  } else {
    let normalized = s;
    if (/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}(:\d{2})?$/.test(normalized)) {
      normalized = normalized.replace(" ", "T") + "Z";
    } else if (/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2})?$/.test(normalized)) {
      normalized = normalized + "Z";
    }
    d = new Date(normalized);
  }
  if (Number.isNaN(d.getTime())) return s;
  return d.toLocaleDateString([], {
    year: "numeric",
    month: "short",
    day: "numeric",
  });
}

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
    selectedFyiIds.clear();
    selectTask("general");
  });

  // FYI click handler
  document.getElementById("fyiItem").addEventListener("click", () => {
    selectedTaskIds.clear();
    selectedFyiIds.clear();
    selectTask("fyi");
  });

  // Title click → DB Stats
  document.getElementById("titleLink").addEventListener("click", () => {
    selectedTaskIds.clear();
    selectedFyiIds.clear();
    selectTask("dbstats");
  });

  // Memories button
  document.getElementById("memoriesBtn").addEventListener("click", () => {
    selectedTaskIds.clear();
    selectedFyiIds.clear();
    selectTask("memories");
  });

  // Pause toggle buttons
  document.getElementById("pauseTasksBtn").addEventListener("click", () => togglePause("tasks"));
  document.getElementById("pauseIngestBtn").addEventListener("click", () => togglePause("ingest"));
  await fetchPauseStatus();
  setInterval(fetchPauseStatus, 30000);

  // Initialize voice module
  if (typeof Voice !== "undefined") {
    await Voice.init();
    setupVoiceAutoPlayToggle();
  }

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
  setInterval(refreshTaskList, TASK_LIST_REFRESH_MS);
  setInterval(() => {
    if (activeTaskId === "fyi") refreshFyiPane();
  }, FYI_REFRESH_MS);
  setInterval(refreshDbStatsPane, DB_STATS_REFRESH_MS);
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
  if (activeTaskId === "fyi") {
    const changed = await loadFyiList();
    if (changed) {
      clearActiveEmailHoverPopup();
      renderMidPane();
      renderRightPane();
    }
    return;
  }
  if (activeTaskId && activeTaskId !== "general" && activeTaskId !== "memories" && activeTaskId !== "dbstats") {
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

  // Update General chat active state
  const gcEl = document.getElementById("generalChatItem");
  if (gcEl) {
    gcEl.className = "task-item" + (activeTaskId === "general" ? " active" : "");
  }
  const fyiEl = document.getElementById("fyiItem");
  if (fyiEl) {
    fyiEl.className = "task-item" + (activeTaskId === "fyi" ? " active" : "");
  }
  // Update Memories button active state
  const memBtn = document.getElementById("memoriesBtn");
  if (memBtn) {
    memBtn.className = "nav-btn" + (activeTaskId === "memories" ? " active" : "");
  }

  if (tasks.length === 0) {
    const emptyEl = document.createElement("div");
    emptyEl.className = "empty-state";
    emptyEl.style.cssText = "padding:20px;font-size:12px;";
    emptyEl.textContent = "No tasks yet";
    list.appendChild(emptyEl);
    return;
  }

  const sortBy = document.getElementById("sortBy").value;
  const draggable = sortBy === "manual" || sortBy === "deadline" || sortBy === "importance";

  for (const t of tasks) {
    const el = document.createElement("div");
    const isActive = t.task_id === activeTaskId;
    const isSelected = selectedTaskIds.has(t.task_id);
    el.className = "task-item" + (isActive ? " active" : "") + (isSelected ? " selected" : "");
    el.dataset.id = t.task_id;
    if (draggable) el.draggable = true;

    const badge = statusBadge(t.status);
    const deadline = t.deadline ? `<span style="font-size:10px;">${esc(formatLocalDate(t.deadline))}</span>` : "";
    const pip = readinessPip(t.context_ready);
    const score = t.importance_score != null ? `<span class="ti-score">${t.importance_score}</span>` : "";

    const displayTitle = (t.title || "(untitled)").replace(/^(?:Respond|Reply) to\b/i, "↩");
    el.innerHTML = `
      <div class="ti-title">${esc(displayTitle)}</div>
      <div class="ti-meta"><span class="ti-meta-left">${badge} ${pip} ${deadline}</span>${score}</div>
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

    /* ── Drag-and-drop ── */
    if (draggable) {
      el.addEventListener("dragstart", (ev) => {
        dragSourceTaskId = t.task_id;
        el.classList.add("dragging");
        ev.dataTransfer.effectAllowed = "move";
        ev.dataTransfer.setData("text/plain", t.task_id);
      });
      el.addEventListener("dragend", () => {
        dragSourceTaskId = null;
        el.classList.remove("dragging");
        clearDropIndicators();
      });
      el.addEventListener("dragover", (ev) => {
        if (!dragSourceTaskId || dragSourceTaskId === t.task_id) return;
        ev.preventDefault();
        ev.dataTransfer.dropEffect = "move";
        clearDropIndicators();
        const rect = el.getBoundingClientRect();
        const midY = rect.top + rect.height / 2;
        if (ev.clientY < midY) {
          el.classList.add("drop-above");
        } else {
          el.classList.add("drop-below");
        }
      });
      el.addEventListener("dragleave", () => {
        el.classList.remove("drop-above", "drop-below");
      });
      el.addEventListener("drop", (ev) => {
        ev.preventDefault();
        clearDropIndicators();
        if (!dragSourceTaskId || dragSourceTaskId === t.task_id) return;
        const rect = el.getBoundingClientRect();
        const midY = rect.top + rect.height / 2;
        const insertBefore = ev.clientY < midY;
        handleTaskDrop(dragSourceTaskId, t.task_id, taskIdx, insertBefore);
        dragSourceTaskId = null;
      });
    }

    list.appendChild(el);
  }
}

function clearDropIndicators() {
  for (const el of document.querySelectorAll(".task-item.drop-above, .task-item.drop-below")) {
    el.classList.remove("drop-above", "drop-below");
  }
}

async function handleTaskDrop(sourceId, targetId, targetIdx, insertBefore) {
  const sortBy = document.getElementById("sortBy").value;
  const srcIdx = tasks.findIndex(t => t.task_id === sourceId);
  if (srcIdx < 0) return;

  if (sortBy === "manual") {
    // Reorder: move source to new position in local array, then persist sort_order
    const [moved] = tasks.splice(srcIdx, 1);
    let newIdx = tasks.findIndex(t => t.task_id === targetId);
    if (newIdx < 0) newIdx = tasks.length;
    if (!insertBefore) newIdx++;
    tasks.splice(newIdx, 0, moved);
    // Assign sort_order values and persist
    const order = tasks.map((t, i) => ({ task_id: t.task_id, sort_order: i }));
    renderTaskList();
    try {
      const base = await getServerBase();
      await fetch(`${base}/task/reorder`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ order }),
      });
    } catch (e) {
      console.error("[task.reorder]", e);
    }
  } else if (sortBy === "deadline" || sortBy === "importance") {
    // Mutate the dragged task's field to match the target's
    const target = tasks[targetIdx];
    if (!target) return;
    const payload = { task_id: sourceId };
    if (sortBy === "deadline") {
      payload.deadline = target.deadline || "";
    } else {
      payload.importance_score = target.importance_score;
    }
    try {
      const base = await getServerBase();
      await fetch(`${base}/task/update`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(payload),
      });
      await loadTaskList(filterEmailIds);
    } catch (e) {
      console.error("[task.drop-mutate]", e);
    }
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
  if (taskId !== "fyi") {
    selectedFyiIds.clear();
    lastClickedFyiIdx = -1;
  }
  renderTaskList();

  if (taskId === "general") {
    activeTask = null;
    renderMidPane();
    renderRightPane();
    return;
  }

  if (taskId === "fyi") {
    activeTask = null;
    await loadFyiList();
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

async function notifyThunderRagStateChanged() {
  try {
    await browser.runtime.sendMessage({ type: "refreshThunderRagState" });
  } catch (_) {}
}

async function refreshFyiPane() {
  if (activeTaskId !== "fyi") return;
  const changed = await loadFyiList();
  if (!changed) return;
  clearActiveEmailHoverPopup();
  renderMidPane();
  renderRightPane();
}

/* ── Email row helpers ── */

function clearActiveEmailHoverPopup() {
  if (!activeEmailHoverPopup) return;
  const state = activeEmailHoverPopup;
  activeEmailHoverPopup = null;
  if (state.hideTimer) {
    clearTimeout(state.hideTimer);
    state.hideTimer = null;
  }
  if (state.popup && state.popup.parentNode) {
    state.popup.remove();
  }
  state.popup = null;
}

function attachEmailHoverPopup(targets, email) {
  const els = Array.isArray(targets) ? targets.filter(Boolean) : [targets];
  if (els.length === 0) return;
  const state = { popup: null, hideTimer: null };
  const removePopup = () => {
    if (state.hideTimer) {
      clearTimeout(state.hideTimer);
      state.hideTimer = null;
    }
    if (state.popup && state.popup.parentNode) {
      state.popup.remove();
    }
    state.popup = null;
    if (activeEmailHoverPopup === state) activeEmailHoverPopup = null;
  };
  const showPopup = async (ev) => {
    if (state.hideTimer) {
      clearTimeout(state.hideTimer);
      state.hideTimer = null;
    }
    if (state.popup) return;
    clearActiveEmailHoverPopup();
    state.popup = document.createElement("div");
    state.popup.className = "email-hover-popup";
    state.popup.textContent = "Loading…";
    state.popup.addEventListener("mouseenter", keepPopup);
    state.popup.addEventListener("mouseleave", dismissPopup);
    document.body.appendChild(state.popup);
    activeEmailHoverPopup = state;
    const rect = (ev.currentTarget || ev.target || els[0]).getBoundingClientRect();
    state.popup.style.left = Math.max(0, rect.left + 120) + "px";
    state.popup.style.top = Math.max(0, rect.top - 2) + "px";
    try {
      const base = await getServerBase();
      const resp = await fetch(`${base}/admin/email_detail`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ doc_id: email.doc_id }),
      });
      if (!resp.ok) throw new Error("not found");
      const detail = await resp.json();
      if (!detail.body_text) {
        try {
          const extracted = await browser.runtime.sendMessage({
            type: "extractBody",
            headerMessageId: email.doc_id,
            endpoint: base,
            summarize: false,
          });
          if (extracted?.body_text && String(extracted.body_text).trim()) {
            detail.body_text = String(extracted.body_text).trim();
          }
        } catch (_) {}
      }
      if (activeEmailHoverPopup !== state || !state.popup || !state.popup.parentNode) return;
      state.popup.textContent = "";
      const lines = [];
      if (detail.sender) lines.push("From: " + detail.sender);
      if (detail.recipient) lines.push("To: " + detail.recipient);
      if (detail.cc) lines.push("Cc: " + detail.cc);
      if (detail.subject) lines.push("Subject: " + detail.subject);
      if (detail.email_date) lines.push("Date: " + formatLocalDateTime(detail.email_date));
      if (detail.attachments && detail.attachments.length) lines.push("Attachments: " + detail.attachments.join(", "));
      if (detail.action_score != null) lines.push("Action: " + detail.action_score + "/100");
      if (detail.importance_score != null) lines.push("Importance: " + detail.importance_score + "/100");
      if (detail.reply_by) lines.push("Reply by: " + formatLocalDate(detail.reply_by));
      lines.push(detail.processed ? "✔ Processed" : "✗ Not processed");
      if (detail.body_text) {
        lines.push("───────────");
        lines.push(detail.body_text);
      }
      state.popup.textContent = lines.join("\n");
    } catch (_) {
      if (activeEmailHoverPopup === state && state.popup && state.popup.parentNode) {
        state.popup.textContent = "(no ingested data)";
      }
    }
  };
  const keepPopup = () => {
    if (state.hideTimer) {
      clearTimeout(state.hideTimer);
      state.hideTimer = null;
    }
  };
  const dismissPopup = () => {
    if (state.hideTimer) clearTimeout(state.hideTimer);
    state.hideTimer = setTimeout(removePopup, 200);
  };
  for (const el of els) {
    el.addEventListener("mouseenter", showPopup);
    el.addEventListener("mouseleave", dismissPopup);
  }
}

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
  if (e.role === "style") {
    link.textContent = subject;
    const recipParts = [];
    if (e.recipient) recipParts.push("To: " + e.recipient);
    if (e.cc) recipParts.push("Cc: " + e.cc);
    if (recipParts.length) link.title = recipParts.join("\n");
  } else {
    link.textContent = `${sender} — ${subject}`;
  }
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
  attachEmailHoverPopup([link, tankBtn], e);

  row.appendChild(link);
  if (date) {
    const dateSpan = document.createElement("span");
    dateSpan.className = "email-date";
    dateSpan.textContent = formatLocalDateTime(date);
    row.appendChild(dateSpan);
  }
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

function buildCollapsibleTextSection(label, text) {
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
  const pre = document.createElement("pre");
  pre.style.cssText = "font-size:11px;line-height:1.4;white-space:pre-wrap;margin:4px 0 0;opacity:0.85;";
  pre.textContent = text;
  body.appendChild(pre);

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
  clearActiveEmailHoverPopup();
  const pane = document.getElementById("midPane");
  const right = document.getElementById("rightPane");
  const dividerRight = document.getElementById("dividerRight");

  // General chat mode: embed the RAG query UI
  if (activeTaskId === "general") {
    pane.style.width = "";
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
    pane.style.width = "";
    renderDbStatsPane();
    return;
  }

  // Memories mode
  if (activeTaskId === "memories") {
    pane.style.width = "";
    renderMemoriesPane();
    return;
  }

  if (activeTaskId === "fyi") {
    if (right) right.style.display = "none";
    if (dividerRight) dividerRight.style.display = "none";
    pane.style.flex = "1";
    pane.style.width = "";
    renderFyiPane();
    return;
  }

  pane.style.flex = "1";
  pane.style.width = "";
  if (dividerRight) dividerRight.style.display = "";

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
  const titleText = document.createElement("span");
  titleText.className = "mh-title-text";
  titleText.textContent = activeTask.title || "(untitled)";
  titleEl.appendChild(titleText);
  const titleMeta = document.createElement("span");
  titleMeta.className = "mh-title-meta";
  if (activeTask.deadline) {
    const dl = document.createElement("span");
    dl.textContent = `📅 ${formatLocalDate(activeTask.deadline)}`;
    titleMeta.appendChild(dl);
  }
  if (activeTask.importance_score != null) {
    const sc = document.createElement("span");
    sc.textContent = `⚡${activeTask.importance_score}`;
    titleMeta.appendChild(sc);
  }
  if (titleMeta.childNodes.length) titleEl.appendChild(titleMeta);
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

    // Prior resolutions — collapsible
    const priorRes = (activeTask.prior_resolutions || "").trim();
    if (priorRes) {
      const count = (priorRes.match(/^---\s*\[/gm) || []).length;
      emailsDiv.appendChild(buildCollapsibleTextSection(
        `Similar resolved tasks (${count})`, priorRes));
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
    if (role === "assistant" && typeof marked !== "undefined") {
      bubble.innerHTML = marked.parse(stripMarkers(content));
    } else {
      bubble.textContent = role === "assistant" ? stripMarkers(content) : content;
    }
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
    // Speaker button for assistant messages (TTS)
    if (role === "assistant" && typeof Voice !== "undefined" && Voice.getSettings().voiceEnableTTS) {
      const speakBtn = document.createElement("button");
      speakBtn.className = "voice-speak-btn";
      speakBtn.title = "Read aloud";
      speakBtn.textContent = "\uD83D\uDD0A";
      const msgText = stripMarkers(content);
      speakBtn.addEventListener("click", (ev) => {
        ev.stopPropagation();
        Voice.speakText(stripMarkdown(msgText), speakBtn);
      });
      bubble.style.position = "relative";
      bubble.appendChild(speakBtn);
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
    const showMic = typeof Voice !== "undefined" && Voice.getSettings().voiceEnableSTT;
    composer.innerHTML = `
      <textarea id="chatInput" rows="1" placeholder="Type a message…"></textarea>
      ${showMic ? '<button class="voice-mic-btn" id="micBtn" title="Voice input">🎤</button>' : ''}
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

    // Mic button: toggle STT recording
    const micBtn = composer.querySelector("#micBtn");
    if (micBtn) {
      micBtn.addEventListener("click", () => toggleMic(micBtn, input));
    }

    requestAnimationFrame(() => input.focus());
  }
}

function normalizeWhitespace(text) {
  // Replace exotic Unicode spaces (narrow no-break space, thin space, etc.) with regular spaces
  return text.replace(/[\u00A0\u2002\u2003\u2004\u2005\u2006\u2007\u2008\u2009\u200A\u202F\u205F]/g, " ");
}

function stripMarkdown(text) {
  let s = text;
  s = s.replace(/```[\s\S]*?```/g, "");       // fenced code blocks
  s = s.replace(/`([^`]+)`/g, "$1");           // inline code
  s = s.replace(/!\[([^\]]*)\]\([^)]*\)/g, "$1"); // images
  s = s.replace(/\[([^\]]+)\]\([^)]*\)/g, "$1");  // links
  s = s.replace(/^#{1,6}\s+/gm, "");           // headings
  s = s.replace(/(\*\*|__)(.*?)\1/g, "$2");    // bold
  s = s.replace(/(\*|_)(.*?)\1/g, "$2");       // italic
  s = s.replace(/~~(.*?)~~/g, "$1");           // strikethrough
  s = s.replace(/^>\s?/gm, "");               // blockquotes
  s = s.replace(/^[-*+]\s+/gm, "");           // unordered lists
  s = s.replace(/^\d+\.\s+/gm, "");           // ordered lists
  s = s.replace(/^---+$/gm, "");              // horizontal rules
  s = s.replace(/\n{3,}/g, "\n\n");           // collapse excess newlines
  return s.trim();
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
  s = s.replace(/^\[DISMISS\]\s*$/gm, "");
  s = s.replace(/^\[DELETE\]\s*$/gm, "");
  s = s.replace(/^\[RECOMPUTE\]\s*$/gm, "");
  s = s.replace(/^\[NEXT\]\s*$/gm, "");
  s = s.replace(/^\[PREVIOUS\]\s*$/gm, "");
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

    // Auto-play TTS on the latest assistant message
    if (typeof Voice !== "undefined" && Voice.getSettings().voiceAutoPlay && activeTask?.conversation?.length) {
      const last = activeTask.conversation[activeTask.conversation.length - 1];
      if (last.role === "assistant") {
        Voice.speakText(stripMarkdown(stripMarkers(last.content)));
      }
    }

    // Process side effects
    if (data.side_effects) {
      for (const se of data.side_effects) {
        if (se.type === "task_new") {
          await loadTaskList();
        }
        if (se.type === "done" || se.type === "dismiss" || se.type === "delete") {
          // Capture the neighbor task BEFORE reloading the list
          const idx = tasks.findIndex(t => t.task_id === activeTaskId);
          const nextId = idx >= 0 && idx < tasks.length - 1 ? tasks[idx + 1].task_id
                       : idx > 0 ? tasks[idx - 1].task_id
                       : null;
          await loadTaskList();
          // If the task is gone from the (filtered) list, navigate to the neighbor
          const stillVisible = tasks.find(t => t.task_id === activeTaskId);
          if (!stillVisible) {
            const target = nextId && tasks.find(t => t.task_id === nextId);
            if (target) {
              await selectTask(target.task_id);
            } else if (tasks.length > 0) {
              await selectTask(tasks[0].task_id);
            } else {
              await selectTask("general");
            }
          }
        }
        if (se.type === "recompute") {
          // Server already reset context flags; reload task to reflect updated state
          await selectTask(activeTaskId);
        }
        if (se.type === "next") {
          const idx = tasks.findIndex(t => t.task_id === activeTaskId);
          if (idx >= 0 && idx < tasks.length - 1) {
            await selectTask(tasks[idx + 1].task_id);
          }
        }
        if (se.type === "previous") {
          const idx = tasks.findIndex(t => t.task_id === activeTaskId);
          if (idx > 0) {
            await selectTask(tasks[idx - 1].task_id);
          }
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
  const f = document.getElementById("fyiCtxMenu");
  if (f) f.remove();
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

  // If the new status is filtered out, remove affected tasks and auto-select next
  const checkedStatuses = getCheckedStatuses();
  if (checkedStatuses.length > 0 && !checkedStatuses.includes(newStatus)) {
    const removedSet = new Set(taskIds);
    const activeIdx = tasks.findIndex(t => t.task_id === activeTaskId);
    tasks = tasks.filter(t => !removedSet.has(t.task_id));
    if (removedSet.has(activeTaskId)) {
      const nextIdx = Math.min(activeIdx, tasks.length - 1);
      if (tasks.length > 0 && nextIdx >= 0) {
        selectTask(tasks[nextIdx].task_id);
      } else {
        selectTask("general");
      }
    } else {
      renderTaskList();
      renderMidPane();
    }
  } else {
    renderTaskList();
    renderMidPane();
  }

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
    const wasActive = taskIds.includes(activeTaskId);
    const activeIdx = wasActive ? tasks.findIndex(t => t.task_id === activeTaskId) : -1;
    const nextId = activeIdx >= 0 && activeIdx < tasks.length - 1 ? tasks[activeIdx + 1].task_id
                 : activeIdx > 0 ? tasks[activeIdx - 1].task_id
                 : null;
    selectedTaskIds.clear();
    await loadTaskList();
    if (wasActive) {
      const target = nextId && tasks.find(t => t.task_id === nextId);
      if (target) {
        await selectTask(target.task_id);
      } else if (tasks.length > 0) {
        await selectTask(tasks[0].task_id);
      } else {
        activeTaskId = "general";
        activeTask = null;
        renderMidPane();
        renderRightPane();
      }
    } else {
      renderMidPane();
      renderRightPane();
    }
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
  const idx = tasks.findIndex(t => t.task_id === tid);
  const t = idx >= 0 ? tasks[idx] : null;
  if (t) t.status = newStatus;

  // If the task's new status is no longer in the checked filters, select the next visible task
  const checkedStatuses = getCheckedStatuses();
  if (checkedStatuses.length > 0 && !checkedStatuses.includes(newStatus)) {
    // Remove from local list since it won't be visible
    if (idx >= 0) tasks.splice(idx, 1);
    // Select the next task (or previous if it was last)
    const nextIdx = Math.min(idx, tasks.length - 1);
    if (tasks.length > 0 && nextIdx >= 0) {
      selectTask(tasks[nextIdx].task_id);
    } else {
      selectTask("general");
    }
  } else {
    renderTaskList();
    renderMidPane();
  }

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
  const dividerRight = document.getElementById("dividerRight");

  // Hide right pane for General chat, Memories, and DB Stats
  if (activeTaskId === "general" || activeTaskId === "fyi" || activeTaskId === "memories" || activeTaskId === "dbstats") {
    pane.style.display = "none";
    if (dividerRight) dividerRight.style.display = "none";
    return;
  }
  pane.style.display = "";
  if (dividerRight) dividerRight.style.display = "";

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

async function loadFyiList() {
  const prevSignature = stableJson(fyiEntries.map((item) => ({
    doc_id: item.doc_id || "",
    summary: item.summary || "",
    date: item.date || "",
    sender: item.sender || "",
    subject: item.subject || "",
  })));
  try {
    const base = await getServerBase();
    const resp = await fetch(`${base}/fyi/list`);
    if (!resp.ok) throw new Error(`Server error: ${resp.status}`);
    const data = await resp.json();
    fyiEntries = Array.isArray(data) ? data : [];
  } catch (e) {
    console.error("[fyi.list]", e);
    fyiEntries = [];
  }
  const visibleIds = new Set(fyiEntries.map((item) => item.doc_id));
  selectedFyiIds = new Set([...selectedFyiIds].filter((id) => visibleIds.has(id)));
  if (lastClickedFyiIdx >= fyiEntries.length) lastClickedFyiIdx = fyiEntries.length - 1;
  const nextSignature = stableJson(fyiEntries.map((item) => ({
    doc_id: item.doc_id || "",
    summary: item.summary || "",
    date: item.date || "",
    sender: item.sender || "",
    subject: item.subject || "",
  })));
  return prevSignature !== nextSignature;
}

function sortFyiEntries(entries) {
  return [...entries].sort((a, b) => {
    const av = a.date || "";
    const bv = b.date || "";
    return fyiSortAsc ? av.localeCompare(bv) : bv.localeCompare(av);
  });
}

async function createTaskFromFyi(docIds, selectCreated = true) {
  try {
    const base = await getServerBase();
    const ids = Array.isArray(docIds) ? docIds : [docIds];
    let taskId = "";
    for (const docId of ids) {
      const resp = await fetch(`${base}/email/force_task`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ id: docId }),
      });
      if (!resp.ok) throw new Error(`Server error: ${resp.status}`);
      const data = await resp.json();
      if (!taskId && data.task_id) taskId = data.task_id;
    }
    selectedFyiIds = new Set([...selectedFyiIds].filter((id) => !ids.includes(id)));
    await loadFyiList();
    await loadTaskList(filterEmailIds);
    await notifyThunderRagStateChanged();
    if (selectCreated && ids.length === 1 && taskId) {
      await selectTask(taskId);
    } else {
      renderMidPane();
      renderRightPane();
    }
  } catch (e) {
    console.error("[fyi.create_task]", e);
    alert(`Failed to create task: ${e.message}`);
  }
}

async function refreshFyiAfterMutation(removedIds = []) {
  if (removedIds.length) {
    selectedFyiIds = new Set([...selectedFyiIds].filter((id) => !removedIds.includes(id)));
  }
  await loadFyiList();
  await loadTaskList(filterEmailIds);
  await notifyThunderRagStateChanged();
  renderMidPane();
  renderRightPane();
}

function getFyiItemsByIds(docIds) {
  const ids = Array.isArray(docIds) ? docIds : [docIds];
  const byId = new Map(fyiEntries.map((item) => [item.doc_id, item]));
  return ids.map((id) => byId.get(id)).filter(Boolean);
}

async function openFyiEmails(docIds) {
  try {
    const ids = Array.isArray(docIds) ? docIds : [docIds];
    for (const docId of ids) {
      await browser.runtime.sendMessage({
        type: "openMessageByHeaderMessageId",
        headerMessageId: docId,
      });
    }
  } catch (e) {
    console.error("[fyi.open_email]", e);
    alert(`Failed to open email: ${e.message}`);
  }
}

async function ingestFyiEmails(docIds) {
  try {
    const base = await getServerBase();
    const ids = Array.isArray(docIds) ? docIds : [docIds];
    for (const docId of ids) {
      const result = await browser.runtime.sendMessage({
        type: "ingestMessageByHeaderMessageId",
        headerMessageId: docId,
        endpoint: `${base}/ingest`,
      });
      if (!result?.ok) {
        throw new Error(result?.body || `Server error: ${result?.status ?? "unknown"}`);
      }
    }
    await refreshFyiAfterMutation();
  } catch (e) {
    console.error("[fyi.ingest]", e);
    alert(`Failed to ingest email: ${e.message}`);
  }
}

async function deingestFyiEmails(docIds) {
  try {
    const base = await getServerBase();
    const ids = Array.isArray(docIds) ? docIds : [docIds];
    for (const docId of ids) {
      const resp = await fetch(`${base}/admin/delete`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ id: docId }),
      });
      if (!resp.ok) throw new Error(`Server error: ${resp.status}`);
    }
    await refreshFyiAfterMutation(ids);
  } catch (e) {
    console.error("[fyi.deingest]", e);
    alert(`Failed to de-ingest email: ${e.message}`);
  }
}

async function showFyiIngestedData(docIds) {
  try {
    const base = await getServerBase();
    const items = getFyiItemsByIds(docIds);
    const msgs = items.map((item) => ({
      id: item.doc_id,
      from: item.sender || "",
      subject: item.subject || "",
      date: item.date || "",
    }));
    if (!msgs.length) return;
    const url = browser.runtime.getURL("ui/ingested-detail.html")
      + `?msgs=${encodeURIComponent(JSON.stringify(msgs))}&endpoint=${encodeURIComponent(base)}`;
    browser.tabs.create({ url });
  } catch (e) {
    console.error("[fyi.show_ingested]", e);
    alert(`Failed to show ingested data: ${e.message}`);
  }
}

async function setFyiProcessed(docIds, processed) {
  try {
    const base = await getServerBase();
    const ids = Array.isArray(docIds) ? docIds : [docIds];
    const path = processed ? "/admin/mark_processed" : "/admin/mark_unprocessed";
    for (const docId of ids) {
      const resp = await fetch(`${base}${path}`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ id: docId }),
      });
      if (!resp.ok) throw new Error(`Server error: ${resp.status}`);
    }
    await refreshFyiAfterMutation(processed ? ids : []);
  } catch (e) {
    console.error("[fyi.set_processed]", e);
    alert(`Failed to mark ${processed ? "processed" : "unprocessed"}: ${e.message}`);
  }
}

async function markFyiProcessed(docIds) {
  await setFyiProcessed(docIds, true);
}

async function markFyiUnprocessed(docIds) {
  await setFyiProcessed(docIds, false);
}

async function showTasksForFyi(docIds) {
  try {
    const ids = Array.isArray(docIds) ? docIds : [docIds];
    if (!ids.length) return;
    const url = browser.runtime.getURL("ui/tasks.html")
      + `?email_ids=${encodeURIComponent(JSON.stringify(ids))}`;
    browser.tabs.create({ url });
  } catch (e) {
    console.error("[fyi.show_tasks]", e);
    alert(`Failed to show tasks: ${e.message}`);
  }
}

async function recomputeFyiTasks(docIds) {
  try {
    const base = await getServerBase();
    const ids = Array.isArray(docIds) ? docIds : [docIds];
    for (const docId of ids) {
      const got = await browser.runtime.sendMessage({
        type: "getRawMessageByHeaderMessageId",
        headerMessageId: docId,
      });
      const raw = got?.raw || "";
      if (!raw) throw new Error(`Missing raw email for ${docId}`);
      const resp = await fetch(`${base}/email/recompute_tasks`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ doc_id: docId, raw }),
      });
      if (!resp.ok) {
        const text = await resp.text();
        throw new Error(text || `Server error: ${resp.status}`);
      }
    }
    await refreshFyiAfterMutation();
  } catch (e) {
    console.error("[fyi.recompute_tasks]", e);
    alert(`Failed to recompute tasks: ${e.message}`);
  }
}

function showFyiContextMenu(ev, docId) {
  ev.preventDefault();
  dismissTaskContextMenu();
  const targetIds = selectedFyiIds.has(docId) && selectedFyiIds.size > 0
    ? [...selectedFyiIds]
    : [docId];
  const count = targetIds.length;
  const menu = document.createElement("div");
  menu.className = "task-context-menu";
  menu.id = "fyiCtxMenu";
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
  addItem(count > 1 ? `Open ${count} emails` : "Open email", "", () => openFyiEmails(targetIds));
  addSep();
  addItem("Ingest selected emails" + (count > 1 ? ` (${count})` : ""), "", () => ingestFyiEmails(targetIds));
  addItem("De-ingest selected emails" + (count > 1 ? ` (${count})` : ""), "", () => deingestFyiEmails(targetIds));
  addItem("Show ingested data" + (count > 1 ? ` (${count})` : ""), "", () => showFyiIngestedData(targetIds));
  addSep();
  addItem("Mark processed" + (count > 1 ? ` (${count})` : ""), "", () => markFyiProcessed(targetIds));
  addItem("Mark unprocessed" + (count > 1 ? ` (${count})` : ""), "", () => markFyiUnprocessed(targetIds));
  addItem("Force task" + (count > 1 ? ` (${count})` : ""), "", () => createTaskFromFyi(targetIds, count === 1));
  addItem("Show tasks" + (count > 1 ? ` (${count})` : ""), "", () => showTasksForFyi(targetIds));
  addItem("Recompute tasks" + (count > 1 ? ` (${count})` : ""), "", () => recomputeFyiTasks(targetIds));
  menu.style.left = ev.clientX + "px";
  menu.style.top = ev.clientY + "px";
  document.body.appendChild(menu);
  setTimeout(() => {
    document.addEventListener("click", dismissTaskContextMenu, { once: true });
  }, 0);
}

function renderFyiPane() {
  const pane = document.getElementById("midPane");
  pane.innerHTML = "";
  pane.style.display = "flex";
  pane.style.flexDirection = "column";

  const toolbar = document.createElement("div");
  toolbar.className = "fyi-toolbar";
  const title = document.createElement("h3");
  title.textContent = "FYI";
  const count = document.createElement("span");
  count.className = "fyi-count";
  count.textContent = `${fyiEntries.length} unprocessed email${fyiEntries.length === 1 ? "" : "s"}`;
  const sortBtn = document.createElement("button");
  sortBtn.textContent = fyiSortAsc ? "Oldest first" : "Newest first";
  sortBtn.addEventListener("click", () => {
    fyiSortAsc = !fyiSortAsc;
    renderFyiPane();
  });
  toolbar.appendChild(title);
  toolbar.appendChild(count);
  toolbar.appendChild(sortBtn);
  pane.appendChild(toolbar);

  if (fyiEntries.length === 0) {
    const empty = document.createElement("div");
    empty.className = "empty-state";
    empty.style.padding = "24px";
    empty.textContent = "No FYI emails";
    pane.appendChild(empty);
    return;
  }

  const list = document.createElement("ul");
  list.className = "fyi-list";
  const items = sortFyiEntries(fyiEntries);
  items.forEach((item, idx) => {
    const li = document.createElement("li");
    if (selectedFyiIds.has(item.doc_id)) li.classList.add("selected");
    const text = document.createElement("div");
    text.className = "fyi-summary";
    text.textContent = item.summary || "(no summary)";
    li.appendChild(text);

    if (item.date) {
      const dateEl = document.createElement("span");
      dateEl.className = "fyi-date";
      dateEl.textContent = formatLocalDateTime(item.date);
      text.appendChild(dateEl);
    }

    li.addEventListener("click", (ev) => {
      if (ev.shiftKey && lastClickedFyiIdx >= 0) {
        const from = Math.min(lastClickedFyiIdx, idx);
        const to = Math.max(lastClickedFyiIdx, idx);
        for (let i = from; i <= to; i++) {
          selectedFyiIds.add(items[i].doc_id);
        }
      } else if (ev.metaKey || ev.ctrlKey) {
        if (selectedFyiIds.has(item.doc_id)) selectedFyiIds.delete(item.doc_id);
        else selectedFyiIds.add(item.doc_id);
        lastClickedFyiIdx = idx;
      } else {
        selectedFyiIds.clear();
        selectedFyiIds.add(item.doc_id);
        lastClickedFyiIdx = idx;
      }
      renderFyiPane();
    });

    li.addEventListener("contextmenu", (ev) => {
      if (!selectedFyiIds.has(item.doc_id)) {
        selectedFyiIds.clear();
        selectedFyiIds.add(item.doc_id);
        lastClickedFyiIdx = idx;
        renderFyiPane();
      }
      showFyiContextMenu(ev, item.doc_id);
    });

    attachEmailHoverPopup(li, item);

    const actions = document.createElement("div");
    actions.className = "fyi-actions";
    const createBtn = document.createElement("button");
    createBtn.className = "fyi-create-btn";
    createBtn.title = "Force task";
    createBtn.textContent = "Force task";
    createBtn.addEventListener("click", async (ev) => {
      ev.stopPropagation();
      await createTaskFromFyi(item.doc_id, true);
    });
    const processedBtn = document.createElement("button");
    processedBtn.className = "fyi-process-btn";
    processedBtn.title = "Mark processed";
    processedBtn.textContent = "Processed";
    processedBtn.addEventListener("click", async (ev) => {
      ev.stopPropagation();
      await markFyiProcessed(item.doc_id);
    });
    actions.appendChild(createBtn);
    actions.appendChild(processedBtn);
    li.appendChild(actions);
    list.appendChild(li);
  });
  pane.appendChild(list);
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

async function markDraftUsed() {
  if (!activeTask || !activeTask.drafts) return;
  const drafts = activeTask.drafts;
  const draft = drafts[activeDraftIdx];
  if (!draft || draft.used) return;
  draft.used = true;
  // Also capture current compose body as the version the user sent/opened
  const body = document.getElementById("composeBody")?.value || "";
  if (body.trim()) draft.body = body;
  try {
    const base = await getServerBase();
    await fetch(`${base}/task/update`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ task_id: activeTaskId, drafts: drafts }),
    });
  } catch (e) {
    console.error("[markDraftUsed]", e);
  }
}

async function openInCompose(draft) {
  const fields = getComposeFields(false);
  try {
    await markDraftUsed();
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
    await markDraftUsed();
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
let dbStatsTotalSize = "";

async function loadDbStats() {
  try {
    const base = await getServerBase();
    const resp = await fetch(`${base}/admin/db_stats`, { method: "GET" });
    if (!resp.ok) throw new Error(`Server error: ${resp.status}`);
    const data = await resp.json();
    dbStatsData = data.tables || [];
    dbStatsTotalSize = data.total_size || "";
  } catch (e) {
    console.error("[db_stats]", e);
    dbStatsData = [];
    dbStatsTotalSize = "";
  }
}

async function refreshDbStatsPane() {
  if (activeTaskId !== "dbstats" || dbStatsRefreshInFlight) return;
  dbStatsRefreshInFlight = true;
  try {
    await loadDbStats();
    if (activeTaskId === "dbstats") renderDbStatsPane();
  } finally {
    dbStatsRefreshInFlight = false;
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

  // Group tables by category
  const catMeta = {
    email:  { label: "Email (metadata & embeddings only — no bodies stored, except ingest_queue, which stores full raw RFC822 emails pending ingestion)", endpoint: "/admin/clear_rag", buttonLabel: "Clear RAG" },
    task:   { label: "Tasks (stores compressed email bodies)", endpoint: "/admin/clear_tasks", buttonLabel: "Clear Tasks" },
    memory: { label: "Memories (derived from emails)", endpoint: "/admin/clear_memories", buttonLabel: "Clear Memories" },
    other:  { label: "Other" }
  };
  const groups = {};
  let totalRows = 0;
  for (const t of dbStatsData) {
    const cat = t.category || "other";
    if (!groups[cat]) groups[cat] = [];
    groups[cat].push(t);
    totalRows += t.rows;
  }

  const table = document.createElement("table");
  table.style.cssText = "width:100%;border-collapse:collapse;font-size:13px;";
  const runAction = async (btn, endpoint, label, names) => {
    if (!endpoint) return;
    const confirmMessage =
      endpoint === "/admin/clear_rag"
        ? `MASSIVE WARNING\n\nClear RAG will permanently delete ALL stored RAG/email data from: ${names}.\n\nThis includes indexed email metadata, embeddings, pending processed markers, and related stored retrieval data.\n\nTHIS IS IRRETRIEVABLE DATA LOSS.\n\nThis cannot be undone.\n\nProceed?`
        : names
          ? `Delete ALL data from: ${names}?\n\nThis cannot be undone.`
          : "";
    if (confirmMessage && !confirm(confirmMessage)) return;
    const prev = btn.textContent;
    btn.disabled = true;
    btn.textContent = "Clearing…";
    try {
      const base = await getServerBase();
      const resp = await fetch(`${base}${endpoint}`, { method: "POST" });
      if (!resp.ok) throw new Error(`Server error: ${resp.status}`);
      await loadDbStats();
      renderDbStatsPane();
    } catch (e) {
      alert(`Error: ${e.message}`);
      btn.disabled = false;
      btn.textContent = prev || label;
    }
  };

  // Header row
  const thead = document.createElement("thead");
  thead.innerHTML = `<tr style="border-bottom:2px solid var(--border,#ddd);text-align:left;">
    <th style="padding:6px 12px 6px 0;">Table</th>
    <th style="padding:6px 12px;">Description</th>
    <th style="padding:6px 12px;text-align:right;">Rows</th>
    <th style="padding:6px 0 6px 12px;text-align:right;">Size</th>
    <th style="padding:6px 0 6px 12px;text-align:right;"></th>
  </tr>`;
  table.appendChild(thead);

  const tbody = document.createElement("tbody");
  for (const cat of ["email", "task", "memory", "other"]) {
    let rows = groups[cat];
    if (!rows || rows.length === 0) continue;
    const meta = catMeta[cat] || catMeta.other;
    if (cat === "email") {
      rows = rows.slice().sort((a, b) => {
        if (a.name === "ingest_queue") return 1;
        if (b.name === "ingest_queue") return -1;
        return 0;
      });
    }

    const catTr = document.createElement("tr");
    const catRows = rows.map(t => t.name).join(", ");
    const catHasData = rows.some(t => t.rows > 0);
    let catAction = "";
    if (meta.endpoint) {
      catAction = `<button data-endpoint="${esc(meta.endpoint)}" data-label="${esc(meta.buttonLabel || "")}" data-names="${esc(catRows)}" style="font-size:12px;color:#c00;"${catHasData ? "" : " disabled"}>${esc(meta.buttonLabel || "")}</button>`;
    }
    catTr.innerHTML = `
      <td colspan="4" style="padding:10px 12px 4px 0;font-weight:bold;font-size:12px;color:FieldText;border-bottom:1px solid var(--border,#ddd);">${esc(meta.label)}</td>
      <td style="padding:10px 0 4px 12px;text-align:right;border-bottom:1px solid var(--border,#ddd);white-space:nowrap;">${catAction}</td>
    `;
    tbody.appendChild(catTr);
    const catBtn = catTr.querySelector("button[data-endpoint]");
    if (catBtn) {
      catBtn.addEventListener("click", () =>
        runAction(catBtn, catBtn.dataset.endpoint, catBtn.dataset.label || "", catBtn.dataset.names || "")
      );
    }

    for (const t of rows) {
      const tr = document.createElement("tr");
      tr.style.borderBottom = "1px solid var(--border,#eee)";
      let rowAction = "";
      if (t.name === "ingest_queue") {
        rowAction = `<button data-endpoint="/admin/clear_ingest_queue" data-label="Clear" style="font-size:12px;color:#c00;"${t.rows > 0 ? "" : " disabled"}>Clear</button>`;
      }
      tr.innerHTML = `
        <td style="padding:5px 12px 5px 12px;font-family:monospace;font-size:12px;">${esc(t.name)}</td>
        <td style="padding:5px 12px;font-size:12px;color:var(--muted,#888);">${esc(t.description || '')}</td>
        <td style="padding:5px 12px;text-align:right;">${t.rows.toLocaleString()}</td>
        <td style="padding:5px 0 5px 12px;text-align:right;">${esc(t.size)}</td>
        <td style="padding:5px 0 5px 12px;text-align:right;white-space:nowrap;">${rowAction}</td>
      `;
      tbody.appendChild(tr);
      const rowBtn = tr.querySelector("button[data-endpoint]");
      if (rowBtn) {
        rowBtn.addEventListener("click", () =>
          runAction(rowBtn, rowBtn.dataset.endpoint, rowBtn.dataset.label || "", t.name)
        );
      }
    }
  }

  // Total row
  const totalTr = document.createElement("tr");
  totalTr.style.cssText = "border-top:2px solid var(--border,#ddd);font-weight:bold;";
  totalTr.innerHTML = `
    <td style="padding:6px 12px 6px 0;">Total</td>
    <td style="padding:6px 12px;"></td>
    <td style="padding:6px 12px;text-align:right;">${totalRows.toLocaleString()}</td>
    <td style="padding:6px 0 6px 12px;text-align:right;">${esc(dbStatsTotalSize)}</td>
    <td style="padding:6px 0 6px 12px;"></td>
  `;
  tbody.appendChild(totalTr);

  table.appendChild(tbody);
  wrapper.appendChild(table);

  const btnRow = document.createElement("div");
  btnRow.style.cssText = "margin-top:12px;display:flex;justify-content:flex-end;";

  const refreshBtn = document.createElement("button");
  refreshBtn.textContent = "Refresh";
  refreshBtn.style.cssText = "font-size:12px;";
  refreshBtn.addEventListener("click", async () => {
    refreshBtn.disabled = true;
    refreshBtn.textContent = "Loading…";
    await loadDbStats();
    renderDbStatsPane();
  });
  btnRow.appendChild(refreshBtn);

  wrapper.appendChild(btnRow);
  pane.appendChild(wrapper);
}

/* ── Pause controls ── */

async function fetchPauseStatus() {
  try {
    const base = await getServerBase();
    const resp = await fetch(`${base}/admin/pause`);
    if (!resp.ok) return;
    const data = await resp.json();
    pauseState.tasks_paused = !!data.tasks_paused;
    pauseState.ingest_paused = !!data.ingest_paused;
    updatePauseButtons();
  } catch (_e) { /* server may be down */ }
}

function updatePauseButtons() {
  const tb = document.getElementById("pauseTasksBtn");
  const ib = document.getElementById("pauseIngestBtn");
  if (tb) {
    tb.classList.toggle("paused", pauseState.tasks_paused);
    const sub = tb.querySelector(".pause-sub");
    if (sub) sub.textContent = pauseState.tasks_paused ? "off" : "on";
  }
  if (ib) {
    ib.classList.toggle("paused", pauseState.ingest_paused);
    const sub = ib.querySelector(".pause-sub");
    if (sub) sub.textContent = pauseState.ingest_paused ? "off" : "on";
  }
}

async function togglePause(which) {
  try {
    const base = await getServerBase();
    const body = {};
    if (which === "tasks") body.tasks = !pauseState.tasks_paused;
    if (which === "ingest") body.ingest = !pauseState.ingest_paused;
    const resp = await fetch(`${base}/admin/pause`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    if (!resp.ok) return;
    const data = await resp.json();
    pauseState.tasks_paused = !!data.tasks_paused;
    pauseState.ingest_paused = !!data.ingest_paused;
    updatePauseButtons();
  } catch (e) {
    console.error("[pause.toggle]", e);
  }
}

/* ── Voice helpers ── */

function toggleMic(micBtn, inputEl) {
  if (typeof Voice === "undefined") return;
  if (Voice.isMicActive()) {
    // Stop recording and submit whatever was accumulated
    Voice.stopMic().then((text) => {
      micBtn.classList.remove("recording");
      micBtn.textContent = "\uD83C\uDF99\uFE0F";
      if (text && text.trim()) {
        inputEl.value = text.trim();
        sendMessage(inputEl);
      }
    });
  } else {
    micBtn.classList.add("recording");
    micBtn.textContent = "\u23F9";
    Voice.startMic({
      inputEl,
      onTranscript: (_text, _isFinal) => {
        // Text already written to inputEl by Voice module
      },
      onAutoSubmit: (fullText) => {
        micBtn.classList.remove("recording");
        micBtn.textContent = "\uD83C\uDF99\uFE0F";
        if (fullText && fullText.trim()) {
          inputEl.value = fullText.trim();
          sendMessage(inputEl);
        }
      },
    });
  }
}

function setupVoiceAutoPlayToggle() {
  if (typeof Voice === "undefined") return;
  const s = Voice.getSettings();
  if (!s.voiceEnableTTS) return;

  const models = document.querySelector(".left-models");
  if (!models) return;

  const row = document.createElement("div");
  row.className = "model-row";
  row.style.justifyContent = "flex-start";
  row.style.gap = "6px";

  const label = document.createElement("span");
  label.className = "model-label";
  label.textContent = "TTS";

  const btn = document.createElement("button");
  btn.className = "voice-autoplay-btn" + (s.voiceAutoPlay ? " active" : "");
  btn.title = "Toggle auto-play TTS on assistant responses";
  btn.textContent = s.voiceAutoPlay ? "\uD83D\uDD0A Auto-play" : "\uD83D\uDD07 Auto-play";
  btn.addEventListener("click", async () => {
    const current = Voice.getSettings().voiceAutoPlay;
    const next = !current;
    await browser.storage.local.set({ voiceAutoPlay: next });
    btn.classList.toggle("active", next);
    btn.textContent = next ? "\uD83D\uDD0A Auto-play" : "\uD83D\uDD07 Auto-play";
  });

  row.appendChild(label);
  row.appendChild(btn);
  models.appendChild(row);
}

/* ── Boot ── */
setupPaneResizing();
init();
