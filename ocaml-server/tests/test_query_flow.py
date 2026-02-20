"""
Test the full 2-phase query flow:
  Phase 1: POST /query           → retrieval, returns request_id + message_ids
  Phase 2: POST /query/evidence  → upload raw RFC822 for each message_id
  Phase 3: POST /query/complete  → final LLM answer generation

Also tests error paths: missing fields, unknown request_ids, missing evidence.

Requires: OCaml server + python-engine + Ollama (embed model + LLM model).
"""

import requests
import pytest

from conftest import make_rfc822


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def ingest_test_corpus(base_url):
    """Ingest a small corpus of 3 emails so that /query has something to retrieve.
    Returns a list of (raw, message_id) tuples."""
    emails = [
        make_rfc822(
            from_="Alice <alice@example.com>",
            to="Bob <bob@example.com>",
            subject="Project Falcon launch date",
            body=(
                "Hi Bob,\n\n"
                "The launch date for Project Falcon is confirmed for March 15, 2025.\n"
                "Please make sure the QA team is ready by March 10.\n\n"
                "Thanks,\nAlice"
            ),
            message_id="<falcon-launch@example.com>",
            date="Wed, 05 Feb 2025 09:00:00 +0000",
        ),
        make_rfc822(
            from_="Bob <bob@example.com>",
            to="Alice <alice@example.com>",
            subject="Re: Project Falcon launch date",
            body=(
                "Hi Alice,\n\n"
                "Got it. QA will be ready by March 10. I've also scheduled a dry run for March 12.\n"
                "The staging environment is already set up.\n\n"
                "Best,\nBob"
            ),
            message_id="<falcon-reply@example.com>",
            date="Wed, 05 Feb 2025 14:30:00 +0000",
        ),
        make_rfc822(
            from_="Carol <carol@example.com>",
            to="Team <team@example.com>",
            subject="Q1 budget review meeting",
            body=(
                "Hi team,\n\n"
                "Reminder: the Q1 budget review meeting is scheduled for February 20, 2025 at 2pm.\n"
                "Please bring your department expense reports.\n\n"
                "Regards,\nCarol"
            ),
            message_id="<budget-review@example.com>",
            date="Mon, 10 Feb 2025 08:00:00 +0000",
        ),
    ]
    for raw, mid in emails:
        r = requests.post(
            base_url + "/ingest",
            data=raw.encode("utf-8"),
            headers={
                "Content-Type": "message/rfc822",
                "X-Thunderbird-Message-Id": mid,
            },
            timeout=120,
        )
        assert r.status_code == 200, f"Corpus ingest failed for {mid}: {r.status_code} {r.text}"
    return emails


# ---------------------------------------------------------------------------
# Phase 1: /query
# ---------------------------------------------------------------------------

class TestQueryPhase1:
    """POST /query — retrieval phase."""

    def test_missing_session_id_returns_400(self, base_url):
        r = requests.post(
            base_url + "/query",
            json={"question": "hello"},
            timeout=30,
        )
        assert r.status_code == 400

    def test_missing_question_returns_400(self, base_url, session_id):
        r = requests.post(
            base_url + "/query",
            json={"session_id": session_id},
            timeout=30,
        )
        assert r.status_code == 400

    def test_empty_question_returns_400(self, base_url, session_id):
        r = requests.post(
            base_url + "/query",
            json={"session_id": session_id, "question": ""},
            timeout=30,
        )
        assert r.status_code == 400

    def test_query_returns_need_messages(self, base_url, session_id):
        """After ingesting a corpus, a query should return status=need_messages."""
        ingest_test_corpus(base_url)
        r = requests.post(
            base_url + "/query",
            json={
                "session_id": session_id,
                "question": "When is the Project Falcon launch date?",
                "top_k": 3,
            },
            timeout=60,
        )
        assert r.status_code == 200, f"Query failed: {r.status_code} {r.text}"
        body = r.json()
        assert body["status"] == "need_messages"
        assert "request_id" in body
        assert isinstance(body["message_ids"], list)
        assert len(body["message_ids"]) > 0
        assert isinstance(body["sources"], list)
        assert len(body["sources"]) > 0

    def test_query_sources_have_doc_id(self, base_url, session_id):
        """Each source in the query response should have a doc_id."""
        ingest_test_corpus(base_url)
        r = requests.post(
            base_url + "/query",
            json={
                "session_id": session_id,
                "question": "budget review",
                "top_k": 2,
            },
            timeout=60,
        )
        assert r.status_code == 200
        body = r.json()
        for src in body["sources"]:
            assert "doc_id" in src, f"Source missing doc_id: {src}"


# ---------------------------------------------------------------------------
# Phase 2: /query/evidence
# ---------------------------------------------------------------------------

class TestQueryPhase2:
    """POST /query/evidence — evidence upload."""

    def test_missing_headers_returns_400(self, base_url):
        r = requests.post(
            base_url + "/query/evidence",
            data=b"some data",
            timeout=10,
        )
        assert r.status_code == 400

    def test_unknown_request_id_returns_404(self, base_url):
        r = requests.post(
            base_url + "/query/evidence",
            data=b"some data",
            headers={
                "X-RAG-Request-Id": "nonexistent-request-id",
                "X-Thunderbird-Message-Id": "<fake@example.com>",
            },
            timeout=10,
        )
        assert r.status_code == 404

    def test_evidence_upload_succeeds(self, base_url, session_id):
        """Upload evidence for a real request_id and verify status=ok."""
        ingest_test_corpus(base_url)
        # Phase 1
        r1 = requests.post(
            base_url + "/query",
            json={
                "session_id": session_id,
                "question": "What is the launch date?",
                "top_k": 2,
            },
            timeout=60,
        )
        assert r1.status_code == 200
        q = r1.json()
        request_id = q["request_id"]
        message_ids = q["message_ids"]
        assert len(message_ids) > 0

        # Phase 2: upload a synthetic RFC822 for the first message_id
        mid = message_ids[0]
        raw, _ = make_rfc822(
            subject="Evidence for test",
            body="This is the evidence body text.",
            message_id=mid,
        )
        r2 = requests.post(
            base_url + "/query/evidence",
            data=raw.encode("utf-8"),
            headers={
                "Content-Type": "message/rfc822",
                "X-RAG-Request-Id": request_id,
                "X-Thunderbird-Message-Id": mid,
            },
            timeout=30,
        )
        assert r2.status_code == 200
        assert r2.json()["status"] == "ok"


# ---------------------------------------------------------------------------
# Phase 3: /query/complete
# ---------------------------------------------------------------------------

class TestQueryPhase3:
    """POST /query/complete — final answer generation."""

    def test_missing_fields_returns_400(self, base_url):
        r = requests.post(base_url + "/query/complete", json={}, timeout=10)
        assert r.status_code == 400

    def test_unknown_request_id_returns_404(self, base_url, session_id):
        r = requests.post(
            base_url + "/query/complete",
            json={"session_id": session_id, "request_id": "nonexistent"},
            timeout=10,
        )
        assert r.status_code == 404

    def test_session_id_mismatch_returns_400(self, base_url, session_id):
        """If session_id doesn't match the one used in /query, return 400."""
        ingest_test_corpus(base_url)
        r1 = requests.post(
            base_url + "/query",
            json={
                "session_id": session_id,
                "question": "launch date?",
                "top_k": 1,
            },
            timeout=60,
        )
        assert r1.status_code == 200
        request_id = r1.json()["request_id"]

        r = requests.post(
            base_url + "/query/complete",
            json={"session_id": "wrong-session", "request_id": request_id},
            timeout=10,
        )
        assert r.status_code == 400

    def test_missing_evidence_returns_400(self, base_url, session_id):
        """Calling /query/complete before uploading all evidence should return missing_evidence."""
        ingest_test_corpus(base_url)
        r1 = requests.post(
            base_url + "/query",
            json={
                "session_id": session_id,
                "question": "launch date?",
                "top_k": 2,
            },
            timeout=60,
        )
        assert r1.status_code == 200
        q = r1.json()
        request_id = q["request_id"]
        message_ids = q["message_ids"]
        assert len(message_ids) > 0

        # Don't upload any evidence — go straight to complete
        r = requests.post(
            base_url + "/query/complete",
            json={"session_id": session_id, "request_id": request_id},
            timeout=10,
        )
        assert r.status_code == 400
        body = r.json()
        assert body["status"] == "missing_evidence"
        assert "missing_message_ids" in body
        assert len(body["missing_message_ids"]) > 0


class TestFullQueryRoundtrip:
    """End-to-end: ingest → query → evidence → complete → verify answer."""

    @pytest.mark.timeout(300)
    def test_full_roundtrip(self, base_url, session_id):
        """Run the complete 3-phase query flow and verify we get a non-empty answer."""
        corpus = ingest_test_corpus(base_url)
        # Build a lookup from message_id to raw RFC822
        corpus_by_mid = {mid: raw for raw, mid in corpus}

        # Phase 1: query
        r1 = requests.post(
            base_url + "/query",
            json={
                "session_id": session_id,
                "question": "When is the Project Falcon launch date?",
                "top_k": 3,
            },
            timeout=60,
        )
        assert r1.status_code == 200
        q = r1.json()
        assert q["status"] == "need_messages"
        request_id = q["request_id"]
        message_ids = q["message_ids"]
        assert len(message_ids) > 0

        # Phase 2: upload evidence for each message_id
        for mid in message_ids:
            if mid in corpus_by_mid:
                raw = corpus_by_mid[mid]
            else:
                # If the server returns a doc_id we didn't ingest in this test,
                # synthesize a placeholder.
                raw, _ = make_rfc822(
                    subject="(placeholder evidence)",
                    body="No content available for this message.",
                    message_id=mid,
                )
            r2 = requests.post(
                base_url + "/query/evidence",
                data=raw.encode("utf-8"),
                headers={
                    "Content-Type": "message/rfc822",
                    "X-RAG-Request-Id": request_id,
                    "X-Thunderbird-Message-Id": mid,
                },
                timeout=30,
            )
            assert r2.status_code == 200, f"Evidence upload failed for {mid}: {r2.status_code} {r2.text}"

        # Phase 3: complete
        r3 = requests.post(
            base_url + "/query/complete",
            json={"session_id": session_id, "request_id": request_id},
            timeout=180,
        )
        assert r3.status_code == 200, f"Complete failed: {r3.status_code} {r3.text}"
        body = r3.json()
        assert "answer" in body, f"No 'answer' in response: {body}"
        assert len(body["answer"]) > 0, "Answer is empty"
        assert "sources" in body
        assert isinstance(body["sources"], list)

        # The answer should mention something about March 15 or the launch date
        answer_lower = body["answer"].lower()
        assert any(
            kw in answer_lower for kw in ["march", "falcon", "launch", "15"]
        ), f"Answer doesn't seem relevant to the question: {body['answer'][:200]}"

    @pytest.mark.timeout(300)
    def test_session_state_persists_across_turns(self, base_url, session_id):
        """After a full roundtrip, the session should have conversation history."""
        corpus = ingest_test_corpus(base_url)
        corpus_by_mid = {mid: raw for raw, mid in corpus}

        # First turn
        r1 = requests.post(
            base_url + "/query",
            json={
                "session_id": session_id,
                "question": "Who scheduled the budget review?",
                "top_k": 3,
            },
            timeout=60,
        )
        assert r1.status_code == 200
        q = r1.json()
        request_id = q["request_id"]
        for mid in q["message_ids"]:
            raw = corpus_by_mid.get(mid)
            if raw is None:
                raw, _ = make_rfc822(subject="placeholder", body="n/a", message_id=mid)
            requests.post(
                base_url + "/query/evidence",
                data=raw.encode("utf-8"),
                headers={
                    "Content-Type": "message/rfc822",
                    "X-RAG-Request-Id": request_id,
                    "X-Thunderbird-Message-Id": mid,
                },
                timeout=30,
            )
        r3 = requests.post(
            base_url + "/query/complete",
            json={"session_id": session_id, "request_id": request_id},
            timeout=180,
        )
        assert r3.status_code == 200

        # Check session debug — should have tail entries now
        r_debug = requests.post(
            base_url + "/admin/session/debug",
            json={"session_id": session_id},
            timeout=10,
        )
        assert r_debug.status_code == 200
        debug = r_debug.json()
        assert len(debug["tail"]) >= 2, f"Expected at least 2 tail entries (user+assistant), got {len(debug['tail'])}"
