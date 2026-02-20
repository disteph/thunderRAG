"""
Shared pytest fixtures for the python-engine integration tests.

These tests hit the running python-engine over HTTP.  They require:
  - The python-engine running (default http://localhost:8000)

Override the server URL with:
    PYTHON_ENGINE_TEST_URL=http://host:port pytest
"""

import os
import uuid

import pytest
import requests

DEFAULT_BASE_URL = "http://localhost:8000"


@pytest.fixture(scope="session")
def base_url():
    """Base URL of the running python-engine."""
    return os.environ.get("PYTHON_ENGINE_TEST_URL", DEFAULT_BASE_URL).rstrip("/")


@pytest.fixture(scope="session")
def server_reachable(base_url):
    """Skip the entire session if the server is not reachable."""
    try:
        r = requests.get(base_url + "/health", timeout=5)
        if r.status_code not in (200, 503):
            pytest.skip(f"python-engine returned unexpected status {r.status_code}")
    except requests.ConnectionError:
        pytest.skip(f"python-engine not reachable at {base_url}")


@pytest.fixture(autouse=True)
def require_server(server_reachable):
    """Auto-use: every test automatically requires the server to be up."""
    pass


@pytest.fixture()
def unique_doc_id():
    """A fresh, unique doc_id for each test."""
    return f"<test-{uuid.uuid4().hex[:16]}@example.com>"


def make_embedding(dim=768, seed=None):
    """Generate a random L2-normalized embedding vector of the given dimension."""
    import numpy as np
    if seed is not None:
        seed = abs(seed) % (2**32)
    rng = np.random.RandomState(seed)
    vec = rng.randn(dim).astype("float32")
    norm = float(np.linalg.norm(vec))
    if norm > 0:
        vec = vec / norm
    return vec.tolist()


def make_ingest_request(doc_id, num_chunks=2, dim=768, metadata=None):
    """Build a valid /ingest_embedded request body."""
    if metadata is None:
        metadata = {
            "from": "test@example.com",
            "subject": "Test document",
            "date": "2025-02-10",
        }
    chunks = []
    for i in range(num_chunks):
        chunks.append({
            "chunk_index": i,
            "text": "",
            "embedding": make_embedding(dim=dim, seed=hash(doc_id) + i),
        })
    return {
        "id": doc_id,
        "metadata": metadata,
        "chunks": chunks,
    }
