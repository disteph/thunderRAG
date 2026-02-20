# ThunderRAG OCaml Server

The OCaml server is the **central orchestrator** of the ThunderRAG system. It sits between the Thunderbird add-on (which provides raw email content) and the python-engine (which owns the FAISS vector index), and it is the only component that talks to the LLM (Ollama).

## Architecture Overview

```
Thunderbird Add-on ──── raw RFC822 ────▸ OCaml Server ──── embeddings ────▸ python-engine
        │                                    │                                   │
        │  (browser.messages.getRaw)         │  (Ollama /api/embeddings)         │  (FAISS + SQLite)
        │                                    │  (Ollama /api/chat)               │
        ▼                                    ▼                                   ▼
   Source of truth              Orchestrator / prompt builder          Vector index + metadata
   for email content            Session state + conversation          Chunk-level retrieval
                                management
```

**Key design principle**: The OCaml server never stores email bodies. Thunderbird is the source of truth. During queries, the UI asks Thunderbird to fetch and upload evidence on demand.

## HTTP Endpoints

### Ingestion

#### `POST /ingest`

Accepts a single raw RFC822 email message for ingestion into the vector index.

- **Content-Type**: `message/rfc822`
- **Header**: `X-Thunderbird-Message-Id` — the RFC822 Message-Id used as the stable `doc_id`
- **Process**:
  1. Parse MIME structure (multipart boundaries, transfer encodings)
  2. Extract text: prefer `text/plain`, fall back to `text/html` → strip tags via lambdasoup
  3. Split into new content vs quoted thread context
  4. Optionally summarize quoted context and attachments via Ollama
  5. Build `text_for_index` (From/To/Cc/Bcc/Subject/Date + body)
  6. Chunk text, embed each chunk via Ollama `/api/embeddings`
  7. Forward embeddings + metadata to python-engine `/ingest_embedded`
- **Response**: JSON `{ "status": "ok", "chunks_ingested": N }` or error

#### `POST /admin/bulk_ingest`

Scans local mbox files and ingests all messages. Used for initial corpus loading.

- **Body**: JSON `{ "paths": ["/path/to/Mail/..."], "recursive": true, "concurrency": 4, "max_messages": 0 }`
- **Process**: Splits mbox files into individual messages, ingests each via the same pipeline as `/ingest`
- **Response**: JSON with progress stats (total scanned, ingested, skipped, failed)

### Query (2-Phase Flow)

The query flow is split into three steps so that Thunderbird (not the server) fetches full email bodies. This avoids storing email content server-side.

#### Phase 1: `POST /query`

Retrieval only — does **not** call Ollama chat.

- **Body**: JSON `{ "session_id": "...", "question": "...", "top_k": 8, "mode": "assistive" }`
- **Process**:
  1. Embed the question via Ollama `/api/embeddings`
  2. Query python-engine `/query_embedded` for top-K similar documents
  3. Generate a `request_id` and store a pending query entry
- **Response**: JSON:
  ```json
  {
    "status": "need_messages",
    "request_id": "...",
    "message_ids": ["<msg1@example.com>", "<msg2@example.com>", ...],
    "sources": [{ "doc_id": "...", "metadata": {...}, "score": 0.85 }, ...]
  }
  ```

#### Phase 2: `POST /query/evidence`

Thunderbird uploads raw RFC822 for each message_id returned by Phase 1.

- **Content-Type**: `message/rfc822`
- **Headers**:
  - `X-RAG-Request-Id` — correlates with the `request_id` from Phase 1
  - `X-Thunderbird-Message-Id` — which message this evidence is for
- **Response**: JSON `{ "status": "ok" }`

#### Phase 3: `POST /query/complete`

Final answer generation.

- **Body**: JSON `{ "session_id": "...", "request_id": "..." }`
- **Process**:
  1. Verify all expected evidence has been uploaded
  2. Re-extract normalized text from each raw email (same pipeline as ingestion)
  3. Build the final prompt:
     - System instructions + current timestamp
     - Session summaries (history, sources) for multi-turn context
     - Recent conversation tail (up to 24 turns)
     - User question
     - SOURCES INDEX (compact date/from/subject for recency reasoning)
     - RETRIEVED EMAILS (full evidence text)
     - Final citation instruction
  4. Call Ollama `/api/chat`
  5. Update session state (tail, summaries)
- **Response**: JSON `{ "answer": "...", "sources": [...] }`

### Admin / Maintenance

| Endpoint | Method | Description |
|---|---|---|
| `/admin/delete` | POST | Delete a doc_id from the vector index (proxied to python-engine) |
| `/admin/reset` | POST | Hard reset: wipe the entire vector index (proxied to python-engine) |
| `/admin/session/debug` | POST | Dump session state (tail, summaries) for debugging |
| `/admin/session/reset` | POST | Clear a session's conversation history |
| `/admin/bulk_state/reset` | POST | Clear the bulk ingestion progress state file |

## Module Structure

```
ocaml-server/
├── bin/
│   └── main.ml              # HTTP server, Ollama integration, session state,
│                             # ingestion pipeline, query orchestration, bulk ingest
├── lib/
│   ├── config.ml             # Environment variables, settings.json loading, all config values
│   ├── text_util.ml          # Text normalization: UTF-8 sanitization (Uutf), RFC2047 decoding
│   │                         # (mrmime), base64 (Base64 lib), quoted-printable (Pecu),
│   │                         # percent-decode (Uri), chunking, L2 normalization
│   ├── html.ml               # HTML→text: entity decoding, markup detection, tag stripping
│   │                         # (all via lambdasoup)
│   ├── mime.ml               # MIME parsing: header extraction, multipart boundary splitting,
│   │                         # leaf part collection, attachment filename extraction
│   ├── body_extract.ml       # Email body extraction: new vs quoted text splitting,
│   │                         # mrmime streaming parser with simple-MIME fallback
│   └── dune                  # Library dependencies: uri lambdasoup yojson unix mrmime
│                             # angstrom base64 pecu uutf
├── bin/dune                  # Executable dependencies: rag_lib + eio cohttp-eio
└── rag_email_server.opam     # Package metadata
```

## Configuration

All configuration is via environment variables (with fallbacks to `~/.thunderrag/settings.json`).

### Ollama

| Variable | Default | Description |
|---|---|---|
| `OLLAMA_BASE_URL` | `http://localhost:11434` | Ollama API base URL |
| `OLLAMA_EMBED_MODEL` | `nomic-embed-text` | Model for `/api/embeddings` |
| `OLLAMA_LLM_MODEL` | `llama3.1:8b` | Model for `/api/chat` |
| `OLLAMA_TIMEOUT_SECONDS` | `120` | Timeout per Ollama request |

### RAG Behavior

| Variable | Default | Description |
|---|---|---|
| `RAG_MAX_EVIDENCE_SOURCES` | `8` | Max sources returned per query |
| `RAG_MAX_EVIDENCE_CHARS_PER_EMAIL` | `12000` | Truncate evidence text per email |
| `RAG_CHUNK_SIZE` | `500` | Characters per embedding chunk |
| `RAG_CHUNK_OVERLAP` | `50` | Overlap between chunks |

### Debugging

| Variable | Description |
|---|---|
| `RAG_DEBUG_OLLAMA_EMBED=1` | Print Ollama embedding request JSON |
| `RAG_DEBUG_OLLAMA_CHAT=1` | Print Ollama chat request JSON (full prompt) |
| `RAG_DEBUG_RETRIEVAL=1` | Print retrieval request/response summaries |

## Build / Run

Requires OCaml 5.x and opam:

```bash
opam switch create . ocaml-base-compiler.5.2.0   # first time only
opam install . --deps-only
dune build
dune exec -- rag-email-server -p 8080
```

The server listens on the specified port (default 8080). Configure the Thunderbird filter action endpoint as `http://localhost:8080/ingest`.

## Dependencies

- **eio** / **cohttp-eio**: async I/O and HTTP server (OCaml 5 effects-based)
- **yojson**: JSON construction and parsing (used everywhere, no hand-rolled JSON)
- **lambdasoup**: HTML parsing and text extraction (HTML5 spec compliant)
- **mrmime** / **angstrom**: MIME structure parsing and RFC2047 encoded-word decoding
- **base64** / **pecu** / **uutf**: Content-Transfer-Encoding decoding and UTF-8 sanitization
- **uri**: Percent-encoding/decoding
