"""
Test the /admin/delete endpoint.
"""

import requests

from conftest import make_rfc822


class TestAdminDelete:
    """POST /admin/delete — delete a doc_id from the vector index."""

    def test_delete_nonexistent_doc_id(self, base_url):
        """Deleting a doc_id that doesn't exist should still return 200 (idempotent)."""
        r = requests.post(
            base_url + "/admin/delete",
            json={"id": "<nonexistent-delete-test@example.com>"},
            timeout=30,
        )
        # python-engine treats delete of unknown doc_id as a no-op success
        assert r.status_code == 200

    def test_ingest_then_delete(self, base_url):
        """Ingest a message, delete it, and verify the delete succeeds."""
        raw, message_id = make_rfc822(
            subject="Delete test email",
            body="This email will be ingested and then deleted.",
            message_id="<test-delete-roundtrip@example.com>",
        )
        # Ingest
        r1 = requests.post(
            base_url + "/ingest",
            data=raw.encode("utf-8"),
            headers={
                "Content-Type": "message/rfc822",
                "X-Thunderbird-Message-Id": message_id,
            },
            timeout=120,
        )
        assert r1.status_code == 200

        # Delete
        r2 = requests.post(
            base_url + "/admin/delete",
            json={"id": message_id},
            timeout=30,
        )
        assert r2.status_code == 200
