# ThunderRAG — Thunderbird Add-on

The Thunderbird side of [ThunderRAG](../README.md): a UI layer that connects Thunderbird to the [RAG-o-Mail](../rag-o-mail/README.md) server over localhost HTTP.

## Features

- **Email ingestion** — Right-click → *Ingest selected emails*. Sends raw RFC822 to the server for parsing, triage scoring, and vector embedding.
- **Automatic ingestion** — Create a Thunderbird message filter with the *ThunderRAG* custom action to ingest emails as they arrive.
- **Chat / Q&A** — Click the toolbar button to open a chat panel. Ask natural-language questions about your email; the server retrieves relevant emails and generates answers.
- **Reply drafting** — Right-click → *Draft reply*. The LLM interviews you with short questions, then produces a complete draft you can edit, save, or send.
- **Ingestion status** — Custom column (●) in the message list shows which emails are ingested. Context menu items for de-ingesting, viewing metadata, and marking emails as processed.
- **Voice (STT / TTS)** — Server-side mic recording with speech-to-text (Whisper) and text-to-speech (Piper). Voice buttons appear in the chat UI when enabled in Preferences.
- **Settings UI** — Preferences page for configuring the server URL, top-K, voice toggles, and all RAG-o-Mail server settings (models, chunking, voice paths, prompts).

## UI Pages

| File | Purpose |
|---|---|
| `ui/query.html` / `query.js` | Chat panel (search & Q&A) |
| `ui/reply.html` / `reply.js` | Reply drafting (interview + draft) |
| `ui/options.html` / `options.js` | Settings & prompts editor |
| `ui/ingested-detail.html` / `ingested-detail.js` | Ingested email metadata viewer |

## Architecture

```
background.js          — Event handlers, ingestion queue, context menus, tab management
experiments/           — Experiment API for custom message filter action (nsIMsgFilterCustomAction)
ui/                    — All UI panels (opened as Thunderbird content tabs)
manifest.json          — Add-on manifest (permissions, experiment API registration)
```

The add-on communicates with RAG-o-Mail exclusively via HTTP:

- **Ingestion**: `POST /ingest` with `Content-Type: message/rfc822` and header `X-Thunderbird-Message-Id`
- **Queries**: `POST /query` → `POST /query/evidence` → `POST /query/complete`
- **Reply drafting**: `POST /reply/start` → `POST /reply/answer` (multi-turn)
- **Admin**: `/admin/ingested_status`, `/admin/de_ingest`, `/admin/mark_processed`, `/admin/reload`, etc.

## Install

```bash
# From the repository root:
make xpi    # produces ThunderRAG/dist/thunderRAG.xpi
```

Then in Thunderbird:

1. **Tools → Add-ons and Themes** (or `Ctrl+Shift+A`)
2. Click the gear icon → **Install Add-on From File…**
3. Select `ThunderRAG/dist/thunderRAG.xpi`

## Configuration

Open **Add-ons → ThunderRAG → Preferences**:

- **RAG-o-Mail URL** — Server address (default `http://localhost:8080`), stored locally
- **Top-K** — Number of emails to retrieve per query (default 20), stored locally
- **Server settings** — All RAG-o-Mail settings (`~/.rag-o-mail/settings.json`), edited and saved via the server's `/admin/settings` endpoint
- **Prompts** — All LLM prompts (`~/.rag-o-mail/prompts.json`), edited and saved via the server's `/admin/prompts` endpoint

## Implementation Notes

- The custom filter action is implemented via a Thunderbird **Experiment API**, registering an `nsIMsgFilterCustomAction` with `MailServices.filters.addCustomAction()`.
- For manual ("Run Now") filters, the action is async and signals completion using the provided copy listener.
- Requires Thunderbird ≥ 140.0.
