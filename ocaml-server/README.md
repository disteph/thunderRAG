# ocaml-server

Small HTTP server to test the Thunderbird filter action.

## Endpoint

- `POST /ingest`
  - Expects body `Content-Type: message/rfc822`
  - Prints decoded `text/plain` parts to stdout (ignores all other parts, incl attachments)

## Build / Run

Using opam:

1. `opam switch create . ocaml-base-compiler.5.2.0` (or any OCaml 5.x)
2. `opam install . --deps-only`
3. `dune build`
4. `dune exec -- rag-email-server -p 8080`

Then configure the Thunderbird action argument as:

- `http://localhost:8080/ingest`

