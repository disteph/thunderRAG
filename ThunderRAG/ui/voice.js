/*
  ThunderRAG Voice Module
  -----------------------
  Provides STT (Whisper.cpp) and TTS (Piper) integration for chat UIs.
  Loaded by tasks.html and query.html.

  Public API:
    Voice.init(opts)        — call once after DOM ready
    Voice.speakText(text)   — TTS: synthesize + play
    Voice.stopPlayback()    — cancel current TTS playback
    Voice.startMic(opts)    — begin STT recording with VAD
    Voice.stopMic()         — stop STT recording, return accumulated text
    Voice.isMicActive()     — true if currently recording
    Voice.getSettings()     — returns current voice settings from storage
*/

const Voice = (() => {
  /* ---- State ---- */
  let settings = {};
  let currentAudio = null;      // Audio element for TTS playback
  let activeSpeakerBtn = null;   // currently playing speaker button (for toggle)
  let micActive = false;
  let micPollTimer = null;      // polling interval for mic results
  let micSessionId = null;      // session ID for mic result exchange
  let accumulatedText = "";     // STT text accumulates here
  let onTranscript = null;      // callback(text, isFinal) — called on each Whisper result
  let onAutoSubmit = null;      // callback(text) — called when stop word detected
  let currentInputEl = null;    // textarea to write into

  /* ---- Settings ---- */

  const DEFAULTS = {
    voiceEnableSTT: false,
    voiceVADSilence: 0.7,
    voiceStopWord: "over",
    voiceEnableTTS: false,
    voiceAutoPlay: false,
  };

  const DEFAULT_SERVER_BASE = "http://localhost:8080";
  async function getServerBase() {
    try {
      const data = await browser.storage.local.get("ragServerBase");
      const url = (data.ragServerBase || "").trim();
      return url || DEFAULT_SERVER_BASE;
    } catch (_e) { return DEFAULT_SERVER_BASE; }
  }

  async function loadSettings() {
    try {
      const stored = await browser.storage.local.get(Object.keys(DEFAULTS));
      settings = {};
      for (const [k, def] of Object.entries(DEFAULTS)) {
        settings[k] = stored[k] != null ? stored[k] : def;
      }
    } catch (e) {
      console.warn("[voice] cannot load settings, using defaults", e);
      settings = { ...DEFAULTS };
    }
    return settings;
  }

  function getSettings() { return { ...settings }; }

  /* ---- TTS (Piper) ---- */

  async function speakText(text, speakerBtn) {
    if (!settings.voiceEnableTTS || !text) return;
    // If the same button is already playing, stop it (toggle)
    if (speakerBtn && speakerBtn === activeSpeakerBtn && isPlaying()) {
      stopPlayback();
      return;
    }
    stopPlayback();
    if (speakerBtn) {
      activeSpeakerBtn = speakerBtn;
      speakerBtn.textContent = "\u23F9"; // stop icon
      speakerBtn.classList.add("playing");
    }
    const url = (await getServerBase()).replace(/\/+$/, "");
    try {
      const resp = await fetch(url + "/synthesize", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ text }),
      });
      if (!resp.ok) {
        console.error("[voice.tts] HTTP", resp.status);
        notifyError("TTS server returned HTTP " + resp.status);
        resetSpeakerBtn();
        return;
      }
      const blob = await resp.blob();
      const audioUrl = URL.createObjectURL(blob);
      currentAudio = new Audio(audioUrl);
      currentAudio.addEventListener("ended", () => {
        URL.revokeObjectURL(audioUrl);
        currentAudio = null;
        resetSpeakerBtn();
      });
      currentAudio.play();
    } catch (e) {
      console.error("[voice.tts] error:", e.message);
      notifyError("TTS service unreachable: " + e.message);
      resetSpeakerBtn();
    }
  }

  function resetSpeakerBtn() {
    if (activeSpeakerBtn) {
      activeSpeakerBtn.textContent = "\uD83D\uDD0A";
      activeSpeakerBtn.classList.remove("playing");
      activeSpeakerBtn = null;
    }
  }

  function stopPlayback() {
    if (currentAudio) {
      currentAudio.pause();
      currentAudio.src = "";
      currentAudio = null;
    }
    resetSpeakerBtn();
  }

  function isPlaying() { return currentAudio !== null && !currentAudio.paused; }

  /* ---- STT via server-side mic recording (sox/rec) ---- */

  /*
    getUserMedia doesn't work in Thunderbird extension pages at all.
    Instead, the voice-server records from the system mic via sox/rec,
    does VAD, and transcribes segments with Whisper. We just call HTTP
    endpoints and poll for results.
  */
  async function startMic(opts = {}) {
    if (micActive) return;
    if (!settings.voiceEnableSTT) return;

    onTranscript = opts.onTranscript || null;
    onAutoSubmit = opts.onAutoSubmit || null;
    currentInputEl = opts.inputEl || null;
    accumulatedText = "";
    micActive = true;

    stopPlayback();

    // Generate unique session ID
    micSessionId = "s" + Date.now() + Math.random().toString(36).slice(2, 8);

    // Tell server to start recording
    const ttsBase = (await getServerBase()).replace(/\/+$/, "");
    const silence = settings.voiceVADSilence || 0.7;
    const stopWord = settings.voiceStopWord || "over";
    const startUrl = ttsBase + "/mic/start/" + micSessionId
      + "?silence=" + silence
      + "&stop_word=" + encodeURIComponent(stopWord);

    try {
      const resp = await fetch(startUrl, { method: "POST" });
      if (!resp.ok) {
        notifyError("Failed to start mic recording: HTTP " + resp.status);
        micActive = false;
        return;
      }
    } catch (e) {
      notifyError("Voice server unreachable: " + e.message);
      micActive = false;
      return;
    }

    // Poll for results every 500ms
    let lastText = "";
    micPollTimer = setInterval(async () => {
      try {
        const resp = await fetch(ttsBase + "/mic/result/" + micSessionId);
        if (!resp.ok) return;
        const data = await resp.json();

        // Update accumulated text if changed
        if (data.text && data.text !== lastText) {
          lastText = data.text;
          accumulatedText = data.text;
          if (currentInputEl) currentInputEl.value = accumulatedText;
          if (onTranscript) onTranscript(data.text, false);
        }

        // Done signal (stop word detected by server)
        if (data.done) {
          accumulatedText = data.text || "";
          if (currentInputEl) currentInputEl.value = accumulatedText;
          clearInterval(micPollTimer);
          micPollTimer = null;
          micActive = false;
          micSessionId = null;

          if (accumulatedText.trim() && onAutoSubmit) {
            onAutoSubmit(accumulatedText.trim());
          }
        }
      } catch (_e) { /* server may be briefly unavailable */ }
    }, 500);
  }

  async function stopMic() {
    if (!micActive) return accumulatedText;

    // Stop polling
    if (micPollTimer) {
      clearInterval(micPollTimer);
      micPollTimer = null;
    }

    // Tell server to stop recording and wait for final transcription
    if (micSessionId) {
      const ttsBase = (await getServerBase()).replace(/\/+$/, "");
      try {
        const resp = await fetch(ttsBase + "/mic/stop/" + micSessionId, { method: "POST" });
        if (resp.ok) {
          const data = await resp.json();
          accumulatedText = data.text || accumulatedText;
          if (currentInputEl) currentInputEl.value = accumulatedText;
        }
      } catch (_e) { /* best effort */ }
    }

    micActive = false;
    micSessionId = null;
    onTranscript = null;
    currentInputEl = null;
    return accumulatedText;
  }

  function isMicActive() { return micActive; }
  function getAccumulatedText() { return accumulatedText; }

  /* ---- Error notification ---- */

  let onError = null; // optional callback set by consumer

  function notifyError(msg) {
    console.warn("[voice]", msg);
    if (onError) onError(msg);
  }

  function setErrorHandler(fn) { onError = fn; }

  /* ---- Init ---- */

  async function init() {
    await loadSettings();
    // Re-load settings when they change
    browser.storage.onChanged.addListener((changes, area) => {
      if (area !== "local") return;
      for (const key of Object.keys(DEFAULTS)) {
        if (changes[key]) {
          settings[key] = changes[key].newValue;
        }
      }
    });
  }

  return {
    init,
    getSettings,
    loadSettings,
    speakText,
    stopPlayback,
    isPlaying,
    startMic,
    stopMic,
    isMicActive,
    getAccumulatedText,
    setErrorHandler,
  };
})();
