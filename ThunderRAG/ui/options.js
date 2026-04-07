const DEFAULT_SERVER_URL = "http://localhost:8080";
const STORAGE_KEY = "ragServerBase";
const TOPK_KEY = "ragDefaultTopK";
const DEFAULT_TOPK = 20;
const ATTACHMENT_KEYS = {
  attachmentFilterSyntax: { key: "attachmentFilterSyntax", default: "glob" },
  attachmentDefaultPath: { key: "attachmentDefaultPath", default: "~/Downloads/attachments/{{account}}/{{yyyy}}-{{mm}}/{{yyyy}}-{{mm}}-{{dd}}_{{hours}}-{{minutes}}_{{from}}" },
  attachmentLazyIgnore: { key: "attachmentLazyIgnore", default: "*.p7m\n*.p7s\n*.asc\n*.ics\nimg-*\n*.png" },
};

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

  { section: "Models — background tasks" },
  { key: "ollama.embed_model", path: ["ollama","embed_model"], label: "Embedding model", type: "model_embed",
    hint: "Used for vector search during ingestion and retrieval." },
  { key: "ollama.triage_model", path: ["ollama","triage_model"], label: "Triage model", type: "model",
    hint: "Used for propose_tasks, task_dedup, and first-message generation (all background)." },

  { section: "Models — session (overridable per tab)" },
  { key: "ollama.llm_model", path: ["ollama","llm_model"], label: "Chat / LLM model", type: "model",
    hint: "Default for task chat and general chat. Overridable via the Chat dropdown in each tab." },
  { key: "ollama.rewrite_model", path: ["ollama","rewrite_model"], label: "Query rewrite model", type: "model",
    hint: "Used for query rewriting and evidence selection. Overridable via the Rewrite dropdown." },

  { section: "Models — dual use" },
  { key: "ollama.summarize_model", path: ["ollama","summarize_model"], label: "Summarize model", type: "model",
    hint: "Used for ingestion compression (background) and evidence/session summarization (session, overridable via Summary dropdown)." },

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

function getRequestedPromptKey() {
  const params = new URLSearchParams(window.location.search);
  return (params.get("prompt") || "").trim();
}

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

  // Define schemas and models for prompts
  const promptInfo = {
    "propose_tasks_system": {
      schema: {
        type: "object",
        properties: {
          tasks: {
            type: "array",
            items: {
              type: "object",
              properties: {
                title: { type: "string" },
                description: { type: "string" },
                importance: { type: "integer" },
                deadline: { type: "string" }
              },
              required: ["title", "description"]
            }
          },
          summary: { type: "string" }
        },
        required: ["tasks"]
      },
      model: "Triage model (task generation)"
    },
    "propose_tasks_user": {
      schema: null,
      model: "Triage model (task generation)"
    },
    "task_dedup_system": {
      schema: {
        type: "object",
        properties: {
          decision: { type: "string" },
          existing_task_id: { type: "string" },
          update_description: { type: "string" },
          importance: { type: "integer" },
          deadline: { type: "string" }
        },
        required: ["decision"]
      },
      model: "Triage model (task generation)"
    },
    "task_dedup_user": {
      schema: null,
      model: "Triage model (task generation)"
    },
    "memory_rule_extract_system": {
      schema: {
        type: "object",
        properties: {
          extractable: { type: "boolean" },
          rule: { type: "object" }
        },
        required: ["extractable"]
      },
      model: "Chat / LLM model"
    },
    "memory_rule_extract_user": {
      schema: null,
      model: "Chat / LLM model"
    },
    "memory_template_gen_system": {
      schema: {
        type: "object",
        properties: {
          templates: {
            type: "array",
            items: { type: "string" }
          }
        },
        required: ["templates"]
      },
      model: "Chat / LLM model"
    },
    "memory_template_gen_user": {
      schema: null,
      model: "Chat / LLM model"
    },
    "query_rewrite_system": {
      schema: {
        type: "object",
        properties: {
          no_retrieval: { type: "boolean" },
          resolved_question: { type: "string" },
          rewrite: { type: "string" },
          hyp_from: { type: "string" },
          hyp_to: { type: "string" },
          hyp_subject: { type: "string" },
          hyp_body: { type: "string" },
          filter: { type: "string" },
          score_expr: { type: "string" }
        },
        required: ["no_retrieval", "resolved_question"]
      },
      model: "Query rewrite model"
    },
    "query_rewrite_user": {
      schema: null,
      model: "Query rewrite model"
    },
    "query_rewrite_system_extra": {
      schema: null,
      model: "Query rewrite model (template fragment)"
    },
    "select_evidence_system": {
      schema: {
        type: "object",
        properties: {
          selected: {
            type: "array",
            items: { type: "integer" }
          }
        },
        required: ["selected"]
      },
      model: "Query rewrite model"
    },
    "select_evidence_user": {
      schema: null,
      model: "Query rewrite model"
    },
    "task_first_message_system": {
      schema: null,
      model: "Triage model (task generation)"
    },
    "task_first_message_user": {
      schema: null,
      model: "Triage model (task generation)"
    },
    "task_interview_system": {
      schema: null,
      model: "Chat / LLM model"
    },
    "task_interview_user": {
      schema: null,
      model: "Chat / LLM model"
    },
    "chat": {
      schema: null,
      model: "Chat / LLM model"
    },
    "chat_question_user_suffix": {
      schema: null,
      model: "Chat / LLM model (template fragment - appended to user question)"
    },
    "conversation_summary_system": {
      schema: null,
      model: "Summarize model"
    },
    "conversation_summary_user": {
      schema: null,
      model: "Summarize model"
    },
    "task_archive_system": {
      schema: null,
      model: "Chat / LLM model"
    },
    "task_archive_user": {
      schema: null,
      model: "Chat / LLM model"
    },
    "compress_new_content_ingest": {
      schema: null,
      model: "Summarize model"
    },
    "compress_new_content_evidence": {
      schema: null,
      model: "Summarize model"
    },
    "compress_quoted_context_evidence": {
      schema: null,
      model: "Summarize model"
    },
    "compress_attachment": {
      schema: null,
      model: "Summarize model"
    }
  };

  // Group prompts by their base name (e.g., "propose_tasks_system" and "propose_tasks_user" -> "propose_tasks")
  const promptGroups = {};
  const keys = Object.keys(json);
  
  for (const key of keys) {
    if (key === "_meta") continue;
    
    // Extract base name and type
    let baseName, type;
    if (key.endsWith("_system")) {
      baseName = key.slice(0, -7);
      type = "system";
    } else if (key.endsWith("_user")) {
      baseName = key.slice(0, -5);
      type = "user";
    } else {
      baseName = key;
      type = "single";
    }
    
    if (!promptGroups[baseName]) {
      promptGroups[baseName] = {
        baseName,
        system: null,
        user: null,
        single: null,
        model: promptInfo[key]?.model || ""
      };
    }
    
    promptGroups[baseName][type] = {
      key,
      value: json[key],
      schema: promptInfo[key]?.schema
    };
  }

  // Render each prompt group
  for (const group of Object.values(promptGroups)) {
    const groupDiv = document.createElement("div");
    groupDiv.className = "prompt-group";
    groupDiv.style.cssText = `
      margin-bottom: 24px;
      padding: 16px;
      border: 1px solid var(--border);
      border-radius: 8px;
      background: var(--bg-secondary);
    `;
    
    // Group header
    const headerDiv = document.createElement("div");
    headerDiv.className = "prompt-group-header";
    headerDiv.style.cssText = `
      display: flex;
      justify-content: space-between;
      align-items: center;
      margin-bottom: 12px;
      padding-bottom: 8px;
      border-bottom: 1px solid var(--border);
    `;
    
    const titleSpan = document.createElement("span");
    titleSpan.style.cssText = `
      font-weight: 600;
      font-size: 1.1rem;
      color: var(--text);
    `;
    titleSpan.textContent = group.baseName;
    
    const modelSpan = document.createElement("span");
    modelSpan.style.cssText = `
      font-size: 0.85rem;
      color: var(--muted);
      background: var(--code-bg);
      padding: 2px 8px;
      border-radius: 4px;
    `;
    modelSpan.textContent = group.model;
    
    headerDiv.appendChild(titleSpan);
    if (group.model) {
      headerDiv.appendChild(modelSpan);
    }
    groupDiv.appendChild(headerDiv);
    
    // Collect schemas to display at the end
    const schemas = [];
    
    // Render prompts in the group
    if (group.single) {
      // Single prompt (not split)
      renderPromptField(groupDiv, group.single.key, group.single.value, null, "Single");
      if (group.single.schema) {
        schemas.push(group.single.schema);
      }
    } else {
      // Split system/user prompts
      if (group.system) {
        renderPromptField(groupDiv, group.system.key, group.system.value, null, "System");
        if (group.system.schema) {
          schemas.push(group.system.schema);
        }
      }
      if (group.user) {
        renderPromptField(groupDiv, group.user.key, group.user.value, null, "User");
        if (group.user.schema) {
          schemas.push(group.user.schema);
        }
      }
    }
    
    container.appendChild(groupDiv);
    
    // Add schemas at the end of the group
    if (schemas.length > 0) {
      const schemaDiv = document.createElement("div");
      schemaDiv.className = "json-schema";
      schemaDiv.style.cssText = `
        margin-top: 8px;
        padding: 8px;
        background: var(--code-bg);
        border: 1px solid var(--border);
        border-radius: 4px;
        font-size: 0.75rem;
        color: var(--muted);
      `;
      
      const schemaTitle = document.createElement("div");
      schemaTitle.style.cssText = `
        font-weight: 600;
        margin-bottom: 4px;
        color: var(--text);
      `;
      schemaTitle.textContent = "Output JSON Schema:";
      
      // Merge all schemas into one (for split prompts, typically only one will have a schema)
      const mergedSchema = schemas.length === 1 ? schemas[0] : {
        type: "object",
        properties: schemas.reduce((acc, schema, index) => {
          if (schema.properties) {
            Object.assign(acc, schema.properties);
          }
          return acc;
        }, {}),
        required: schemas.reduce((acc, schema) => {
          if (schema.required) {
            return acc.concat(schema.required);
          }
          return acc;
        }, [])
      };
      
      const schemaPre = document.createElement("pre");
      schemaPre.style.cssText = `
        margin: 0;
        white-space: pre-wrap;
        font-family: "SF Mono", Menlo, Consolas, monospace;
      `;
      schemaPre.textContent = JSON.stringify(mergedSchema, null, 2);
      
      schemaDiv.appendChild(schemaTitle);
      schemaDiv.appendChild(schemaPre);
      container.appendChild(schemaDiv);
    }
  }

  /* Show the _meta info at the end */
  if (json._meta && json._meta.variables) {
    const metaDiv = document.createElement("div");
    metaDiv.className = "hint";
    metaDiv.style.marginTop = "12px";
    const vars = Object.entries(json._meta.variables)
      .map(([k, v]) => `<code>${k}</code> - ${v}`)
      .join("<br/>");
    metaDiv.innerHTML = `<strong>Available template variables:</strong><br/>${vars}`;
    container.appendChild(metaDiv);
  }

  document.getElementById("prompts-btn-bar").style.display = "flex";
  clearPromptsDirty();
}

function renderPromptField(container, key, value, fieldType) {
  const text = promptValueToText(value);
  const rows = Math.max(3, Math.min(20, text.split("\n").length + 1));
  
  const fieldDiv = document.createElement("div");
  fieldDiv.className = "prompt-field";
  fieldDiv.style.cssText = `
    margin-bottom: 12px;
  `;
  
  // Field header with type label
  const headerDiv = document.createElement("div");
  headerDiv.style.cssText = `
    display: flex;
    align-items: center;
    margin-bottom: 4px;
  `;
  
  const typeLabel = document.createElement("span");
  typeLabel.style.cssText = `
    font-size: 0.75rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    padding: 2px 6px;
    border-radius: 3px;
    margin-right: 8px;
  `;
  
  if (fieldType === "System") {
    typeLabel.style.background = "#e3f2fd";
    typeLabel.style.color = "#1976d2";
  } else if (fieldType === "User") {
    typeLabel.style.background = "#f3e5f5";
    typeLabel.style.color = "#7b1fa2";
  } else {
    typeLabel.style.background = "#e8f5e8";
    typeLabel.style.color = "#388e3c";
  }
  typeLabel.textContent = fieldType;
  
  const nameLabel = document.createElement("label");
  nameLabel.style.cssText = `
    font-size: 0.9rem;
    color: var(--muted);
    font-weight: 500;
  `;
  nameLabel.htmlFor = `prompt-${key}`;
  nameLabel.textContent = key;
  
  headerDiv.appendChild(typeLabel);
  headerDiv.appendChild(nameLabel);
  fieldDiv.appendChild(headerDiv);
  
  // Textarea
  const textarea = document.createElement("textarea");
  textarea.id = `prompt-${key}`;
  textarea.textContent = text; // Use textContent to avoid HTML escaping
  textarea.rows = rows;
  textarea.style.cssText = `
    width: 100%;
    padding: 8px;
    border: 1px solid var(--border);
    border-radius: 4px;
    font-family: "SF Mono", Menlo, Consolas, monospace;
    font-size: 0.85rem;
    resize: vertical;
    background: var(--code-bg);
    color: var(--text);
  `;
  textarea.addEventListener("input", markPromptsDirty);
  fieldDiv.appendChild(textarea);
  
  container.appendChild(fieldDiv);
}

function focusPromptEditor(key) {
  if (!key) return false;
  const textarea = document.getElementById("prompt-" + key);
  if (!textarea) return false;
  textarea.scrollIntoView({ behavior: "smooth", block: "center" });
  textarea.classList.remove("prompt-flash");
  void textarea.offsetWidth;
  textarea.classList.add("prompt-flash");
  textarea.focus();
  return true;
}

async function openPromptEditor(key) {
  if (!key) return false;
  const promptsSection = document.getElementById("prompts-section");
  if (!promptsSection.open) {
    promptsSection.open = true;
  }
  if (!promptsLoaded) {
    await loadPrompts();
  }
  return await new Promise((resolve) => {
    requestAnimationFrame(() => {
      resolve(focusPromptEditor(key));
    });
  });
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

  /* ---- Attachment settings (local) ---- */
  {
    const stored = await browser.storage.local.get(Object.keys(ATTACHMENT_KEYS));
    for (const [id, spec] of Object.entries(ATTACHMENT_KEYS)) {
      const el = document.getElementById(id);
      if (!el) continue;
      const val = stored[id] != null ? stored[id] : spec.default;
      if (el.type === "checkbox") el.checked = !!val;
      else if (el.tagName === "SELECT") el.value = val;
      else el.value = val;
      const save = async () => {
        const v = el.type === "checkbox" ? el.checked : el.value;
        await browser.storage.local.set({ [id]: v });
        statusMsg("Attachment setting saved.");
      };
      el.addEventListener("change", save);
    }
  }

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
    await openPromptEditor(key);
  });

  const requestedPromptKey = getRequestedPromptKey();
  if (requestedPromptKey) {
    setTimeout(() => {
      openPromptEditor(requestedPromptKey).then((ok) => {
        if (!ok) {
          statusMsg(`Prompt not found: ${requestedPromptKey}`, true);
        }
      }).catch((e) => {
        statusMsg(`Failed to open prompt: ${e.message}`, true);
      });
    }, 0);
  }

  updateEndpointUrls(serverUrl);
  fetchAndRender();
}

init();
