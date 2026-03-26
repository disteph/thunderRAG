"use strict";

(function () {
  const container = document.getElementById("content");

  // Read debug data from sessionStorage
  const raw = localStorage.getItem("llm_debug_data");
  if (!raw) {
    container.innerHTML = '<div class="empty-state">No debug data found. Click the debug icon from a conversation message.</div>';
    return;
  }

  let data;
  try {
    data = JSON.parse(raw);
  } catch (e) {
    container.innerHTML = `<div class="empty-state">Failed to parse debug data: ${e.message}</div>`;
    return;
  }

  // Clear after reading
  localStorage.removeItem("llm_debug_data");

  container.innerHTML = "";

  // --- Meta info ---
  if (data.model || data.label) {
    const meta = document.createElement("div");
    meta.className = "meta";
    let parts = [];
    if (data.model) parts.push(`<span><span class="label">Model:</span> ${esc(data.model)}</span>`);
    if (data.label) parts.push(`<span><span class="label">Label:</span> ${esc(data.label)}</span>`);
    meta.innerHTML = parts.join("");
    container.appendChild(meta);
  }

  // --- Request messages ---
  const messages = data.messages || [];
  if (messages.length > 0) {
    const promptKey = String(data.prompt_key || "").trim();
    const header = document.createElement("div");
    header.className = "section-header";

    const h2 = document.createElement("h2");
    h2.textContent = `Request Messages (${messages.length})`;
    header.appendChild(h2);

    if (promptKey) {
      const sourceLink = document.createElement("a");
      sourceLink.href = "#";
      sourceLink.className = "source-link";
      sourceLink.textContent = "Source code";
      sourceLink.addEventListener("click", async (ev) => {
        ev.preventDefault();
        const url = browser.runtime.getURL(`ui/options.html?prompt=${encodeURIComponent(promptKey)}`);
        await browser.tabs.create({ url });
      });
      header.appendChild(sourceLink);
    }

    container.appendChild(header);

    const copyReqBtn = document.createElement("button");
    copyReqBtn.className = "copy-btn";
    copyReqBtn.textContent = "Copy full request JSON";
    copyReqBtn.addEventListener("click", () => {
      // Build the full ollama request body
      const reqBody = {
        model: data.model || "",
        messages: messages,
        stream: false,
        options: data.options || {},
      };
      navigator.clipboard.writeText(JSON.stringify(reqBody, null, 2)).then(() => {
        copyReqBtn.textContent = "Copied!";
        setTimeout(() => { copyReqBtn.textContent = "Copy full request JSON"; }, 1500);
      });
    });
    container.appendChild(copyReqBtn);

    for (let i = 0; i < messages.length; i++) {
      const msg = messages[i];
      const role = msg.role || "unknown";
      const content = msg.content || "";
      const charCount = content.length;
      const isLong = charCount > 500;

      const div = document.createElement("div");
      div.className = `message ${role}`;

      const roleEl = document.createElement("div");
      roleEl.className = "role";
      roleEl.innerHTML = `${esc(role)} <span class="char-count">(${charCount.toLocaleString()} chars)</span>`;
      div.appendChild(roleEl);

      const contentEl = document.createElement("div");
      contentEl.className = "content" + (isLong ? " collapsed" : "");
      contentEl.textContent = content;
      div.appendChild(contentEl);

      if (isLong) {
        const btn = document.createElement("button");
        btn.className = "toggle-btn";
        btn.textContent = "Expand";
        btn.addEventListener("click", () => {
          const collapsed = contentEl.classList.toggle("collapsed");
          btn.textContent = collapsed ? "Expand" : "Collapse";
        });
        div.appendChild(btn);
      }

      container.appendChild(div);
    }
  }

  // --- Raw response ---
  const rawResp = data.raw_response || "";
  if (rawResp) {
    const h2 = document.createElement("h2");
    h2.innerHTML = `Raw LLM Response <span class="char-count">(${rawResp.length.toLocaleString()} chars)</span>`;
    container.appendChild(h2);

    const copyBtn = document.createElement("button");
    copyBtn.className = "copy-btn";
    copyBtn.textContent = "Copy response";
    copyBtn.addEventListener("click", () => {
      navigator.clipboard.writeText(rawResp).then(() => {
        copyBtn.textContent = "Copied!";
        setTimeout(() => { copyBtn.textContent = "Copy response"; }, 1500);
      });
    });
    container.appendChild(copyBtn);

    const section = document.createElement("div");
    section.className = "section";
    const pre = document.createElement("div");
    pre.className = "raw-response";
    pre.textContent = rawResp;
    section.appendChild(pre);
    container.appendChild(section);
  }

  function esc(s) {
    const d = document.createElement("div");
    d.textContent = s;
    return d.innerHTML;
  }
})();
