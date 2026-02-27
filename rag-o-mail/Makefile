# RAG-o-Mail server — build, run, and test targets

.PHONY: build install run clean test test-quick quality

# ---------------------------------------------------------------------------
# Build / Run
# ---------------------------------------------------------------------------

build:
	dune build

# Install settings.json and prompts.json to ~/.rag-o-mail/ (the server
# reads from there, not from the codebase copy).  Creates the directory
# if needed.  Does not overwrite existing files.
install: build
	@mkdir -p ~/.rag-o-mail
	@if [ ! -f ~/.rag-o-mail/settings.json ]; then \
		cp settings.json ~/.rag-o-mail/settings.json; \
		echo "[install] settings.json -> ~/.rag-o-mail/settings.json"; \
	else \
		echo "[install] settings.json already exists, skipping"; \
	fi
	@if [ ! -f ~/.rag-o-mail/prompts.json ]; then \
		cp prompts.json ~/.rag-o-mail/prompts.json; \
		echo "[install] prompts.json -> ~/.rag-o-mail/prompts.json"; \
	else \
		echo "[install] prompts.json already exists, skipping"; \
	fi

run: build
	dune exec -- rag-o-mail -p 8080

clean:
	dune clean

# ---------------------------------------------------------------------------
# Test suite (OCaml integration tests — requires running server + Ollama)
# ---------------------------------------------------------------------------

TEST_URL ?= http://localhost:8080

# Run the full Alcotest integration suite
test: build
	RAGOMAIL_TEST_URL=$(TEST_URL) dune exec test/run_tests.exe

# Quick tests only (routing + admin — no Ollama needed)
test-quick: build
	RAGOMAIL_TEST_URL=$(TEST_URL) dune exec test/run_tests.exe -- --quick

# Quality harness (ingests corpus, runs scored query battery)
quality: build
	dune exec test/quality_harness.exe -- --base-url $(TEST_URL)
