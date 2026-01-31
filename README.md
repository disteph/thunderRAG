# ThunderRAG

This repository contains three components:

- `ThunderRAG/`: Thunderbird add-on (XPI)
- `ocaml-server/`: OCaml control-plane and bulk ingest tooling
- `python-engine/`: Python RAG engine (FastAPI)

## Build

From the repository root:

- `make all`
  - Builds the Thunderbird add-on XPI, the OCaml server, and ensures Python dependencies are installed.

- `make xpi`
  - Builds the add-on XPI.
  - Output: `ThunderRAG/dist/thunderRAG.xpi`

- `make ocaml`
  - Installs OCaml deps via `opam install . --deps-only` and builds via `dune build`.

- `make python`
  - Creates/updates the Python virtualenv at `python-engine/.venv` and installs dependencies from `python-engine/requirements.txt`.

## Run

- `make run-ocaml`
  - Runs the OCaml server on `http://127.0.0.1:8090`.

- `make run-python`
  - Runs the Python engine on `http://127.0.0.1:8000`.

## Clean

- `make clean`
  - Cleans add-on build outputs, OCaml build artifacts, and removes the Python virtualenv.
