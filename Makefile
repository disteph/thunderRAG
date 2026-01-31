SHELL := /bin/bash

XPI_NAME ?= thunderRAG.xpi
PYTHON_ENGINE_DIR := python-engine
OCAML_SERVER_DIR := ocaml-server
ADDON_DIR := ThunderRAG

.PHONY: all deps xpi ocaml python \
	python-deps ocaml-deps \
	clean clean-xpi clean-ocaml clean-python \
	run-ocaml run-python

all: xpi ocaml python

deps: ocaml-deps python-deps

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
	cd "$(OCAML_SERVER_DIR)" && opam install . --deps-only -y

python: python-deps

python-deps:
	@if ! command -v python3 >/dev/null 2>&1; then \
		echo "error: python3 not found." 1>&2; \
		exit 2; \
	fi
	@if [ ! -d "$(PYTHON_ENGINE_DIR)/.venv" ]; then \
		python3 -m venv "$(PYTHON_ENGINE_DIR)/.venv"; \
	fi
	"$(PYTHON_ENGINE_DIR)/.venv/bin/python" -m pip install --upgrade pip
	"$(PYTHON_ENGINE_DIR)/.venv/bin/python" -m pip install -r "$(PYTHON_ENGINE_DIR)/requirements.txt"

clean: clean-xpi clean-ocaml clean-python

clean-xpi:
	$(MAKE) -C "$(ADDON_DIR)" clean

clean-ocaml:
	@if [ -f "$(OCAML_SERVER_DIR)/dune" ] || [ -d "$(OCAML_SERVER_DIR)/_build" ]; then \
		cd "$(OCAML_SERVER_DIR)" && opam exec -- dune clean || true; \
	fi

clean-python:
	rm -rf "$(PYTHON_ENGINE_DIR)/.venv"

run-ocaml: ocaml
	cd "$(OCAML_SERVER_DIR)" && opam exec -- dune exec rag-email-server -- -p 8090

run-python: python
	cd "$(PYTHON_ENGINE_DIR)" && .venv/bin/uvicorn app:app --host 127.0.0.1 --port 8000
