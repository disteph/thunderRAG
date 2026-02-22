# ThunderRAG OCaml server — build, run, and test targets

.PHONY: build install run clean test test-quick quality

# ---------------------------------------------------------------------------
# Build / Run
# ---------------------------------------------------------------------------

build:
	dune build

# Install prompts.json to ~/.thunderRAG/ (the server reads from there,
# not from the codebase copy).  Creates the directory if needed.
install: build
	@mkdir -p ~/.thunderRAG
	@cp prompts.json ~/.thunderRAG/prompts.json
	@echo "[install] prompts.json -> ~/.thunderRAG/prompts.json"

run: build
	dune exec -- rag-email-server -p 8080

clean:
	dune clean

# ---------------------------------------------------------------------------
# Test suite (OCaml integration tests — requires running server + Ollama)
# ---------------------------------------------------------------------------

TEST_URL ?= http://localhost:8080

# Run the full Alcotest integration suite
test: build
	THUNDERRAG_TEST_URL=$(TEST_URL) dune exec test/run_tests.exe

# Quick tests only (routing + admin — no Ollama needed)
test-quick: build
	THUNDERRAG_TEST_URL=$(TEST_URL) dune exec test/run_tests.exe -- --quick

# Quality harness (ingests corpus, runs scored query battery)
quality: build
	dune exec test/quality_harness.exe -- --base-url $(TEST_URL)
