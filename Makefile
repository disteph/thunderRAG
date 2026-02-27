SHELL := /bin/bash

XPI_NAME ?= thunderRAG.xpi
SERVER_DIR := rag-o-mail
ADDON_DIR := ThunderRAG

.PHONY: all deps xpi ocaml ocaml-deps \
	clean clean-xpi clean-ocaml \
	setup-db run

all: xpi ocaml

deps: ocaml-deps

xpi:
	$(MAKE) -C "$(ADDON_DIR)" xpi XPI_NAME="$(XPI_NAME)"

ocaml: ocaml-deps
	cd "$(SERVER_DIR)" && opam exec -- dune build

ocaml-deps:
	@if ! command -v opam >/dev/null 2>&1; then \
		echo "error: opam not found. Install opam first." 1>&2; \
		exit 2; \
	fi
	@if ! command -v dune >/dev/null 2>&1; then \
		echo "error: dune not found. Ensure your opam switch has dune installed." 1>&2; \
		exit 2; \
	fi
	@echo "Note: system deps required: brew install postgresql@17 pgvector libpg_query"
	cd "$(SERVER_DIR)" && opam install . --deps-only -y

setup-db:
	@echo "Creating rag-o-mail database (if not exists) and enabling pgvector..."
	@createdb rag-o-mail 2>/dev/null || true
	@psql -d rag-o-mail -c "CREATE EXTENSION IF NOT EXISTS vector;" 2>&1

clean: clean-xpi clean-ocaml

clean-xpi:
	$(MAKE) -C "$(ADDON_DIR)" clean

clean-ocaml:
	@if [ -f "$(SERVER_DIR)/dune" ] || [ -d "$(SERVER_DIR)/_build" ]; then \
		cd "$(SERVER_DIR)" && opam exec -- dune clean || true; \
	fi

run: ocaml
	cd "$(SERVER_DIR)" && opam exec -- dune exec rag-o-mail -- -p 8090
