"""ThunderRAG python-engine

Responsibilities
- Owns the vector index (FAISS) and the doc_id mapping (SQLite).
- Provides a minimal HTTP API used by the OCaml server:
  - /ingest_embedded: store pre-computed embeddings for a doc_id (computed in OCaml).
  - /query_embedded: vector retrieval given a query embedding (computed in OCaml).
  - /admin/delete, /admin/reset: maintenance operations.

Design notes / invariants
- This service is a pure vector index — it does NOT call an LLM and does NOT store metadata.
  Email metadata (from, subject, date, etc.) is the OCaml server's responsibility.
- Embeddings are treated as cosine similarity via inner product on L2-normalized vectors.
- chunks.text and metadata_json are stored as "" / "{}" respectively.
  The OCaml server and UI do not rely on the python-engine for email content or metadata.
- Retrieval returns chunk-level hits from FAISS, then deduplicates by doc_id (keeping the best
  scoring chunk per doc_id) because the OCaml server operates at the email/message level.
"""

import asyncio
import json
import os
import sqlite3
from dataclasses import dataclass
from typing import Any, Dict, List, Optional

import numpy as np
import faiss  # type: ignore
from contextlib import asynccontextmanager
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field


DATA_DIR = os.environ.get("RAG_ENGINE_DATA_DIR", os.path.join(os.path.dirname(__file__), "data"))
DB_PATH = os.path.join(DATA_DIR, "chunks.sqlite3")
FAISS_PATH = os.path.join(DATA_DIR, "chunks.faiss")
META_PATH = os.path.join(DATA_DIR, "meta.json")

DEFAULT_TOP_K = int(os.environ.get("RAG_ENGINE_TOP_K", "8"))


def _l2_normalize(vec: List[float]) -> List[float]:
    """L2-normalize a vector so inner-product equals cosine similarity."""
    a = np.array(vec, dtype="float32")
    n = float(np.linalg.norm(a))
    return (a / n).tolist() if n > 0 else vec


class EmbeddedChunk(BaseModel):
    """A single chunk with its pre-computed embedding vector."""
    chunk_index: int = Field(..., ge=0)
    text: str
    embedding: List[float]


class IngestEmbeddedRequest(BaseModel):
    """Request to store pre-computed embeddings for a document.

    The OCaml server computes embeddings via Ollama and forwards them here.
    Metadata typically includes from, to, subject, date, attachments, etc.
    """
    id: str = Field(..., description="Document/message id")
    metadata: Dict[str, Any] = Field(default_factory=dict)
    chunks: List[EmbeddedChunk] = Field(default_factory=list)


class IngestResponse(BaseModel):
    status: str
    chunks_ingested: int


class QueryEmbeddedRequest(BaseModel):
    """Vector retrieval request with a pre-computed query embedding."""
    embedding: List[float]
    top_k: int = Field(default=DEFAULT_TOP_K, ge=1, le=50)


class SourceChunk(BaseModel):
    """A single retrieval hit: one chunk from a document, with its similarity score."""
    chunk_id: int
    doc_id: str
    text: str          # Currently "" (pointer-first: bodies come from Thunderbird)
    metadata: Dict[str, Any]
    score: float        # Cosine similarity (inner product on L2-normalized vectors)


class QueryResponse(BaseModel):
    """Retrieval response.  answer is always "" (LLM generation is in OCaml)."""
    answer: str
    sources: List[SourceChunk]


class DeleteRequest(BaseModel):
    id: str


class DeleteResponse(BaseModel):
    status: str
    chunks_deleted: int


class ResetResponse(BaseModel):
    status: str


@dataclass
class EngineState:
    """Singleton runtime state holding the DB connection, FAISS index, and async lock."""
    conn: sqlite3.Connection
    index: Optional[faiss.Index]  # None until first ingestion
    dim: Optional[int]            # Embedding dimensionality (set on first ingest)
    lock: asyncio.Lock            # Serializes all index/DB mutations


def _ensure_data_dir() -> None:
    os.makedirs(DATA_DIR, exist_ok=True)


def _connect_db() -> sqlite3.Connection:
    """Create/open the SQLite DB and ensure the schema exists.

    Schema notes
    - One row per embedded chunk.
    - doc_id is the stable identifier (typically the RFC822 Message-Id).
    - metadata_json stores arbitrary JSON metadata (from, subject, date, attachments, ...).
    """
    conn = sqlite3.connect(DB_PATH, check_same_thread=False)
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS chunks (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          doc_id TEXT NOT NULL,
          chunk_index INTEGER NOT NULL,
          text TEXT NOT NULL,
          metadata_json TEXT NOT NULL
        )
        """
    )
    conn.execute(
        """
        CREATE INDEX IF NOT EXISTS idx_chunks_doc_id
        ON chunks(doc_id)
        """
    )
    conn.commit()
    return conn


def _load_meta() -> Dict[str, Any]:
    """Load the meta.json sidecar (currently just stores {"dim": N})."""
    if not os.path.exists(META_PATH):
        return {}
    with open(META_PATH, "r", encoding="utf-8") as f:
        return json.load(f)


def _save_meta(meta: Dict[str, Any]) -> None:
    """Atomically persist meta.json via write-to-tmp + rename."""
    tmp = META_PATH + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(meta, f)
    os.replace(tmp, META_PATH)


def _make_faiss_index(dim: int) -> faiss.Index:
    """Create a FAISS index configured for cosine similarity.

    Cosine similarity is equivalent to inner product when vectors are L2-normalized.
    We use an ID-mapped index so we can delete by SQLite row ids.
    """
    # Cosine similarity = inner product on L2-normalized vectors.
    base = faiss.IndexFlatIP(dim)
    return faiss.IndexIDMap2(base)


def _load_faiss_index() -> Optional[faiss.Index]:
    if not os.path.exists(FAISS_PATH):
        return None
    return faiss.read_index(FAISS_PATH)


def _persist_faiss_index(index: faiss.Index) -> None:
    """Atomically persist the FAISS index to disk via write-to-tmp + rename."""
    tmp = FAISS_PATH + ".tmp"
    faiss.write_index(index, tmp)
    os.replace(tmp, FAISS_PATH)


def _remove_faiss_ids(index: faiss.Index, ids: List[int]) -> None:
    """Remove vectors from a FAISS IDMap index by their SQLite row IDs."""
    if not ids:
        return
    arr = np.array(ids, dtype="int64")
    sel = faiss.IDSelectorBatch(int(arr.size), faiss.swig_ptr(arr))
    index.remove_ids(sel)


def _safe_unlink(path: str) -> None:
    """Delete a file if it exists; silently ignore if already gone."""
    try:
        os.unlink(path)
    except FileNotFoundError:
        return


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Initialize global EngineState on startup, clean up on shutdown.

    The FAISS index is loaded from disk if present, otherwise created lazily when the first
    embeddings are ingested.
    """
    global state
    _ensure_data_dir()
    conn = _connect_db()
    meta = _load_meta()

    index = _load_faiss_index()
    dim: Optional[int] = None

    if index is not None:
        dim = int(index.d)
    elif isinstance(meta.get("dim"), int):
        dim = meta["dim"]

    state = EngineState(conn=conn, index=index, dim=dim, lock=asyncio.Lock())
    yield
    if state:
        try:
            state.conn.close()
        finally:
            state = None


app = FastAPI(lifespan=lifespan)
state: Optional[EngineState] = None


@app.get("/health")
async def health() -> Dict[str, Any]:
    """Health/status endpoint used for debugging and readiness checks."""
    if not state:
        raise HTTPException(status_code=503, detail="not initialized")
    return {
        "status": "ok",
        "data_dir": DATA_DIR,
        "faiss_loaded": state.index is not None,
        "dim": state.dim,
    }


@app.post("/ingest_embedded", response_model=IngestResponse)
async def ingest_embedded(req: IngestEmbeddedRequest) -> IngestResponse:
    """Ingest pre-computed embeddings for a document/message.

    Idempotency
    - If a doc_id already exists, we delete existing rows and remove their FAISS ids,
      then insert the new chunks.

    Pointer-first storage
    - chunks.text is currently stored as "" (empty) to keep python-engine lightweight.
      The UI does not display bodies from here; OCaml builds prompts from Thunderbird-provided
      raw RFC822 evidence.
    """
    if not state:
        raise HTTPException(status_code=503, detail="not initialized")

    chunks = req.chunks or []
    if not chunks:
        return IngestResponse(status="ok", chunks_ingested=0)

    embedded: List[List[float]] = []
    for ch in chunks:
        vec = [float(x) for x in (ch.embedding or [])]
        if not vec:
            raise HTTPException(status_code=400, detail="empty embedding")
        embedded.append(_l2_normalize(vec))

    async with state.lock:
        meta = _load_meta()

        if state.dim is None:
            state.dim = len(embedded[0])
            meta["dim"] = state.dim
            _save_meta(meta)
        elif len(embedded[0]) != state.dim:
            raise HTTPException(
                status_code=500,
                detail=f"Embedding dim mismatch: expected {state.dim}, got {len(embedded[0])}",
            )

        for v in embedded:
            if len(v) != state.dim:
                raise HTTPException(
                    status_code=500,
                    detail=f"Embedding dim mismatch: expected {state.dim}, got {len(v)}",
                )

        # Idempotency: if this doc_id already exists, replace it.
        cur = state.conn.cursor()
        existing = cur.execute("SELECT id FROM chunks WHERE doc_id=?", (req.id,)).fetchall()
        existing_ids = [int(r[0]) for r in existing]
        if existing_ids:
            cur.execute("DELETE FROM chunks WHERE doc_id=?", (req.id,))
            state.conn.commit()

            if state.index is not None:
                _remove_faiss_ids(state.index, existing_ids)
                if state.index.ntotal == 0:
                    state.index = None
                    state.dim = None
                    _safe_unlink(FAISS_PATH)
                    _safe_unlink(META_PATH)
                else:
                    _persist_faiss_index(state.index)

        if state.index is None:
            if state.dim is None:
                raise HTTPException(status_code=500, detail="Index dimension unknown")
            state.index = _make_faiss_index(state.dim)

        inserted_ids: List[int] = []
        for ch in chunks:
            cur.execute(
                "INSERT INTO chunks(doc_id, chunk_index, text, metadata_json) VALUES(?,?,?,?)",
                (req.id, int(ch.chunk_index), "", "{}"),
            )
            inserted_ids.append(int(cur.lastrowid))
        state.conn.commit()

        vecs = np.array(embedded, dtype="float32")
        ids = np.array(inserted_ids, dtype="int64")
        state.index.add_with_ids(vecs, ids)
        _persist_faiss_index(state.index)

    return IngestResponse(status="ok", chunks_ingested=len(chunks))


@app.post("/query_embedded", response_model=QueryResponse)
async def query_embedded(req: QueryEmbeddedRequest) -> QueryResponse:
    """Vector retrieval endpoint.

    Input
    - embedding: query embedding (already computed by OCaml via Ollama)
    - top_k: maximum number of results

    Output
    - QueryResponse(answer="", sources=[...])
      The OCaml server uses sources[*].doc_id as the stable message pointer.

    Ranking + dedupe
    - FAISS returns chunk-level hits.
    - We load metadata_json from SQLite for each hit.
    - We deduplicate by doc_id (keep highest score), sort by score desc, and return up to top_k.
    """
    if not state:
        raise HTTPException(status_code=503, detail="not initialized")

    qvec = [float(x) for x in (req.embedding or [])]
    if not qvec:
        raise HTTPException(status_code=400, detail="empty embedding")

    qvec = _l2_normalize(qvec)
    search_k = int(req.top_k)

    async with state.lock:
        if state.index is None or state.index.ntotal == 0:
            raise HTTPException(status_code=400, detail="index is empty")
        if state.dim is None or len(qvec) != state.dim:
            raise HTTPException(status_code=500, detail="embedding dim mismatch")

        q = np.array([qvec], dtype="float32")
        scores, ids = state.index.search(q, search_k)

        hits: List[SourceChunk] = []
        cur = state.conn.cursor()
        for score, chunk_id in zip(scores[0].tolist(), ids[0].tolist()):
            if chunk_id == -1:
                continue
            row = cur.execute(
                "SELECT doc_id, text, metadata_json FROM chunks WHERE id=?",
                (int(chunk_id),),
            ).fetchone()
            if not row:
                continue
            doc_id, text, metadata_json = row
            try:
                metadata = json.loads(metadata_json)
            except Exception:
                metadata = {}
            hits.append(
                SourceChunk(
                    chunk_id=int(chunk_id),
                    doc_id=str(doc_id),
                    text=str(text),
                    metadata=metadata,
                    score=float(score),
                )
            )

        # Deduplicate by doc_id, keeping the highest-scoring hit.
        best_by_doc: Dict[str, SourceChunk] = {}
        for h in hits:
            prev = best_by_doc.get(h.doc_id)
            if prev is None or h.score > prev.score:
                best_by_doc[h.doc_id] = h
        hits = list(best_by_doc.values())
        hits.sort(key=lambda h: h.score, reverse=True)
        hits = hits[: int(req.top_k)]

    return QueryResponse(answer="", sources=hits)


@app.post("/admin/delete", response_model=DeleteResponse)
async def admin_delete(req: DeleteRequest) -> DeleteResponse:
    """Delete all chunks associated with a doc_id from SQLite and FAISS."""
    if not state:
        raise HTTPException(status_code=503, detail="not initialized")

    async with state.lock:
        cur = state.conn.cursor()
        rows = cur.execute("SELECT id FROM chunks WHERE doc_id=?", (req.id,)).fetchall()
        chunk_ids = [int(r[0]) for r in rows]
        if not chunk_ids:
            return DeleteResponse(status="ok", chunks_deleted=0)

        cur.execute("DELETE FROM chunks WHERE doc_id=?", (req.id,))
        state.conn.commit()

        if state.index is not None:
            _remove_faiss_ids(state.index, chunk_ids)
            if state.index.ntotal == 0:
                state.index = None
                state.dim = None
                _safe_unlink(FAISS_PATH)
                _safe_unlink(META_PATH)
            else:
                _persist_faiss_index(state.index)

    return DeleteResponse(status="ok", chunks_deleted=len(chunk_ids))


@app.post("/admin/reset", response_model=ResetResponse)
async def admin_reset() -> ResetResponse:
    """Hard reset: delete all persisted DB/index files and reinitialize empty state."""
    if not state:
        raise HTTPException(status_code=503, detail="not initialized")

    async with state.lock:
        try:
            state.conn.close()
        except Exception:
            pass

        _safe_unlink(DB_PATH)
        _safe_unlink(FAISS_PATH)
        _safe_unlink(META_PATH)

        conn = _connect_db()
        state.conn = conn
        state.index = None
        state.dim = None

    return ResetResponse(status="ok")
