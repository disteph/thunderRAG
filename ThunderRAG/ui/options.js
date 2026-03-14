const DEFAULT_SERVER_URL = "http://localhost:8080";
const STORAGE_KEY = "ragServerBase";
const TOPK_KEY = "ragDefaultTopK";
const DEFAULT_TOPK = 20;

/* Voice settings keys & defaults */
const VOICE_KEYS = {
  voiceEnableSTT:  { key: "voiceEnableSTT",  default: false },
  voiceVADSilence: { key: "voiceVADSilence",  default: 0.7 },
  voiceStopWord:   { key: "voiceStopWord",    default: "over" },
  voiceEnableTTS:  { key: "voiceEnableTTS",   default: false },
  voiceAutoPlay:   { key: "voiceAutoPlay",    default: false },
};

function normalizeUrl(s) {
  const trimmed = (s || "").trim();
  if (!trimmed) return DEFAULT_SERVER_URL;
  if (/^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(trimmed)) return trimmed.replace(/\/+$/, "");
  return ("http://" + trimmed).replace(/\/+$/, "");
}

function updateEndpointUrls(base) {
  const el1 = document.getElementById("endpointIngest");
  const el2 = document.getElementById("endpointMarkProcessed");
  if (el1) el1.textContent = base + "/ingest";
  if (el2) el2.textContent = base + "/admin/mark_processed";
}

function statusMsg(text, isError) {
  const el = document.getElementById("status");
  el.textContent = text;
  el.className = "status " + (isError ? "err" : "ok");
  if (!isError) setTimeout(() => { el.textContent = ""; }, 4000);
}

/* ---- Schema: describes every settings.json field for UI rendering ---- */
const SETTINGS_SCHEMA = [
  { section: "Identity" },
  { key: "whoami", path: ["whoami"], label: "Who am I", type: "textarea",
    hint: "Your name, email, role. Used by the LLM for triage and reply drafting." },

  { section: "Ollama" },
  { key: "ollama.base_url", path: ["ollama","base_url"], label: "Ollama base URL", type: "text" },
  { key: "ollama.num_ctx", path: ["ollama","num_ctx"], label: "Context window (tokens)", type: "number" },
  { key: "ollama.embed_model", path: ["ollama","embed_model"], label: "Embedding model", type: "model_embed" },
  { key: "ollama.llm_model", path: ["ollama","llm_model"], label: "Chat / LLM model", type: "model" },
  { key: "ollama.summarize_model", path: ["ollama","summarize_model"], label: "Summarize model", type: "model" },
  { key: "ollama.triage_model", path: ["ollama","triage_model"], label: "Triage model", type: "model" },
  { key: "ollama.rewrite_model", path: ["ollama","rewrite_model"], label: "Query rewrite model", type: "model" },

  { section: "Database" },
  { key: "pg.database", path: ["pg","database"], label: "PostgreSQL database name", type: "text" },

  { section: "RAG — chunking" },
  { key: "rag.chunk_size", path: ["rag","chunk_size"], label: "Chunk size (chars)", type: "number" },
  { key: "rag.chunk_overlap", path: ["rag","chunk_overlap"], label: "Chunk overlap (chars)", type: "number" },

  { section: "RAG — evidence" },
  { key: "rag.max_evidence_chars_per_email", path: ["rag","max_evidence_chars_per_email"], label: "Max evidence chars / email", type: "number" },

  { section: "RAG — new content" },
  { key: "rag.new_content.max_chars", path: ["rag","new_content","max_chars"], label: "Max new-content chars", type: "number" },

  { section: "RAG — summarization" },
  { key: "rag.summarize.max_input_chars", path: ["rag","summarize","max_input_chars"], label: "Max summarize input chars", type: "number" },

  { section: "RAG — quoted context" },
  { key: "rag.quoted_context.summarize", path: ["rag","quoted_context","summarize"], label: "Summarize quoted context", type: "bool" },
  { key: "rag.quoted_context.max_lines", path: ["rag","quoted_context","max_lines"], label: "Max lines", type: "number" },
  { key: "rag.quoted_context.max_chars", path: ["rag","quoted_context","max_chars"], label: "Max chars", type: "number" },
  { key: "rag.quoted_context.max_input_chars", path: ["rag","quoted_context","max_input_chars"], label: "Max input chars", type: "number" },

  { section: "RAG — attachments" },
  { key: "rag.attachments.summarize", path: ["rag","attachments","summarize"], label: "Summarize attachments", type: "bool" },
  { key: "rag.attachments.max_attachments", path: ["rag","attachments","max_attachments"], label: "Max attachments", type: "number" },
  { key: "rag.attachments.max_chars", path: ["rag","attachments","max_chars"], label: "Max chars", type: "number" },
  { key: "rag.attachments.max_input_chars", path: ["rag","attachments","max_input_chars"], label: "Max input chars", type: "number" },
  { key: "rag.attachments.max_bytes", path: ["rag","attachments","max_bytes"], label: "Max bytes", type: "number" },
  { key: "rag.attachments.use_pdftotext", path: ["rag","attachments","use_pdftotext"], label: "Use pdftotext", type: "bool" },
  { key: "rag.attachments.use_pandoc", path: ["rag","attachments","use_pandoc"], label: "Use pandoc", type: "bool" },

  { section: "RAG — query" },
  { key: "rag.query.include_unrehydrated_metadata", path: ["rag","query","include_unrehydrated_metadata"], label: "Include unrehydrated metadata", type: "bool" },
  { key: "rag.query.rewrite", path: ["rag","query","rewrite"], label: "Query rewrite", type: "bool" },

  { section: "Voice" },
  { key: "voice.piper_model", path: ["voice","piper_model"], label: "Piper TTS model path", type: "text",
    hint: "Path to .onnx voice model file (~ expanded). Leave empty to disable TTS." },
  { key: "voice.piper_bin", path: ["voice","piper_bin"], label: "Piper binary path", type: "text",
    hint: "Path to piper executable (~ expanded)." },
  { key: "voice.whisper_url", path: ["voice","whisper_url"], label: "Whisper server URL", type: "text",
    hint: "URL of the Whisper.cpp STT server." },

  { section: "Debug" },
  { key: "debug.ollama_embed", path: ["debug","ollama_embed"], label: "Debug: Ollama embed", type: "bool" },
  { key: "debug.ollama_chat", path: ["debug","ollama_chat"], label: "Debug: Ollama chat", type: "bool" },
  { key: "debug.retrieval", path: ["debug","retrieval"], label: "Debug: retrieval", type: "bool" },
];

/* Traverse nested object by key path */
function getPath(obj, path) {
  let cur = obj;
  for (const k of path) {
    if (cur == null || typeof cur !== "object") return undefined;
    cur = cur[k];
  }
  return cur;
}

/* Set a value in a nested object by key path, creating intermediates */
function setPath(obj, path, val) {
  let cur = obj;
  for (let i = 0; i < path.length - 1; i++) {
    if (cur[path[i]] == null || typeof cur[path[i]] !== "object") cur[path[i]] = {};
    cur = cur[path[i]];
  }
  cur[path[path.length - 1]] = val;
}

let currentSettings = {};
let chatModels = [];
let embedModels = [];
let allModels = [];
let settingsDirty = false;

function markSettingsDirty() {
  settingsDirty = true;
  document.getElementById("settingsDirty").textContent = "(unsaved changes)";
}

function clearSettingsDirty() {
  settingsDirty = false;
  document.getElementById("settingsDirty").textContent = "";
}

/* Collect current form values into a settings object */
function collectForm() {
  const out = {};
  for (const f of SETTINGS_SCHEMA) {
    if (f.section) continue;
    const el = document.getElementById("opt-" + f.key);
    if (!el) continue;
    let val;
    if (f.type === "bool") val = el.checked;
    else if (f.type === "number") val = parseInt(el.value, 10) || 0;
    else val = el.value;
    setPath(out, f.path, val);
  }
  return out;
}

async function saveSettingsToServer() {
  const btn = document.getElementById("saveSettingsBtn");
  btn.disabled = true;
  const base = normalizeUrl(document.getElementById("serverUrl").value);
  const patch = collectForm();
  try {
    const resp = await fetch(base + "/admin/settings", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(patch),
    });
    const data = await resp.json();
    if (data.ok) {
      if (data.settings) currentSettings = data.settings;
      /* Sync whoami to local storage for other UI pages */
      const whoami = (patch.whoami || "").trim();
      if (whoami) await browser.storage.local.set({ ragWhoAmI: whoami });
      clearSettingsDirty();
      statusMsg("Settings saved.");
    } else {
      statusMsg("Save error: " + (data.error || "unknown"), true);
    }
  } catch (e) {
    statusMsg("Cannot reach server: " + e.message, true);
  } finally {
    btn.disabled = false;
  }
}

/* Build the settings form from schema + current values */
function renderSettings(settings, models) {
  chatModels = models.models || [];
  embedModels = models.embed_models || [];
  allModels = models.all_models || models.models || [];
  currentSettings = settings;

  const container = document.getElementById("settings-container");
  container.innerHTML = "";
  container.classList.remove("loading");

  for (const f of SETTINGS_SCHEMA) {
    if (f.section) {
      const h = document.createElement("h2");
      h.textContent = f.section;
      container.appendChild(h);
      continue;
    }

    const val = getPath(settings, f.path);
    const div = document.createElement("div");
    div.className = "field";
    const id = "opt-" + f.key;

    if (f.type === "bool") {
      div.innerHTML = `<div class="field-row">
        <input type="checkbox" id="${id}" ${val ? "checked" : ""} />
        <label class="inline" for="${id}">${f.label}</label>
      </div>`;
      if (f.hint) div.innerHTML += `<div class="hint">${f.hint}</div>`;
      div.querySelector("input").addEventListener("change", markSettingsDirty);
    } else if (f.type === "model" || f.type === "model_embed") {
      const list = f.type === "model_embed" ? embedModels : chatModels;
      const opts = [...new Set([...(val ? [val] : []), ...list])];
      div.innerHTML = `<label for="${id}">${f.label}</label>
        <select id="${id}">${opts.map(m => `<option value="${m}" ${m === val ? "selected" : ""}>${m}</option>`).join("")}</select>`;
      if (f.hint) div.innerHTML += `<div class="hint">${f.hint}</div>`;
      div.querySelector("select").addEventListener("change", markSettingsDirty);
    } else if (f.type === "textarea") {
      div.innerHTML = `<label for="${id}">${f.label}</label>
        <textarea id="${id}" rows="3">${val != null ? String(val) : ""}</textarea>`;
      if (f.hint) div.innerHTML += `<div class="hint">${f.hint}</div>`;
      div.querySelector("textarea").addEventListener("input", markSettingsDirty);
    } else if (f.type === "number") {
      div.innerHTML = `<label for="${id}">${f.label}</label>
        <input type="number" id="${id}" value="${val != null ? val : ""}" />`;
      if (f.hint) div.innerHTML += `<div class="hint">${f.hint}</div>`;
      div.querySelector("input").addEventListener("input", markSettingsDirty);
    } else {
      div.innerHTML = `<label for="${id}">${f.label}</label>
        <input type="text" id="${id}" value="${val != null ? String(val) : ""}" />`;
      if (f.hint) div.innerHTML += `<div class="hint">${f.hint}</div>`;
      div.querySelector("input").addEventListener("input", markSettingsDirty);
    }

    container.appendChild(div);
  }

  /* Show the save button bar */
  document.getElementById("settings-btn-bar").style.display = "flex";
  clearSettingsDirty();
}

async function fetchAndRender() {
  const base = normalizeUrl(document.getElementById("serverUrl").value);
  try {
    const [settingsResp, modelsResp] = await Promise.all([
      fetch(base + "/admin/settings"),
      fetch(base + "/admin/models"),
    ]);
    const settingsData = await settingsResp.json();
    const models = await modelsResp.json();
    const settings = settingsData.settings || settingsData;
    renderSettings(settings, models);
    /* Sync whoami to local storage for other UI pages */
    const whoami = (settings.whoami || "").trim();
    if (whoami) await browser.storage.local.set({ ragWhoAmI: whoami });
    /* Show file paths */
    const pathEl = document.getElementById("settingsPathInfo");
    if (settingsData.path) {
      pathEl.textContent = `Reading from: ${settingsData.path}`;
      if (settingsData.default_path) pathEl.textContent += ` | Defaults: ${settingsData.default_path}`;
    }
  } catch (e) {
    const container = document.getElementById("settings-container");
    container.innerHTML = `<div style="color:var(--error); padding:20px 0;">
      Cannot reach server at <strong>${base}</strong>: ${e.message}<br/>
      Check the RAG-o-Mail URL above and ensure the server is running.</div>`;
    container.classList.remove("loading");
    document.getElementById("settings-btn-bar").style.display = "none";
    statusMsg("Server unreachable", true);
  }
}

async function resetSettingsToDefaults() {
  if (!confirm("Reset all settings to their shipped defaults? You will still need to click Save.")) return;
  const base = normalizeUrl(document.getElementById("serverUrl").value);
  try {
    const resp = await fetch(base + "/admin/settings/defaults");
    if (!resp.ok) {
      const err = await resp.json().catch(() => ({}));
      statusMsg("Cannot load defaults: " + (err.error || "HTTP " + resp.status), true);
      return;
    }
    const defaults = await resp.json();
    /* Re-render the form with default values */
    renderSettings(defaults, { models: chatModels, embed_models: embedModels, all_models: allModels });
    markSettingsDirty();
    statusMsg("Settings reset to defaults (not yet saved).");
  } catch (e) {
    statusMsg("Cannot reach server: " + e.message, true);
  }
}

/* ===== Prompts section ===== */

let promptsLoaded = false;
let promptsData = null;
let promptsDirty = false;

function markPromptsDirty() {
  promptsDirty = true;
  document.getElementById("promptsDirty").textContent = "(unsaved changes)";
}

function clearPromptsDirty() {
  promptsDirty = false;
  document.getElementById("promptsDirty").textContent = "";
}

function promptValueToText(val) {
  if (Array.isArray(val)) return val.join("\n");
  if (typeof val === "string") return val;
  if (typeof val === "object" && val !== null) return JSON.stringify(val, null, 2);
  return String(val);
}

function textToPromptValue(text) {
  if (text.includes("\n")) return text.split("\n");
  return text;
}

function renderPrompts(json) {
  promptsData = json;
  const container = document.getElementById("prompts-container");
  container.innerHTML = "";

  if (typeof json !== "object" || json === null) {
    container.textContent = "Unexpected prompts format.";
    return;
  }

  const keys = Object.keys(json);
  for (const key of keys) {
    if (key === "_meta") continue;
    const val = json[key];
    const text = promptValueToText(val);
    const rows = Math.max(3, Math.min(20, text.split("\n").length + 1));

    const div = document.createElement("div");
    div.className = "prompt-field";
    div.innerHTML = `<label for="prompt-${key}">${key}</label>
      <textarea id="prompt-${key}" rows="${rows}">${text.replace(/</g, "&lt;")}</textarea>`;
    div.querySelector("textarea").addEventListener("input", markPromptsDirty);
    container.appendChild(div);
  }

  /* Show the _meta info at the end */
  if (json._meta && json._meta.variables) {
    const metaDiv = document.createElement("div");
    metaDiv.className = "hint";
    metaDiv.style.marginTop = "12px";
    const vars = Object.entries(json._meta.variables)
      .map(([k, v]) => `<code>${k}</code> — ${v}`)
      .join("<br/>");
    metaDiv.innerHTML = `<strong>Available template variables:</strong><br/>${vars}`;
    container.appendChild(metaDiv);
  }

  document.getElementById("prompts-btn-bar").style.display = "flex";
  clearPromptsDirty();
}

async function loadPrompts() {
  const base = normalizeUrl(document.getElementById("serverUrl").value);
  const container = document.getElementById("prompts-container");
  try {
    container.textContent = "Loading prompts…";
    const resp = await fetch(base + "/admin/prompts");
    if (!resp.ok) throw new Error("HTTP " + resp.status);
    const data = await resp.json();
    const prompts = data.prompts || data;
    promptsLoaded = true;
    renderPrompts(prompts);
    /* Show file paths */
    const pathEl = document.getElementById("promptsPathInfo");
    if (data.path) {
      pathEl.textContent = `Reading from: ${data.path}`;
      if (data.default_path) pathEl.textContent += ` | Defaults: ${data.default_path}`;
    }
  } catch (e) {
    container.innerHTML = `<div style="color:var(--error);">Failed to load prompts: ${e.message}</div>`;
  }
}

async function resetPromptsToDefaults() {
  if (!confirm("Reset all prompts to their shipped defaults? You will still need to click Save.")) return;
  const base = normalizeUrl(document.getElementById("serverUrl").value);
  try {
    const resp = await fetch(base + "/admin/prompts/defaults");
    if (!resp.ok) {
      const err = await resp.json().catch(() => ({}));
      statusMsg("Cannot load default prompts: " + (err.error || "HTTP " + resp.status), true);
      return;
    }
    const defaults = await resp.json();
    renderPrompts(defaults);
    markPromptsDirty();
    statusMsg("Prompts reset to defaults (not yet saved).");
  } catch (e) {
    statusMsg("Cannot reach server: " + e.message, true);
  }
}

function collectPrompts() {
  if (!promptsData) return null;
  const out = {};
  if (promptsData._meta) out._meta = promptsData._meta;
  for (const key of Object.keys(promptsData)) {
    if (key === "_meta") continue;
    const el = document.getElementById("prompt-" + key);
    if (!el) { out[key] = promptsData[key]; continue; }
    out[key] = textToPromptValue(el.value);
  }
  return out;
}

async function savePromptsToServer() {
  const btn = document.getElementById("savePromptsBtn");
  btn.disabled = true;
  const base = normalizeUrl(document.getElementById("serverUrl").value);
  const data = collectPrompts();
  if (!data) { btn.disabled = false; return; }
  try {
    const resp = await fetch(base + "/admin/prompts", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(data),
    });
    const result = await resp.json();
    if (result.ok) {
      clearPromptsDirty();
      statusMsg("Prompts saved.");
    } else {
      statusMsg("Prompts save error: " + (result.error || "unknown"), true);
    }
  } catch (e) {
    statusMsg("Cannot reach server: " + e.message, true);
  } finally {
    btn.disabled = false;
  }
}

/* ===== Initialization ===== */

async function init() {
  const data = await browser.storage.local.get(STORAGE_KEY);
  const serverUrl = data[STORAGE_KEY] || DEFAULT_SERVER_URL;
  document.getElementById("serverUrl").value = serverUrl;

  /* ---- Add-on local fields ---- */

  /* Server URL: save locally on change, then reload settings */
  const urlInput = document.getElementById("serverUrl");
  let urlSaveTimer = null;
  const onUrlChange = () => {
    clearTimeout(urlSaveTimer);
    urlSaveTimer = setTimeout(async () => {
      const url = normalizeUrl(urlInput.value);
      urlInput.value = url;
      await browser.storage.local.set({ [STORAGE_KEY]: url });
      updateEndpointUrls(url);
      statusMsg("Server URL saved. Reloading…");
      fetchAndRender();
      if (promptsLoaded) loadPrompts();
    }, 500);
  };
  urlInput.addEventListener("change", onUrlChange);
  urlInput.addEventListener("keydown", (e) => {
    if (e.key === "Enter") { e.preventDefault(); onUrlChange(); }
  });

  /* Top-K: save locally on change */
  const topKInput = document.getElementById("localTopK");
  const topKData = await browser.storage.local.get(TOPK_KEY);
  topKInput.value = topKData[TOPK_KEY] || DEFAULT_TOPK;
  topKInput.addEventListener("change", async () => {
    const v = Math.max(1, Math.min(50, parseInt(topKInput.value, 10) || DEFAULT_TOPK));
    topKInput.value = v;
    await browser.storage.local.set({ [TOPK_KEY]: v });
    statusMsg("Top-K saved locally.");
  });

  /* ---- Voice settings (local) ---- */
  {
    const stored = await browser.storage.local.get(Object.keys(VOICE_KEYS));
    for (const [id, spec] of Object.entries(VOICE_KEYS)) {
      const el = document.getElementById(id);
      if (!el) continue;
      const val = stored[id] != null ? stored[id] : spec.default;
      if (el.type === "checkbox") el.checked = !!val;
      else el.value = val;
      const save = async () => {
        let v;
        if (el.type === "checkbox") v = el.checked;
        else if (el.type === "number") v = parseFloat(el.value) || spec.default;
        else v = el.value;
        await browser.storage.local.set({ [id]: v });
        statusMsg("Voice setting saved.");
      };
      el.addEventListener("change", save);
    }
  }

  /* ---- Server-side settings & prompts ---- */

  /* Save / Reset settings buttons */
  document.getElementById("saveSettingsBtn").addEventListener("click", saveSettingsToServer);
  document.getElementById("resetSettingsBtn").addEventListener("click", resetSettingsToDefaults);

  /* Prompts: load on first expand */
  document.getElementById("prompts-section").addEventListener("toggle", (e) => {
    if (e.target.open && !promptsLoaded) loadPrompts();
  });
  document.getElementById("savePromptsBtn").addEventListener("click", savePromptsToServer);
  document.getElementById("resetPromptsBtn").addEventListener("click", resetPromptsToDefaults);

  /* ---- Pipeline prompt-tag click → scroll to prompt editor ---- */
  document.getElementById("pipelines-section").addEventListener("click", async (e) => {
    const tag = e.target.closest(".pl-prompt-tag[data-prompt]");
    if (!tag) return;
    const key = tag.dataset.prompt;
    if (!key) return;

    /* 1. Open the Prompts section */
    const promptsSection = document.getElementById("prompts-section");
    if (!promptsSection.open) {
      promptsSection.open = true;
      /* If prompts haven't loaded yet, load them now */
      if (!promptsLoaded) {
        await loadPrompts();
      }
    }

    /* 2. Wait a tick for rendering, then scroll to the textarea */
    requestAnimationFrame(() => {
      const textarea = document.getElementById("prompt-" + key);
      if (textarea) {
        textarea.scrollIntoView({ behavior: "smooth", block: "center" });
        textarea.classList.remove("prompt-flash");
        void textarea.offsetWidth; /* force reflow to restart animation */
        textarea.classList.add("prompt-flash");
        textarea.focus();
      }
    });
  });

  updateEndpointUrls(serverUrl);
  fetchAndRender();
}

init();
