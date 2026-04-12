# RAG-o-Mail server — build, run, and test targets

.PHONY: build install run clean test test-quick test-setup quality

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
# Test suite (OCaml integration tests)
#
# `make test` spins up an isolated server on TEST_PORT with its own
# config dir (TEST_CONFIG) and Postgres database (TEST_DB), runs the
# Alcotest suite against it, and tears everything down.  Your
# production server on port 8080 is never touched.
#
# Override any variable on the command line:
#   make test TEST_PORT=19000 TEST_DB=my_test_db ARGS="-v"
# ---------------------------------------------------------------------------

TEST_PORT    ?= 18082
TEST_DB      ?= rag-o-mail-test
TEST_CONFIG   = $(CURDIR)/test/config
TEST_URL      = http://127.0.0.1:$(TEST_PORT)
TEST_PID      = /tmp/rag-o-mail-test.pid
ARGS         ?=

# Auto-detect PostgreSQL tools (Homebrew versioned installs hide them)
PSQL := $(or $(shell which psql 2>/dev/null),\
             $(wildcard /opt/homebrew/opt/postgresql@17/bin/psql),\
             $(wildcard /opt/homebrew/opt/postgresql@16/bin/psql),\
             $(wildcard /opt/homebrew/opt/libpq/bin/psql),\
             psql)

# Setup: create the test Postgres database and sync prompts.json.
# test/config/settings.json is checked into the repo (points at TEST_DB).
# prompts.json is copied fresh from the repo root each run to stay in sync.
test-setup:
	@$(PSQL) -d postgres -tc "SELECT 1 FROM pg_database WHERE datname='$(TEST_DB)'" \
		| grep -q 1 \
		&& echo "[test-setup] database $(TEST_DB) already exists" \
		|| { $(PSQL) -d postgres -c "CREATE DATABASE \"$(TEST_DB)\"" \
		     && echo "[test-setup] created database $(TEST_DB)"; }
	@cp prompts.json $(TEST_CONFIG)/prompts.json

# Run the full Alcotest integration suite against an isolated server.
# Lifecycle: start server → wait for ready → run tests → stop server.
test: build test-setup
	@echo "[test] starting test server on port $(TEST_PORT) (db=$(TEST_DB))..."
	@dune exec -- rag-o-mail --config-dir $(TEST_CONFIG) -p $(TEST_PORT) \
		> /tmp/rag-o-mail-test.log 2>&1 & \
		echo $$! > $(TEST_PID)
	@for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do \
		if curl -s -o /dev/null $(TEST_URL)/admin/config 2>/dev/null; then \
			echo "[test] server ready after $${i}s"; \
			break; \
		fi; \
		if [ $$i -eq 15 ]; then \
			echo "[test] ERROR: server did not start (see /tmp/rag-o-mail-test.log)"; \
			kill $$(cat $(TEST_PID)) 2>/dev/null; rm -f $(TEST_PID); \
			exit 1; \
		fi; \
		sleep 1; \
	done
	@RAGOMAIL_TEST_URL=$(TEST_URL) dune exec test/run_tests.exe -- $(ARGS); \
		rc=$$?; \
		kill $$(cat $(TEST_PID)) 2>/dev/null; rm -f $(TEST_PID); \
		echo "[test] server stopped"; \
		exit $$rc

# Quick tests only (routing + admin — no Ollama needed)
test-quick: ARGS += -q
test-quick: test

# Quality harness (ingests corpus, runs scored query battery)
quality: build
	dune exec test/quality_harness.exe -- --base-url $(TEST_URL)
