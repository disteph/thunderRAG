"""
Test the /admin/reset endpoint.

WARNING: This test wipes the entire vector index.
Run selectively: ``pytest -k 'not TestAdminReset'`` to skip.
"""

import requests

from conftest import make_ingest_request, make_embedding


class TestAdminReset:
    """POST /admin/reset — hard reset of all data."""

    def test_reset_returns_ok(self, base_url):
        r = requests.post(base_url + "/admin/reset", timeout=30)
        assert r.status_code == 200
        assert r.json()["status"] == "ok"

    def test_reset_clears_index(self, base_url, unique_doc_id):
        """After reset, querying should fail with 'index is empty'."""
        # Ingest something first
        body = make_ingest_request(unique_doc_id, num_chunks=2)
        r1 = requests.post(base_url + "/ingest_embedded", json=body, timeout=30)
        assert r1.status_code == 200

        # Reset
        r2 = requests.post(base_url + "/admin/reset", timeout=30)
        assert r2.status_code == 200

        # Query should fail
        qvec = make_embedding(dim=768, seed=1)
        r3 = requests.post(
            base_url + "/query_embedded",
            json={"embedding": qvec, "top_k": 3},
            timeout=30,
        )
        assert r3.status_code == 400

    def test_health_after_reset(self, base_url):
        """After reset, /health should still return ok (but no index loaded)."""
        requests.post(base_url + "/admin/reset", timeout=30)
        r = requests.get(base_url + "/health", timeout=10)
        assert r.status_code == 200
        body = r.json()
        assert body["status"] == "ok"
        assert body["faiss_loaded"] is False
