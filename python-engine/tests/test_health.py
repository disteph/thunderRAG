"""
Test the /health endpoint and basic routing.
"""

import requests


class TestHealth:
    """GET /health — readiness check."""

    def test_health_returns_ok(self, base_url):
        r = requests.get(base_url + "/health", timeout=10)
        assert r.status_code == 200
        body = r.json()
        assert body["status"] == "ok"
        assert "data_dir" in body
        assert "faiss_loaded" in body
        assert "dim" in body


class TestRouting:
    """Verify unknown endpoints return appropriate errors."""

    def test_unknown_endpoint_returns_404(self, base_url):
        r = requests.post(base_url + "/nonexistent", timeout=10)
        assert r.status_code in (404, 405)

    def test_get_on_post_endpoint_returns_405(self, base_url):
        r = requests.get(base_url + "/ingest_embedded", timeout=10)
        assert r.status_code == 405
