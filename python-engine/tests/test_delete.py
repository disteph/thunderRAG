"""
Test the /admin/delete endpoint.
"""

import requests

from conftest import make_ingest_request, make_embedding


class TestAdminDelete:
    """POST /admin/delete — remove a doc_id from the index."""

    def test_delete_nonexistent_doc_id(self, base_url):
        """Deleting a doc_id that doesn't exist should return ok with 0 chunks deleted."""
        r = requests.post(
            base_url + "/admin/delete",
            json={"id": "<nonexistent-delete@example.com>"},
            timeout=30,
        )
        assert r.status_code == 200
        resp = r.json()
        assert resp["status"] == "ok"
        assert resp["chunks_deleted"] == 0

    def test_ingest_then_delete(self, base_url, unique_doc_id):
        """Ingest a document, delete it, verify chunks_deleted > 0."""
        body = make_ingest_request(unique_doc_id, num_chunks=3)
        r1 = requests.post(base_url + "/ingest_embedded", json=body, timeout=30)
        assert r1.status_code == 200

        r2 = requests.post(
            base_url + "/admin/delete",
            json={"id": unique_doc_id},
            timeout=30,
        )
        assert r2.status_code == 200
        resp = r2.json()
        assert resp["status"] == "ok"
        assert resp["chunks_deleted"] == 3

    def test_delete_is_idempotent(self, base_url, unique_doc_id):
        """Deleting the same doc_id twice: first returns N, second returns 0."""
        body = make_ingest_request(unique_doc_id, num_chunks=2)
        requests.post(base_url + "/ingest_embedded", json=body, timeout=30)

        r1 = requests.post(base_url + "/admin/delete", json={"id": unique_doc_id}, timeout=30)
        assert r1.status_code == 200
        assert r1.json()["chunks_deleted"] == 2

        r2 = requests.post(base_url + "/admin/delete", json={"id": unique_doc_id}, timeout=30)
        assert r2.status_code == 200
        assert r2.json()["chunks_deleted"] == 0

    def test_delete_does_not_affect_other_docs(self, base_url):
        """Deleting doc A should not remove doc B from the index."""
        doc_a = "<delete-isolation-a@example.com>"
        doc_b = "<delete-isolation-b@example.com>"
        body_a = make_ingest_request(doc_a, num_chunks=2)
        body_b = make_ingest_request(doc_b, num_chunks=2)
        requests.post(base_url + "/ingest_embedded", json=body_a, timeout=30)
        requests.post(base_url + "/ingest_embedded", json=body_b, timeout=30)

        # Delete A
        requests.post(base_url + "/admin/delete", json={"id": doc_a}, timeout=30)

        # B should still be queryable
        qvec = make_embedding(dim=768, seed=hash(doc_b))
        r = requests.post(
            base_url + "/query_embedded",
            json={"embedding": qvec, "top_k": 10},
            timeout=30,
        )
        assert r.status_code == 200
        doc_ids = [s["doc_id"] for s in r.json()["sources"]]
        assert doc_b in doc_ids, f"Doc B missing after deleting Doc A. Found: {doc_ids}"
        assert doc_a not in doc_ids, f"Doc A still in index after deletion. Found: {doc_ids}"
