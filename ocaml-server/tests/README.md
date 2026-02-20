# OCaml Server Integration Tests

External HTTP integration tests for the ThunderRAG OCaml server. These tests exercise every endpoint by making real HTTP requests and inspecting the responses.

## Prerequisites

All three backend services must be running:

1. **python-engine** (default `http://localhost:8000`)
   ```bash
   cd python-engine && uvicorn app:app --port 8000
   ```

2. **OCaml server** (default `http://localhost:8080`)
   ```bash
   cd ocaml-server && dune exec -- rag-email-server -p 8080
   ```

3. **Ollama** with the configured models pulled:
   ```bash
   ollama pull nomic-embed-text
   ollama pull llama3
   ```

## Setup

```bash
cd ocaml-server/tests
pip install -r requirements.txt
```

## Running

```bash
# Run all tests (server must be at localhost:8080)
pytest -v

# Custom server URL
THUNDERRAG_TEST_URL=http://localhost:9090 pytest -v

# Skip the full reset test (it wipes the vector index)
pytest -v -k 'not TestAdminReset'

# Run only the fast routing/admin tests (no Ollama needed for these)
pytest -v test_routing.py test_admin.py

# Run only the full end-to-end roundtrip
pytest -v test_query_flow.py::TestFullQueryRoundtrip

# Show print output (useful for debugging)
pytest -v -s
```

## Test Structure

| File | What it tests | Needs Ollama? |
|---|---|---|
| `test_routing.py` | HTTP method/path routing (405, 404) | No |
| `test_admin.py` | Session debug/reset, bulk state reset, index reset | No (except `TestAdminReset`) |
| `test_ingest.py` | `/ingest` with plain, HTML, multipart, RFC2047, empty body | Yes (embed) |
| `test_delete.py` | `/admin/delete` — ingest then delete | Yes (embed) |
| `test_query_flow.py` | Full 2-phase query: `/query` → `/query/evidence` → `/query/complete` | Yes (embed + LLM) |

## Notes

- Tests that require Ollama embedding take ~5-15s each (model load + inference).
- The full roundtrip test (`TestFullQueryRoundtrip`) can take 30-120s depending on the LLM model.
- Tests automatically skip if the OCaml server is not reachable.
- Each test uses a unique `session_id` and `message_id` to avoid cross-test interference.
