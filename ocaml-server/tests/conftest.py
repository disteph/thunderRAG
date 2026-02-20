"""
Shared pytest fixtures for the OCaml server integration tests.

These tests hit the running OCaml server over HTTP.  They require:
  - The OCaml server running (default http://localhost:8080)
  - The python-engine running (default http://localhost:8000)
  - Ollama running with the configured embed + LLM models pulled

Override the server URL with:
    THUNDERRAG_TEST_URL=http://host:port pytest
"""

import os
import uuid

import pytest
import requests

DEFAULT_BASE_URL = "http://localhost:8080"


@pytest.fixture(scope="session")
def base_url():
    """Base URL of the running OCaml server."""
    return os.environ.get("THUNDERRAG_TEST_URL", DEFAULT_BASE_URL).rstrip("/")


@pytest.fixture(scope="session")
def server_reachable(base_url):
    """Skip the entire session if the server is not reachable."""
    try:
        # Any endpoint will do; a bad method on root gives 405.
        r = requests.get(base_url + "/", timeout=5)
        # 405 Method Not Allowed is fine — it means the server is up.
        if r.status_code not in (200, 404, 405):
            pytest.skip(f"OCaml server returned unexpected status {r.status_code}")
    except requests.ConnectionError:
        pytest.skip(f"OCaml server not reachable at {base_url}")


@pytest.fixture(autouse=True)
def require_server(server_reachable):
    """Auto-use: every test automatically requires the server to be up."""
    pass


@pytest.fixture()
def session_id():
    """A fresh, unique session ID for each test that needs one."""
    return f"test-session-{uuid.uuid4().hex[:12]}"


def make_rfc822(
    *,
    from_="Alice <alice@example.com>",
    to="Bob <bob@example.com>",
    subject="Test email",
    message_id=None,
    body="This is a test email body.\nIt has multiple lines.",
    cc="",
    date="Mon, 10 Feb 2025 09:00:00 +0000",
):
    """Build a minimal RFC822 message for testing."""
    if message_id is None:
        message_id = f"<test-{uuid.uuid4().hex[:16]}@example.com>"
    headers = [
        f"From: {from_}",
        f"To: {to}",
        f"Subject: {subject}",
        f"Message-Id: {message_id}",
        f"Date: {date}",
        "MIME-Version: 1.0",
        "Content-Type: text/plain; charset=UTF-8",
        "Content-Transfer-Encoding: 8bit",
    ]
    if cc:
        headers.insert(3, f"Cc: {cc}")
    return "\r\n".join(headers) + "\r\n\r\n" + body, message_id
