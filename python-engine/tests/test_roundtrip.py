"""
End-to-end roundtrip: ingest → query → delete → verify gone.
"""

import requests

from conftest import make_ingest_request, make_embedding


class TestRoundtrip:
    """Full lifecycle: ingest, query, verify retrieval, delete, verify removal."""

    def test_ingest_query_delete_roundtrip(self, base_url, unique_doc_id):
        # 1. Ingest
        metadata = {"from": "roundtrip@example.com", "subject": "Roundtrip test"}
        body = make_ingest_request(unique_doc_id, num_chunks=3, metadata=metadata)
        r1 = requests.post(base_url + "/ingest_embedded", json=body, timeout=30)
        assert r1.status_code == 200
        assert r1.json()["chunks_ingested"] == 3

        # 2. Query — the doc should appear in results
        # Use the same seed as the first chunk to maximize similarity
        qvec = make_embedding(dim=768, seed=hash(unique_doc_id) + 0)
        r2 = requests.post(
            base_url + "/query_embedded",
            json={"embedding": qvec, "top_k": 10},
            timeout=30,
        )
        assert r2.status_code == 200
        doc_ids = [s["doc_id"] for s in r2.json()["sources"]]
        assert unique_doc_id in doc_ids, f"Ingested doc not found in query results: {doc_ids}"

        # Verify metadata is returned
        matching = [s for s in r2.json()["sources"] if s["doc_id"] == unique_doc_id]
        assert len(matching) == 1
        assert matching[0]["metadata"]["from"] == "roundtrip@example.com"
        assert matching[0]["metadata"]["subject"] == "Roundtrip test"

        # 3. Delete
        r3 = requests.post(
            base_url + "/admin/delete",
            json={"id": unique_doc_id},
            timeout=30,
        )
        assert r3.status_code == 200
        assert r3.json()["chunks_deleted"] == 3

        # 4. Query again — the doc should be gone
        r4 = requests.post(
            base_url + "/query_embedded",
            json={"embedding": qvec, "top_k": 10},
            timeout=30,
        )
        # If index is now empty, we get 400; otherwise check doc isn't in results
        if r4.status_code == 200:
            doc_ids_after = [s["doc_id"] for s in r4.json()["sources"]]
            assert unique_doc_id not in doc_ids_after, \
                f"Deleted doc still in results: {doc_ids_after}"
