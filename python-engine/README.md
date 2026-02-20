# ThunderRAG Python Engine

The python-engine is the **vector index and metadata store** for the ThunderRAG system. It owns the FAISS similarity index and a SQLite database of chunk metadata, and exposes a minimal HTTP API consumed exclusively by the OCaml server.

## Architecture Overview

```
OCaml Server ──── embeddings + metadata ────▸ python-engine
     │                                            │
     │  (Ollama /api/embeddings)                  │  FAISS (cosine via inner-product)
     │                                            │  SQLite (chunk metadata)
     ▼                                            ▼
  Orchestrator                              Vector index + metadata store
  Prompt builder                            Chunk-level retrieval, doc-level dedup
```

**Key design principle**: The python-engine never calls an LLM and never stores email bodies. Embeddings are pre-computed by the OCaml server (via Ollama) and forwarded here. Chunk text is stored as `""` — Thunderbird is the source of truth for message content.

## HTTP Endpoints

### `GET /health`

Readiness/status check.

- **Response**: `{ "status": "ok", "data_dir": "...", "faiss_loaded": true, "dim": 768 }`

### `POST /ingest_embedded`

Store pre-computed embeddings for a document.

- **Body** (JSON):
  ```json
  {
    "id": "<message-id@example.com>",
    "metadata": { "from": "...", "subject": "...", "date": "..." },
    "chunks": [
      { "chunk_index": 0, "text": "", "embedding": [0.1, 0.2, ...] }
    ]
  }
  ```
- **Idempotency**: If `id` already exists, existing chunks are deleted and replaced.
- **Response**: `{ "status": "ok", "chunks_ingested": N }`

### `POST /query_embedded`

Vector retrieval given a pre-computed query embedding.

- **Body** (JSON):
  ```json
  {
    "embedding": [0.1, 0.2, ...],
    "top_k": 8
  }
  ```
- **Process**:
  1. L2-normalize the query vector
  2. FAISS inner-product search (equivalent to cosine similarity on normalized vectors)
  3. Load metadata from SQLite for each hit
  4. Deduplicate by `doc_id` (keep highest score per document)
  5. Sort by score descending, truncate to `top_k`
- **Response**:
  ```json
  {
    "answer": "",
    "sources": [
      { "chunk_id": 1, "doc_id": "<msg@example.com>", "text": "", "metadata": {...}, "score": 0.85 }
    ]
  }
  ```

### `POST /admin/delete`

Delete all chunks for a document.

- **Body**: `{ "id": "<message-id@example.com>" }`
- **Response**: `{ "status": "ok", "chunks_deleted": N }`

### `POST /admin/reset`

Hard reset: wipe all data (SQLite + FAISS + meta.json) and reinitialize empty.

- **Response**: `{ "status": "ok" }`

## Storage

All data lives under `RAG_ENGINE_DATA_DIR` (default: `./data/`):

| File | Description |
|---|---|
| `chunks.sqlite3` | One row per embedded chunk: `(id, doc_id, chunk_index, text, metadata_json)` |
| `chunks.faiss` | FAISS `IndexIDMap2(IndexFlatIP)` — inner-product index with SQLite row IDs |
| `meta.json` | Sidecar: `{ "dim": 768 }` — embedding dimensionality |

Writes are atomic (write-to-tmp + `os.replace`). All index/DB mutations are serialized via `asyncio.Lock`.

## Configuration

| Variable | Default | Description |
|---|---|---|
| `RAG_ENGINE_DATA_DIR` | `./data/` | Directory for SQLite, FAISS, and meta.json |
| `RAG_ENGINE_TOP_K` | `8` | Default `top_k` for `/query_embedded` |

## Setup / Run

Requires Python 3.10+:

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
uvicorn app:app --port 8000
```

Or use the Makefile:

```bash
make run          # create venv, install deps, start server on port 8000
make test         # run the integration test suite
make test-fast    # health + admin tests only (no embeddings needed)
```

## Dependencies

- **FastAPI** / **uvicorn**: async HTTP server
- **faiss-cpu**: vector similarity search (inner-product on L2-normalized vectors)
- **numpy**: vector normalization
- **pydantic**: request/response validation
