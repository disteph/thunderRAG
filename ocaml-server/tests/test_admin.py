"""
Test admin / maintenance endpoints.
"""

import requests


class TestAdminSessionReset:
    """POST /admin/session/reset"""

    def test_missing_session_id_returns_400(self, base_url):
        r = requests.post(base_url + "/admin/session/reset", json={}, timeout=10)
        assert r.status_code == 400

    def test_empty_session_id_returns_400(self, base_url):
        r = requests.post(
            base_url + "/admin/session/reset",
            json={"session_id": ""},
            timeout=10,
        )
        assert r.status_code == 400

    def test_reset_nonexistent_session_succeeds(self, base_url, session_id):
        """Resetting a session that doesn't exist should still return ok."""
        r = requests.post(
            base_url + "/admin/session/reset",
            json={"session_id": session_id},
            timeout=10,
        )
        assert r.status_code == 200
        body = r.json()
        assert body["status"] == "ok"
        assert body["session_id"] == session_id


class TestAdminSessionDebug:
    """POST /admin/session/debug"""

    def test_missing_session_id_returns_400(self, base_url):
        r = requests.post(base_url + "/admin/session/debug", json={}, timeout=10)
        assert r.status_code == 400

    def test_debug_nonexistent_session(self, base_url, session_id):
        """Debugging a session that hasn't been used yet should return empty state."""
        r = requests.post(
            base_url + "/admin/session/debug",
            json={"session_id": session_id},
            timeout=10,
        )
        assert r.status_code == 200
        body = r.json()
        assert body["session_id"] == session_id
        assert isinstance(body["tail"], list)


class TestAdminBulkStateReset:
    """POST /admin/bulk_state/reset"""

    def test_bulk_state_reset_succeeds(self, base_url):
        r = requests.post(base_url + "/admin/bulk_state/reset", timeout=10)
        assert r.status_code == 200
        body = r.json()
        assert body["status"] == "ok"
        assert "path" in body


class TestAdminReset:
    """POST /admin/reset — wipes the entire vector index.

    WARNING: This test actually resets the index.  It is placed in its own class
    so it can be deselected easily (``pytest -k 'not TestAdminReset'``).
    """

    def test_reset_returns_ok(self, base_url):
        r = requests.post(base_url + "/admin/reset", timeout=30)
        # The OCaml server proxies to python-engine; both must be up.
        assert r.status_code == 200
