"""
Test the /query_embedded endpoint.
"""

import requests

from conftest import make_ingest_request, make_embedding


def _ingest_corpus(base_url, dim=768):
    """Ingest 3 documents so the index is non-empty for query tests.
    Returns the list of doc_ids."""
    doc_ids = [
        "<query-test-a@example.com>",
        "<query-test-b@example.com>",
        "<query-test-c@example.com>",
    ]
    for i, doc_id in enumerate(doc_ids):
        body = make_ingest_request(
            doc_id,
            num_chunks=2,
            dim=dim,
            metadata={"from": f"user{i}@example.com", "subject": f"Doc {i}"},
        )
        r = requests.post(base_url + "/ingest_embedded", json=body, timeout=30)
        assert r.status_code == 200, f"Corpus ingest failed for {doc_id}: {r.text}"
    return doc_ids


class TestQueryEmbedded:
    """POST /query_embedded — vector retrieval."""

    def test_query_returns_sources(self, base_url):
        doc_ids = _ingest_corpus(base_url)
        qvec = make_embedding(dim=768, seed=42)
        r = requests.post(
            base_url + "/query_embedded",
            json={"embedding": qvec, "top_k": 3},
            timeout=30,
        )
        assert r.status_code == 200
        body = r.json()
        assert "sources" in body
        assert isinstance(body["sources"], list)
        assert len(body["sources"]) > 0

    def test_query_sources_have_required_fields(self, base_url):
        _ingest_corpus(base_url)
        qvec = make_embedding(dim=768, seed=99)
        r = requests.post(
            base_url + "/query_embedded",
            json={"embedding": qvec, "top_k": 5},
            timeout=30,
        )
        assert r.status_code == 200
        for src in r.json()["sources"]:
            assert "doc_id" in src
            assert "score" in src
            assert "metadata" in src
            assert "chunk_id" in src
            assert isinstance(src["score"], (int, float))

    def test_query_deduplicates_by_doc_id(self, base_url):
        """Each doc_id should appear at most once in the results."""
        _ingest_corpus(base_url)
        qvec = make_embedding(dim=768, seed=7)
        r = requests.post(
            base_url + "/query_embedded",
            json={"embedding": qvec, "top_k": 10},
            timeout=30,
        )
        assert r.status_code == 200
        sources = r.json()["sources"]
        doc_ids = [s["doc_id"] for s in sources]
        assert len(doc_ids) == len(set(doc_ids)), f"Duplicate doc_ids in results: {doc_ids}"

    def test_query_respects_top_k(self, base_url):
        _ingest_corpus(base_url)
        qvec = make_embedding(dim=768, seed=11)
        r = requests.post(
            base_url + "/query_embedded",
            json={"embedding": qvec, "top_k": 1},
            timeout=30,
        )
        assert r.status_code == 200
        assert len(r.json()["sources"]) <= 1

    def test_query_empty_embedding_returns_400(self, base_url):
        r = requests.post(
            base_url + "/query_embedded",
            json={"embedding": [], "top_k": 3},
            timeout=10,
        )
        assert r.status_code == 400

    def test_query_answer_is_empty_string(self, base_url):
        """The python-engine never generates answers; answer should always be ''."""
        _ingest_corpus(base_url)
        qvec = make_embedding(dim=768, seed=55)
        r = requests.post(
            base_url + "/query_embedded",
            json={"embedding": qvec, "top_k": 2},
            timeout=30,
        )
        assert r.status_code == 200
        assert r.json()["answer"] == ""

    def test_query_scores_are_descending(self, base_url):
        """Results should be sorted by score descending."""
        _ingest_corpus(base_url)
        qvec = make_embedding(dim=768, seed=33)
        r = requests.post(
            base_url + "/query_embedded",
            json={"embedding": qvec, "top_k": 10},
            timeout=30,
        )
        assert r.status_code == 200
        scores = [s["score"] for s in r.json()["sources"]]
        assert scores == sorted(scores, reverse=True), f"Scores not descending: {scores}"
