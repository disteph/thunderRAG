# ThunderRAG python-engine — run, and test targets

.PHONY: run clean test test-fast test-roundtrip test-collect venv deps

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

VENV       := .venv
PYTHON     := $(VENV)/bin/python3
PIP        := $(VENV)/bin/pip
UVICORN    := $(VENV)/bin/uvicorn
PORT       ?= 8000

# Create the app virtualenv if it doesn't exist
$(VENV)/bin/activate: requirements.txt
	python3 -m venv $(VENV)
	$(PIP) install --upgrade pip -q
	$(PIP) install -r requirements.txt -q
	@touch $(VENV)/bin/activate

run: $(VENV)/bin/activate
	$(UVICORN) app:app --port $(PORT)

clean:
	rm -rf $(VENV) tests/.venv data/__pycache__ __pycache__

# ---------------------------------------------------------------------------
# Test suite (integration tests in tests/)
# ---------------------------------------------------------------------------

TEST_VENV  := tests/.venv
TEST_PYTEST := $(TEST_VENV)/bin/pytest
TEST_PIP   := $(TEST_VENV)/bin/pip
TEST_URL   ?= http://localhost:$(PORT)

# Create the test virtualenv if it doesn't exist
$(TEST_PYTEST): tests/requirements.txt
	python3 -m venv $(TEST_VENV)
	$(TEST_PIP) install --upgrade pip -q
	$(TEST_PIP) install -r tests/requirements.txt -q
	@touch $(TEST_PYTEST)

# Install / update test dependencies
deps: $(TEST_PYTEST)
	$(TEST_PIP) install -r tests/requirements.txt -q

# Run the full test suite
test: $(TEST_PYTEST)
	PYTHON_ENGINE_TEST_URL=$(TEST_URL) $(TEST_PYTEST) tests/ -v --timeout=60

# Fast tests only (health + routing — no index data needed)
test-fast: $(TEST_PYTEST)
	PYTHON_ENGINE_TEST_URL=$(TEST_URL) $(TEST_PYTEST) tests/test_health.py -v --timeout=10

# Full ingest → query → delete roundtrip
test-roundtrip: $(TEST_PYTEST)
	PYTHON_ENGINE_TEST_URL=$(TEST_URL) $(TEST_PYTEST) tests/test_roundtrip.py -v --timeout=60

# Dry-run: collect tests without executing (syntax/import check)
test-collect: $(TEST_PYTEST)
	$(TEST_PYTEST) tests/ --collect-only -q
