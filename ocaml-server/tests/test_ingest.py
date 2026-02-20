"""
Test the /ingest endpoint.

Requires: OCaml server + python-engine + Ollama (for embedding).
"""

import requests

from conftest import make_rfc822


class TestIngest:
    """POST /ingest — single message ingestion."""

    def test_ingest_plain_text_email(self, base_url):
        """Ingest a simple text/plain email and verify the response."""
        raw, message_id = make_rfc822(
            subject="Integration test: plain text",
            body="The quick brown fox jumps over the lazy dog.\n\nThis is a test message for ThunderRAG integration testing.",
        )
        r = requests.post(
            base_url + "/ingest",
            data=raw.encode("utf-8"),
            headers={
                "Content-Type": "message/rfc822",
                "X-Thunderbird-Message-Id": message_id,
            },
            timeout=120,
        )
        assert r.status_code == 200, f"Ingest failed: {r.status_code} {r.text}"
        body = r.json()
        # python-engine returns {"status": "ok", ...} on success
        assert body.get("status") == "ok", f"Unexpected response: {body}"

    def test_ingest_html_email(self, base_url):
        """Ingest an HTML email — the server should strip tags and extract text."""
        html_body = "<html><body><h1>Hello</h1><p>This is <b>bold</b> text in an HTML email.</p></body></html>"
        raw_text = (
            "From: sender@example.com\r\n"
            "To: receiver@example.com\r\n"
            "Subject: Integration test: HTML\r\n"
            "Message-Id: <test-html-ingest@example.com>\r\n"
            "Date: Mon, 10 Feb 2025 10:00:00 +0000\r\n"
            "MIME-Version: 1.0\r\n"
            "Content-Type: text/html; charset=UTF-8\r\n"
            "\r\n"
            + html_body
        )
        r = requests.post(
            base_url + "/ingest",
            data=raw_text.encode("utf-8"),
            headers={
                "Content-Type": "message/rfc822",
                "X-Thunderbird-Message-Id": "<test-html-ingest@example.com>",
            },
            timeout=120,
        )
        assert r.status_code == 200, f"Ingest failed: {r.status_code} {r.text}"

    def test_ingest_multipart_email(self, base_url):
        """Ingest a multipart/alternative email with text/plain + text/html parts."""
        boundary = "----=_Part_12345"
        raw_text = (
            "From: multi@example.com\r\n"
            "To: receiver@example.com\r\n"
            "Subject: Integration test: multipart\r\n"
            "Message-Id: <test-multipart-ingest@example.com>\r\n"
            "Date: Mon, 10 Feb 2025 11:00:00 +0000\r\n"
            "MIME-Version: 1.0\r\n"
            f"Content-Type: multipart/alternative; boundary=\"{boundary}\"\r\n"
            "\r\n"
            f"--{boundary}\r\n"
            "Content-Type: text/plain; charset=UTF-8\r\n"
            "\r\n"
            "Plain text part of the multipart email.\r\n"
            f"--{boundary}\r\n"
            "Content-Type: text/html; charset=UTF-8\r\n"
            "\r\n"
            "<html><body><p>HTML part of the multipart email.</p></body></html>\r\n"
            f"--{boundary}--\r\n"
        )
        r = requests.post(
            base_url + "/ingest",
            data=raw_text.encode("utf-8"),
            headers={
                "Content-Type": "message/rfc822",
                "X-Thunderbird-Message-Id": "<test-multipart-ingest@example.com>",
            },
            timeout=120,
        )
        assert r.status_code == 200, f"Ingest failed: {r.status_code} {r.text}"

    def test_ingest_email_with_rfc2047_subject(self, base_url):
        """Ingest an email with an RFC2047-encoded subject — the server should decode it."""
        raw, message_id = make_rfc822(
            subject="=?UTF-8?B?VGVzdCBzdWJqZWN0IGVuY29kZWQ=?=",
            body="Body of the RFC2047 test email.",
        )
        r = requests.post(
            base_url + "/ingest",
            data=raw.encode("utf-8"),
            headers={
                "Content-Type": "message/rfc822",
                "X-Thunderbird-Message-Id": message_id,
            },
            timeout=120,
        )
        assert r.status_code == 200, f"Ingest failed: {r.status_code} {r.text}"

    def test_ingest_empty_body_still_succeeds(self, base_url):
        """An email with an empty body should still be accepted (metadata is indexed)."""
        raw, message_id = make_rfc822(body="")
        r = requests.post(
            base_url + "/ingest",
            data=raw.encode("utf-8"),
            headers={
                "Content-Type": "message/rfc822",
                "X-Thunderbird-Message-Id": message_id,
            },
            timeout=120,
        )
        # The server should accept it (even if the body is empty/trivial).
        assert r.status_code == 200, f"Ingest failed: {r.status_code} {r.text}"

    def test_ingest_duplicate_is_idempotent(self, base_url):
        """Ingesting the same message_id twice should succeed both times."""
        raw, message_id = make_rfc822(
            subject="Duplicate test",
            body="This message will be ingested twice.",
            message_id="<test-duplicate-ingest@example.com>",
        )
        headers = {
            "Content-Type": "message/rfc822",
            "X-Thunderbird-Message-Id": message_id,
        }
        r1 = requests.post(base_url + "/ingest", data=raw.encode("utf-8"), headers=headers, timeout=120)
        assert r1.status_code == 200
        r2 = requests.post(base_url + "/ingest", data=raw.encode("utf-8"), headers=headers, timeout=120)
        assert r2.status_code == 200
