# ThunderRAG OCaml Server

The OCaml server is the **central orchestrator** of the ThunderRAG system. It sits between the Thunderbird add-on (which provides raw email content) and PostgreSQL/pgvector (which stores email metadata and vector embeddings), and it is the only component that talks to the LLM (Ollama).

## Architecture Overview

```
Thunderbird Add-on ──── raw RFC822 ────▸ OCaml Server ──── embeddings ────▸ PostgreSQL + pgvector
        │                                    │                                   │
        │  (browser.messages.getRaw)         │  (Ollama /api/embeddings)         │  (vector kNN search)
        │                                    │  (Ollama /api/chat)               │  (email metadata)
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
  7. Store email metadata + chunk embeddings in PostgreSQL via `Pg` module
- **Response**: JSON `{ "ok": true }` or error

#### `POST /admin/bulk_ingest`

Scans local mbox files and ingests all messages. Used for initial corpus loading.

- **Body**: JSON `{ "paths": ["/path/to/Mail/..."], "recursive": true, "concurrency": 4, "max_messages": 0 }`
- **Process**: Splits mbox files into individual messages, ingests each via the same pipeline as `/ingest`
- **Response**: JSON with progress stats (total scanned, ingested, skipped, failed)

### Query (2-Phase Flow)

The query flow is split into three steps so that Thunderbird (not the server) fetches full email bodies. This avoids storing email content server-side.

#### Phase 1: `POST /query`

Retrieval only — does **not** call Ollama chat.

- **Body**: JSON `{ "session_id": "...", "question": "...", "top_k": 8, "mode": "assistive", "user_name": "..." }`
  - `user_name` (optional): User identity string from the Thunderbird add-on (email address, display name). Stored on the session (first-write wins) and included in system prompts for both query rewriting and chat answer generation.
- **Process**:
  1. **Query rewriting** (if `RAG_QUERY_REWRITE` is enabled): A single LLM call that produces:
     - `resolved_question`: The user's question with all relative references resolved (e.g. "the second email" → "the email from Mark Mitchell about project deadlines dated 2026-02-18"). Used as the final question in the chat prompt to avoid ambiguity with newly retrieved evidence.
     - `rewrite` (multi-turn only): Self-contained search query with pronouns, relative dates, and implicit references resolved.
     - `hypothetical` (HyDE): A hypothetical email in the exact indexed format (From/To/Cc/Subject/Date headers + body) to maximize cosine similarity with relevant stored emails.
  2. Embed each query variant via Ollama `/api/embeddings`
  3. Query PostgreSQL/pgvector for top-K similar documents per variant, merge by doc_id (max score)
  4. Generate a `request_id` and store a pending query entry (including `resolved_question`)
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
  3. Enrich each evidence email with full metadata from the ingestion ledger:
     - **Headers**: From, To, Cc, Bcc, Subject, Date
     - **Attachments**: list of filenames
     - **Triage**: action score (0–100), importance score (0–100), reply-by deadline
     - **Processed flag**: whether the user has already dealt with this email
     - **Body sections**: NEW CONTENT (summarized to fit) + QUOTED CONTEXT (thread history, summarized)
  4. Build the final prompt:
     - System instructions + user identity + current timestamp + explanation of triage metadata and processed flag semantics
     - History summary (compressed older conversation, if any)
     - Recent conversation tail (up to 24 turns) — assistant messages include an `EMAILS REFERENCED ABOVE` index so `[Email N]` citations are resolvable in history
     - EMAILS THAT MAY BE RELEVANT (full evidence with all metadata)
     - Resolved question (from Phase 1) with citation instructions
  5. Call Ollama `/api/chat`
  6. Update session state: store raw question + answer (with email reference index appended), then optionally summarize older turns
- **Response**: JSON `{ "answer": "...", "sources": [...] }`

### Admin / Maintenance

| Endpoint | Method | Description |
|---|---|---|
| `/admin/delete` | POST | Delete a doc_id from the vector index |
| `/admin/reset` | POST | Hard reset: wipe the entire vector index |
| `/admin/session/debug` | POST | Dump session state (tail, summaries) for debugging |
| `/admin/session/reset` | POST | Clear a session's conversation history |
| `/admin/bulk_state/reset` | POST | Clear the bulk ingestion progress state file |
| `/admin/mark_processed` | POST | Mark an ingested email as processed (no further action needed) |
| `/admin/mark_unprocessed` | POST | Clear the processed flag on an ingested email |
| `/admin/ingested_status` | POST | Check ingestion + processed status for a batch of message IDs |
| `/admin/extract_body` | POST | Re-extract body text from raw RFC822 (with optional LLM summarization) |

## Module Structure

```
ocaml-server/
├── bin/
│   └── main.ml              # HTTP server, Ollama integration, session state,
│                             # ingestion pipeline (with triage), query orchestration
│                             # (multi-query rewrite + HyDE + reference resolution),
│                             # evidence enrichment, recursive summarization, bulk ingest
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
│   ├── pg.ml                 # PostgreSQL/pgvector: connection pool, schema, CRUD, kNN retrieval
│   ├── sql_validate.ml       # SQL fragment validation via libpg_query AST walking
│   └── dune                  # Library dependencies: uri lambdasoup yojson unix mrmime
│                             # angstrom base64 pecu uutf caqti caqti-eio caqti-driver-postgresql pg_query
├── bin/dune                  # Executable dependencies: rag_lib + eio cohttp-eio
└── rag_email_server.opam     # Package metadata
```

## Key Design Decisions

### Recursive Summarization

All LLM-based compression uses `summarize_to_fit`, which recursively splits and summarizes text to fit a character budget. The compression ratio per pass is clamped to **50–75%** of the input: never below 50% (wastes quality) nor above 75% (wastes a pass). This ensures convergence in 2–3 passes rather than many barely-reducing iterations.

### Email Triage

At ingestion time, each email is scored by an LLM for:
- **action_score** (0–100): does it require action/response from the user?
- **importance_score** (0–100): overall importance
- **reply_by**: estimated response deadline (ISO 8601 or "none")

These scores are stored in metadata and included in both the vector index text (for retrieval) and the evidence headers (for the chat model). The `processed` flag (set via `/admin/mark_processed`) indicates the user has dealt with the email.

### Session & Conversation Management

Each session holds:
- **user_name**: identity from the Thunderbird add-on (included in system prompts)
- **tail**: recent user/assistant turns (max 24). Assistant messages include an `EMAILS REFERENCED ABOVE` index so `[Email N]` citations remain resolvable.
- **history_summary**: rolling LLM-compressed summary of older turns, with email references resolved to inline descriptions.

### Query Rewriting & Reference Resolution

A single LLM call before retrieval produces:
1. **resolved_question**: user's question with relative references ("the second email", "that one") replaced by concrete identifiers. Used as the final question in the chat prompt, placed after the evidence block, so there's no ambiguity between previously cited emails and freshly retrieved ones.
2. **rewrite**: self-contained search query (multi-turn only)
3. **hypothetical** (HyDE): a fake email in the exact indexed format to maximize embedding similarity

## Configuration

All configuration is via environment variables (with fallbacks to `~/.thunderrag/settings.json`).

### Ollama

| Variable | Default | Description |
|---|---|---|
| `OLLAMA_BASE_URL` | `http://localhost:11434` | Ollama API base URL |
| `OLLAMA_EMBED_MODEL` | `nomic-embed-text` | Model for `/api/embeddings` |
| `OLLAMA_LLM_MODEL` | `llama3` | Model for `/api/chat` (main conversation) |
| `OLLAMA_SUMMARIZE_MODEL` | (falls back to LLM_MODEL) | Model for summarization and query rewriting |
| `OLLAMA_TRIAGE_MODEL` | (falls back to LLM_MODEL) | Model for email triage (action/importance scoring) |
| `OLLAMA_TIMEOUT_SECONDS` | `300` | Timeout per Ollama request |

### RAG Behavior

| Variable | Default | Description |
|---|---|---|
| `RAG_CHUNK_SIZE` | `1500` | Characters per embedding chunk |
| `RAG_CHUNK_OVERLAP` | `200` | Overlap between chunks |
| `RAG_MAX_EVIDENCE_CHARS_PER_EMAIL` | `8000` | Max chars per email in evidence (recursively summarized beyond this) |
| `RAG_NEW_CONTENT_MAX_CHARS` | `8000` | Max chars for NEW CONTENT section at ingestion |
| `RAG_SUMMARIZE_MAX_INPUT_CHARS` | `20000` | Max chars per LLM summarization input chunk |
| `RAG_QUERY_REWRITE` | `true` | Enable multi-query rewriting (contextual rewrite + HyDE + reference resolution) |

### Quoted Context & Attachments

| Variable | Default | Description |
|---|---|---|
| `RAG_QUOTED_CONTEXT_SUMMARIZE` | `false` | LLM-summarize quoted thread context at ingestion |
| `RAG_QUOTED_CONTEXT_MAX_LINES` | `100` | Max lines of quoted context to keep |
| `RAG_QUOTED_CONTEXT_MAX_CHARS` | `8000` | Max chars for quoted context summary |
| `RAG_ATTACHMENT_SUMMARIZE` | `false` | LLM-summarize attachments at ingestion |
| `RAG_ATTACHMENT_MAX_ATTACHMENTS` | `4` | Max attachments to process per email |
| `RAG_ATTACHMENT_MAX_CHARS` | `1500` | Max chars per attachment summary |
| `RAG_ATTACHMENT_MAX_BYTES` | `5000000` | Max raw bytes per attachment to process |

### Debugging

| Variable | Description |
|---|---|
| `RAG_DEBUG_OLLAMA_EMBED=1` | Print Ollama embedding request JSON |
| `RAG_DEBUG_OLLAMA_CHAT=1` | Print Ollama chat request/response JSON (full prompts) |
| `RAG_DEBUG_RETRIEVAL=1` | Print retrieval queries, scores, and merged source summaries |

## Build / Run

Requires OCaml 5.x, opam, and PostgreSQL 17+ with pgvector and libpg_query:

```bash
brew install postgresql@17 pgvector libpg_query
brew services start postgresql@17
createdb thunderrag
psql -d thunderrag -c "CREATE EXTENSION IF NOT EXISTS vector;"
```

Then build and run:

```bash
opam switch create . ocaml-base-compiler.5.2.0   # first time only
opam install . --deps-only
dune build
dune exec -- rag-email-server -p 8080
```

The server listens on the specified port (default 8080). On startup it connects to PostgreSQL (default `postgresql://localhost/thunderrag`, override with `THUNDERRAG_PG_URL`) and creates the schema if needed.

## Dependencies

- **eio** / **cohttp-eio**: async I/O and HTTP server (OCaml 5 effects-based)
- **yojson**: JSON construction and parsing (used everywhere, no hand-rolled JSON)
- **lambdasoup**: HTML parsing and text extraction (HTML5 spec compliant)
- **mrmime** / **angstrom**: MIME structure parsing and RFC2047 encoded-word decoding
- **base64** / **pecu** / **uutf**: Content-Transfer-Encoding decoding and UTF-8 sanitization
- **uri**: Percent-encoding/decoding
- **caqti** / **caqti-eio** / **caqti-driver-postgresql**: PostgreSQL connection pooling and typed queries
- **pg_query**: SQL parsing via libpg_query (validates LLM-generated SQL fragments)
