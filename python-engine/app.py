import asyncio
import json
import os
import sqlite3
from dataclasses import dataclass
from typing import Any, Dict, List, Optional

import faiss  # type: ignore
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field


DATA_DIR = os.environ.get("RAG_ENGINE_DATA_DIR", os.path.join(os.path.dirname(__file__), "data"))
DB_PATH = os.path.join(DATA_DIR, "chunks.sqlite3")
FAISS_PATH = os.path.join(DATA_DIR, "chunks.faiss")
META_PATH = os.path.join(DATA_DIR, "meta.json")

DEFAULT_TOP_K = int(os.environ.get("RAG_ENGINE_TOP_K", "8"))


def _l2_normalize(vec: List[float]) -> List[float]:
    import math

    s = 0.0
    for v in vec:
        s += v * v
    if s <= 0:
        return vec
    inv = 1.0 / math.sqrt(s)
    return [v * inv for v in vec]


class IngestRequest(BaseModel):
    id: str = Field(..., description="Document/message id")
    text: str = Field(..., description="Text content to embed")
    metadata: Dict[str, Any] = Field(default_factory=dict)


class EmbeddedChunk(BaseModel):
    chunk_index: int = Field(..., ge=0)
    text: str
    embedding: List[float]


class IngestEmbeddedRequest(BaseModel):
    id: str = Field(..., description="Document/message id")
    metadata: Dict[str, Any] = Field(default_factory=dict)
    chunks: List[EmbeddedChunk] = Field(default_factory=list)


class IngestResponse(BaseModel):
    status: str
    chunks_ingested: int


class QueryEmbeddedRequest(BaseModel):
    embedding: List[float]
    top_k: int = Field(default=DEFAULT_TOP_K, ge=1, le=50)


class SourceChunk(BaseModel):
    chunk_id: int
    doc_id: str
    text: str
    metadata: Dict[str, Any]
    score: float


class QueryResponse(BaseModel):
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
    conn: sqlite3.Connection
    index: Optional[faiss.Index]
    dim: Optional[int]
    lock: asyncio.Lock


def _ensure_data_dir() -> None:
    os.makedirs(DATA_DIR, exist_ok=True)


def _connect_db() -> sqlite3.Connection:
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
    if not os.path.exists(META_PATH):
        return {}
    with open(META_PATH, "r", encoding="utf-8") as f:
        return json.load(f)


def _save_meta(meta: Dict[str, Any]) -> None:
    tmp = META_PATH + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(meta, f)
    os.replace(tmp, META_PATH)


def _make_faiss_index(dim: int) -> faiss.Index:
    # Cosine similarity = inner product on L2-normalized vectors.
    base = faiss.IndexFlatIP(dim)
    return faiss.IndexIDMap2(base)


def _load_faiss_index() -> Optional[faiss.Index]:
    if not os.path.exists(FAISS_PATH):
        return None
    return faiss.read_index(FAISS_PATH)


def _persist_faiss_index(index: faiss.Index) -> None:
    tmp = FAISS_PATH + ".tmp"
    faiss.write_index(index, tmp)
    os.replace(tmp, FAISS_PATH)


def _remove_faiss_ids(index: faiss.Index, ids: List[int]) -> None:
    if not ids:
        return
    import numpy as np

    arr = np.array(ids, dtype="int64")
    sel = faiss.IDSelectorBatch(int(arr.size), faiss.swig_ptr(arr))
    index.remove_ids(sel)


def _safe_unlink(path: str) -> None:
    try:
        os.unlink(path)
    except FileNotFoundError:
        return


def _chunk_text(text: str, *, chunk_size: int = 1500, overlap: int = 200) -> List[str]:
    cleaned = text.replace("\r\n", "\n").strip()
    if not cleaned:
        return []

    chunks: List[str] = []
    start = 0
    n = len(cleaned)
    while start < n:
        end = min(n, start + chunk_size)
        chunk = cleaned[start:end].strip()
        if chunk:
            chunks.append(chunk)
        if end >= n:
            break
        start = max(0, end - overlap)
    return chunks


app = FastAPI()
state: Optional[EngineState] = None


@app.on_event("startup")
async def _startup() -> None:
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


@app.on_event("shutdown")
async def _shutdown() -> None:
    global state
    if not state:
        return
    try:
        state.conn.close()
    finally:
        state = None


@app.get("/health")
async def health() -> Dict[str, Any]:
    if not state:
        raise HTTPException(status_code=503, detail="not initialized")
    return {
        "status": "ok",
        "data_dir": DATA_DIR,
        "faiss_loaded": state.index is not None,
        "dim": state.dim,
    }


@app.post("/ingest", response_model=IngestResponse)
async def ingest(req: IngestRequest) -> IngestResponse:
    raise HTTPException(
        status_code=410,
        detail="/ingest is disabled. Compute embeddings in OCaml and call /ingest_embedded.",
    )


@app.post("/ingest_embedded", response_model=IngestResponse)
async def ingest_embedded(req: IngestEmbeddedRequest) -> IngestResponse:
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
                (req.id, int(ch.chunk_index), ch.text, json.dumps(req.metadata)),
            )
            inserted_ids.append(int(cur.lastrowid))
        state.conn.commit()

        import numpy as np

        vecs = np.array(embedded, dtype="float32")
        ids = np.array(inserted_ids, dtype="int64")
        state.index.add_with_ids(vecs, ids)
        _persist_faiss_index(state.index)

    return IngestResponse(status="ok", chunks_ingested=len(chunks))


@app.post("/query", response_model=QueryResponse)
async def query(_req: Dict[str, Any]) -> QueryResponse:
    raise HTTPException(
        status_code=410,
        detail="/query is disabled. Compute embeddings + LLM response in OCaml; call /query_embedded for retrieval.",
    )


@app.post("/query_embedded", response_model=QueryResponse)
async def query_embedded(req: QueryEmbeddedRequest) -> QueryResponse:
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

        import numpy as np

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

    return QueryResponse(answer="", sources=hits)


@app.post("/admin/delete", response_model=DeleteResponse)
async def admin_delete(req: DeleteRequest) -> DeleteResponse:
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


@app.post("/admin/summarize")
async def admin_summarize(_req: Dict[str, Any]) -> Dict[str, Any]:
    raise HTTPException(
        status_code=410,
        detail="/admin/summarize is disabled. Summarization should be done by OCaml via Ollama.",
    )
