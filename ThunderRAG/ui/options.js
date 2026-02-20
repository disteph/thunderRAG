const DEFAULT_SERVER_URL = "http://localhost:8080";
const STORAGE_KEY = "ragServerBase";
const WHOAMI_KEY = "ragWhoAmI";
const TOPK_KEY = "ragDefaultTopK";
const DEFAULT_TOPK = 20;

function normalizeUrl(s) {
  const trimmed = (s || "").trim();
  if (!trimmed) return DEFAULT_SERVER_URL;
  if (/^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(trimmed)) {
    return trimmed.replace(/\/+$/, "");
  }
  return ("http://" + trimmed).replace(/\/+$/, "");
}

async function load() {
  const data = await browser.storage.local.get([STORAGE_KEY, WHOAMI_KEY, TOPK_KEY]);
  document.getElementById("serverUrl").value = data[STORAGE_KEY] || DEFAULT_SERVER_URL;
  document.getElementById("whoAmI").value = data[WHOAMI_KEY] || "";
  document.getElementById("defaultTopK").value = data[TOPK_KEY] || DEFAULT_TOPK;
}

async function save() {
  const raw = document.getElementById("serverUrl").value;
  const url = normalizeUrl(raw);
  document.getElementById("serverUrl").value = url;
  const whoami = document.getElementById("whoAmI").value;
  const topK = Math.max(1, Math.min(50, parseInt(document.getElementById("defaultTopK").value, 10) || DEFAULT_TOPK));
  document.getElementById("defaultTopK").value = topK;
  await browser.storage.local.set({ [STORAGE_KEY]: url, [WHOAMI_KEY]: whoami, [TOPK_KEY]: topK });

  const el = document.getElementById("status");
  el.textContent = "Saved.";
  setTimeout(() => { el.textContent = ""; }, 2000);
}

document.getElementById("serverUrl").addEventListener("change", save);
document.getElementById("serverUrl").addEventListener("keydown", (e) => {
  if (e.key === "Enter") {
    e.preventDefault();
    save();
  }
});
document.getElementById("whoAmI").addEventListener("change", save);
document.getElementById("whoAmI").addEventListener("input", save);
document.getElementById("defaultTopK").addEventListener("change", save);
document.getElementById("defaultTopK").addEventListener("input", save);

load();
