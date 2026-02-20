"""
Test basic HTTP routing: methods, unknown paths, content types.
"""

import requests


class TestRouting:
    """Verify that the server routes requests correctly and rejects bad ones."""

    def test_get_root_returns_405(self, base_url):
        """GET on any path should return 405 Method Not Allowed (server is POST-only)."""
        r = requests.get(base_url + "/", timeout=10)
        assert r.status_code == 405

    def test_get_ingest_returns_405(self, base_url):
        r = requests.get(base_url + "/ingest", timeout=10)
        assert r.status_code == 405

    def test_post_unknown_path_returns_404(self, base_url):
        r = requests.post(base_url + "/nonexistent", timeout=10)
        assert r.status_code == 404

    def test_post_unknown_nested_path_returns_404(self, base_url):
        r = requests.post(base_url + "/admin/nonexistent", timeout=10)
        assert r.status_code == 404
