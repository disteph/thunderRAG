# ThunderRAG

This repository contains two components:

- `ThunderRAG/`: Thunderbird add-on (XPI)
- `ocaml-server/`: OCaml RAG server with PostgreSQL/pgvector vector store

## System Prerequisites

```bash
brew install postgresql@17 pgvector libpg_query
brew services start postgresql@17
make setup-db
```

> **Apple Silicon note:** if `opam install` fails finding `libpq`, export:
> ```bash
> export PKG_CONFIG_PATH="/opt/homebrew/lib/postgresql@17/pkgconfig:$PKG_CONFIG_PATH"
> ```

## Build

From the repository root:

- `make all` — Builds the Thunderbird add-on XPI and the OCaml server.
- `make xpi` — Builds the add-on XPI (`ThunderRAG/dist/thunderRAG.xpi`).
- `make ocaml` — Installs OCaml deps via opam and builds via dune.
- `make setup-db` — Creates the `thunderrag` database and enables the pgvector extension.

## Run

- `make run` — Builds and runs the OCaml server on `http://127.0.0.1:8090`.

## Clean

- `make clean` — Cleans add-on build outputs and OCaml build artifacts.
