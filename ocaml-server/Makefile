# ThunderRAG OCaml server — build, run, and test targets

.PHONY: build run clean test test-fast test-roundtrip test-collect venv deps

# ---------------------------------------------------------------------------
# Build / Run
# ---------------------------------------------------------------------------

build:
	dune build

run: build
	dune exec -- rag-email-server -p 8080

clean:
	dune clean

# ---------------------------------------------------------------------------
# Test suite (Python integration tests in tests/)
# ---------------------------------------------------------------------------

VENV       := tests/.venv
PYTEST     := $(VENV)/bin/pytest
PIP        := $(VENV)/bin/pip
PYTHON     := $(VENV)/bin/python3
TEST_URL   ?= http://localhost:8080

# Create the virtualenv if it doesn't exist
venv: $(PYTEST)

$(PYTEST): tests/requirements.txt
	python3 -m venv $(VENV)
	$(PIP) install --upgrade pip -q
	$(PIP) install -r tests/requirements.txt -q
	@touch $(PYTEST)

# Install / update test dependencies
deps: $(PYTEST)
	$(PIP) install -r tests/requirements.txt -q

# Run the full test suite
test: $(PYTEST)
	THUNDERRAG_TEST_URL=$(TEST_URL) $(PYTEST) tests/ -v --timeout=300

# Fast tests only (routing + admin — no Ollama needed)
test-fast: $(PYTEST)
	THUNDERRAG_TEST_URL=$(TEST_URL) $(PYTEST) tests/test_routing.py tests/test_admin.py -v --timeout=30

# End-to-end roundtrip only (requires Ollama + python-engine)
test-roundtrip: $(PYTEST)
	THUNDERRAG_TEST_URL=$(TEST_URL) $(PYTEST) tests/test_query_flow.py::TestFullQueryRoundtrip -v --timeout=300

# Dry-run: collect tests without executing (syntax/import check)
test-collect: $(PYTEST)
	$(PYTEST) tests/ --collect-only -q
