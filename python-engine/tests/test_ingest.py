"""
Test the /ingest_embedded endpoint.
"""

import requests

from conftest import make_ingest_request, make_embedding


class TestIngestEmbedded:
    """POST /ingest_embedded — store pre-computed embeddings."""

    def test_ingest_single_chunk(self, base_url, unique_doc_id):
        body = make_ingest_request(unique_doc_id, num_chunks=1)
        r = requests.post(base_url + "/ingest_embedded", json=body, timeout=30)
        assert r.status_code == 200
        resp = r.json()
        assert resp["status"] == "ok"
        assert resp["chunks_ingested"] == 1

    def test_ingest_multiple_chunks(self, base_url, unique_doc_id):
        body = make_ingest_request(unique_doc_id, num_chunks=5)
        r = requests.post(base_url + "/ingest_embedded", json=body, timeout=30)
        assert r.status_code == 200
        resp = r.json()
        assert resp["status"] == "ok"
        assert resp["chunks_ingested"] == 5

    def test_ingest_empty_chunks_returns_zero(self, base_url, unique_doc_id):
        body = {"id": unique_doc_id, "metadata": {}, "chunks": []}
        r = requests.post(base_url + "/ingest_embedded", json=body, timeout=30)
        assert r.status_code == 200
        assert r.json()["chunks_ingested"] == 0

    def test_ingest_empty_embedding_returns_400(self, base_url, unique_doc_id):
        body = {
            "id": unique_doc_id,
            "metadata": {},
            "chunks": [{"chunk_index": 0, "text": "", "embedding": []}],
        }
        r = requests.post(base_url + "/ingest_embedded", json=body, timeout=30)
        assert r.status_code == 400

    def test_ingest_is_idempotent(self, base_url, unique_doc_id):
        """Ingesting the same doc_id twice should replace, not duplicate."""
        body1 = make_ingest_request(unique_doc_id, num_chunks=3)
        r1 = requests.post(base_url + "/ingest_embedded", json=body1, timeout=30)
        assert r1.status_code == 200
        assert r1.json()["chunks_ingested"] == 3

        body2 = make_ingest_request(unique_doc_id, num_chunks=2)
        r2 = requests.post(base_url + "/ingest_embedded", json=body2, timeout=30)
        assert r2.status_code == 200
        assert r2.json()["chunks_ingested"] == 2

    def test_ingest_with_metadata(self, base_url, unique_doc_id):
        metadata = {
            "from": "Alice <alice@example.com>",
            "to": "Bob <bob@example.com>",
            "subject": "Metadata test",
            "date": "2025-02-10T09:00:00Z",
            "attachments": ["report.pdf"],
        }
        body = make_ingest_request(unique_doc_id, num_chunks=1, metadata=metadata)
        r = requests.post(base_url + "/ingest_embedded", json=body, timeout=30)
        assert r.status_code == 200
        assert r.json()["status"] == "ok"
