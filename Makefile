SHELL := /bin/bash

XPI_NAME ?= thunderRAG.xpi
OCAML_SERVER_DIR := ocaml-server
ADDON_DIR := ThunderRAG

.PHONY: all deps xpi ocaml ocaml-deps \
	clean clean-xpi clean-ocaml \
	setup-db run

all: xpi ocaml

deps: ocaml-deps

xpi:
	$(MAKE) -C "$(ADDON_DIR)" xpi XPI_NAME="$(XPI_NAME)"

ocaml: ocaml-deps
	cd "$(OCAML_SERVER_DIR)" && opam exec -- dune build

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
	cd "$(OCAML_SERVER_DIR)" && opam install . --deps-only -y

setup-db:
	@echo "Creating thunderrag database (if not exists) and enabling pgvector..."
	@createdb thunderrag 2>/dev/null || true
	@psql -d thunderrag -c "CREATE EXTENSION IF NOT EXISTS vector;" 2>&1

clean: clean-xpi clean-ocaml

clean-xpi:
	$(MAKE) -C "$(ADDON_DIR)" clean

clean-ocaml:
	@if [ -f "$(OCAML_SERVER_DIR)/dune" ] || [ -d "$(OCAML_SERVER_DIR)/_build" ]; then \
		cd "$(OCAML_SERVER_DIR)" && opam exec -- dune clean || true; \
	fi

run: ocaml
	cd "$(OCAML_SERVER_DIR)" && opam exec -- dune exec rag-email-server -- -p 8090
