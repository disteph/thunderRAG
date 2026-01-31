import asyncio
import json
import os
import re
import sqlite3
from dataclasses import dataclass
from datetime import datetime
from email.utils import parsedate_to_datetime
from typing import Any, Dict, List, Optional

import faiss  # type: ignore
import httpx
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field


DATA_DIR = os.environ.get("RAG_ENGINE_DATA_DIR", os.path.join(os.path.dirname(__file__), "data"))
DB_PATH = os.path.join(DATA_DIR, "chunks.sqlite3")
FAISS_PATH = os.path.join(DATA_DIR, "chunks.faiss")
META_PATH = os.path.join(DATA_DIR, "meta.json")

OLLAMA_BASE_URL = os.environ.get("OLLAMA_BASE_URL", "http://127.0.0.1:11434")
OLLAMA_EMBED_MODEL = os.environ.get("OLLAMA_EMBED_MODEL", "nomic-embed-text")
OLLAMA_LLM_MODEL = os.environ.get("OLLAMA_LLM_MODEL", "llama3")

DEFAULT_TOP_K = int(os.environ.get("RAG_ENGINE_TOP_K", "8"))


def _build_retrieval_text(question: str, history: List["ChatMessage"]) -> str:
    q = (question or "").strip()
    hist_text = _render_history(history or [], max_chars=3500)
    if not hist_text:
        return q
    out = "Conversation:\n" + hist_text + "\n\nQuestion:\n" + q
    return out[:4000]


def _render_history(history: List["ChatMessage"], max_chars: int) -> str:
    msgs = history or []
    used = 0
    out_rev: List[str] = []
    for m in reversed(msgs):
        role = (m.role or "").strip().lower()
        if role not in ("user", "assistant", "system"):
            role = "user"
        label = "User" if role == "user" else ("Assistant" if role == "assistant" else "System")
        content = (m.content or "").strip()
        if not content:
            continue
        s = f"{label}: {content}"
        extra = len(s) + (1 if out_rev else 0)
        if used + extra > max_chars:
            break
        out_rev.append(s)
        used += extra
    return "\n".join(reversed(out_rev)).strip()


def _parse_email_date(s: Any) -> Optional[datetime]:
    if not isinstance(s, str):
        return None
    s = s.strip()
    if not s:
        return None
    try:
        dt = parsedate_to_datetime(s)
    except Exception:
        return None
    if dt is None:
        return None
    if dt.tzinfo is None:
        return None
    return dt


class IngestRequest(BaseModel):
    id: str = Field(..., description="Document/message id")
    text: str = Field(..., description="Text content to embed")
    metadata: Dict[str, Any] = Field(default_factory=dict)


class IngestResponse(BaseModel):
    status: str
    chunks_ingested: int


class ChatMessage(BaseModel):
    role: str
    content: str


class QueryRequest(BaseModel):
    question: str
    top_k: int = Field(default=DEFAULT_TOP_K, ge=1, le=50)
    mode: str = Field(default="assistive")
    history: List[ChatMessage] = Field(default_factory=list)


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


class SummarizeRequest(BaseModel):
    text: str
    target_chars: int = Field(default=4000, ge=200, le=20000)
    kind: str = Field(default="history")


class SummarizeResponse(BaseModel):
    summary: str


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


async def _ollama_embed(client: httpx.AsyncClient, text: str) -> List[float]:
    resp = await client.post(
        f"{OLLAMA_BASE_URL}/api/embeddings",
        json={"model": OLLAMA_EMBED_MODEL, "prompt": text},
        timeout=120.0,
    )
    resp.raise_for_status()
    data = resp.json()
    emb = data.get("embedding")
    if not isinstance(emb, list) or not emb:
        raise RuntimeError("Ollama embeddings returned no embedding")
    return [float(x) for x in emb]


async def _ollama_generate(client: httpx.AsyncClient, prompt: str) -> str:
    resp = await client.post(
        f"{OLLAMA_BASE_URL}/api/generate",
        json={"model": OLLAMA_LLM_MODEL, "prompt": prompt, "stream": False},
        timeout=300.0,
    )
    resp.raise_for_status()
    data = resp.json()
    out = data.get("response")
    if not isinstance(out, str):
        raise RuntimeError("Ollama generate returned unexpected response")
    return out.strip()


def _l2_normalize(vec: List[float]) -> List[float]:
    import math

    s = 0.0
    for v in vec:
        s += v * v
    if s <= 0:
        return vec
    inv = 1.0 / math.sqrt(s)
    return [v * inv for v in vec]


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
        "ollama_base_url": OLLAMA_BASE_URL,
        "embed_model": OLLAMA_EMBED_MODEL,
        "llm_model": OLLAMA_LLM_MODEL,
        "faiss_loaded": state.index is not None,
        "dim": state.dim,
    }


@app.post("/ingest", response_model=IngestResponse)
async def ingest(req: IngestRequest) -> IngestResponse:
    if not state:
        raise HTTPException(status_code=503, detail="not initialized")

    chunks = _chunk_text(req.text)
    if not chunks:
        return IngestResponse(status="ok", chunks_ingested=0)

    async with state.lock:
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

        meta = _load_meta()
        async with httpx.AsyncClient(trust_env=False) as client:
            embedded: List[List[float]] = []
            for ch in chunks:
                vec = await _ollama_embed(client, ch)
                if state.dim is None:
                    state.dim = len(vec)
                    meta["dim"] = state.dim
                    _save_meta(meta)
                elif len(vec) != state.dim:
                    raise HTTPException(
                        status_code=500,
                        detail=f"Embedding dim mismatch: expected {state.dim}, got {len(vec)}",
                    )
                embedded.append(_l2_normalize(vec))

        if state.index is None:
            if state.dim is None:
                raise HTTPException(status_code=500, detail="Index dimension unknown")
            state.index = _make_faiss_index(state.dim)

        cur = state.conn.cursor()
        inserted_ids: List[int] = []
        for i, chunk_text in enumerate(chunks):
            cur.execute(
                "INSERT INTO chunks(doc_id, chunk_index, text, metadata_json) VALUES(?,?,?,?)",
                (req.id, i, chunk_text, json.dumps(req.metadata)),
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
async def query(req: QueryRequest) -> QueryResponse:
    if not state:
        raise HTTPException(status_code=503, detail="not initialized")

    mode = (req.mode or "assistive").strip().lower()
    if mode not in ("assistive", "grounded"):
        raise HTTPException(status_code=400, detail="mode must be 'assistive' or 'grounded'")

    retrieval_text = _build_retrieval_text(req.question, req.history)
    search_k = req.top_k

    async with state.lock:
        if state.index is None or state.index.ntotal == 0:
            raise HTTPException(status_code=400, detail="index is empty")

        async with httpx.AsyncClient(trust_env=False) as client:
            qvec = await _ollama_embed(client, retrieval_text)

        if state.dim is None or len(qvec) != state.dim:
            raise HTTPException(status_code=500, detail="embedding dim mismatch")

        qvec = _l2_normalize(qvec)

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

    history_text = _render_history(req.history or [], max_chars=12000)

    context_parts = []
    for i, h in enumerate(hits, start=1):
        md = h.metadata or {}
        meta_lines: List[str] = []
        for k in ("from", "to", "cc", "bcc", "subject", "date", "message_id"):
            v = md.get(k)
            if isinstance(v, str) and v.strip():
                meta_lines.append(f"{k}: {v.strip()}")

        atts = md.get("attachments")
        if isinstance(atts, list):
            files = [str(x).strip() for x in atts if isinstance(x, str) and str(x).strip()]
            if files:
                meta_lines.append("attachments: " + ", ".join(files))

        meta_block = "\n".join(meta_lines)
        if meta_block:
            context_parts.append(
                f"[Source {i} | doc_id={h.doc_id} | chunk_id={h.chunk_id}]\nMetadata:\n{meta_block}\n\nText:\n{h.text}"
            )
        else:
            context_parts.append(f"[Source {i} | doc_id={h.doc_id} | chunk_id={h.chunk_id}]\n{h.text}")

    context = "\n\n".join(context_parts)

    if mode == "grounded":
        prompt = (
            "You are a local assistant answering questions from an email archive. "
            "Use ONLY the provided sources for factual claims about emails. "
            "You may use the conversation to understand references like 'that email', but do not treat it as evidence. "
            "If the sources do not contain the answer, say you don't know.\n\n"
            f"Conversation (optional):\n{history_text}\n\n"
            f"Question: {req.question}\n\n"
            f"Sources:\n{context}\n\n"
            "Answer:\n"
        )
    else:
        prompt = (
            "You are a local assistant. You are helping the user with email-related tasks. "
            "The provided sources are optional context from the user's email archive. "
            "Use them when relevant, and cite them using [Source N] when you rely on them. "
            "If the user asks about who sent an email, the subject, recipients, or message-id, answer by reading the sources (prefer metadata/headers). "
            "If the user refers to an unspecified source among several, ask which [Source N] they mean. "
            "If the sources do not contain the answer, still be helpful and answer from general knowledge, "
            "but do not invent claims about what the sources say.\n\n"
            f"Conversation (optional):\n{history_text}\n\n"
            f"Question: {req.question}\n\n"
            f"Sources (optional):\n{context}\n\n"
            "Answer:\n"
        )

    async with httpx.AsyncClient(trust_env=False) as client:
        answer = await _ollama_generate(client, prompt)

    return QueryResponse(answer=answer, sources=hits)


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


@app.post("/admin/summarize", response_model=SummarizeResponse)
async def admin_summarize(req: SummarizeRequest) -> SummarizeResponse:
    text = (req.text or "").strip()
    if not text:
        return SummarizeResponse(summary="")

    kind = (req.kind or "history").strip().lower()
    if kind not in ("history", "sources"):
        kind = "history"

    instr = (
        "Summarize the following conversation so it can be used as context for a future assistant reply. "
        "Preserve user preferences, decisions, constraints, open questions, and any specific identifiers. "
        "Do not invent facts. "
    )
    if kind == "sources":
        instr = (
            "Summarize the following sources recap so it can be used as context for follow-up questions. "
            "Preserve any doc_id/message_id, dates, subjects, senders, and attachment filenames. "
            "Do not invent sources. "
        )

    target = int(req.target_chars)
    prompt = (
        f"{instr}\\n"
        f"Target length: at most {target} characters.\\n"
        "Output plain text.\\n\\n"
        "Text to summarize:\n"
        + text
        + "\n"
    )

    async with httpx.AsyncClient(trust_env=False) as client:
        summary = await _ollama_generate(client, prompt)

    if len(summary) > target:
        summary = summary[:target]

    return SummarizeResponse(summary=summary)
