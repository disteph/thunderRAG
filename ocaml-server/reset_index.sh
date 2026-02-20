#!/usr/bin/env bash
set -euo pipefail

port=8080

bulk_state_path="${RAG_BULK_STATE:-${HOME}/.thunderRAG/bulk_ingest_state.json}"

usage() {
  cat <<'EOF'
Usage:
  reset_index.sh [-p PORT]

Options:
  -p PORT   OCaml server port (default: 8080)

This calls the OCaml server admin endpoint which clears the Python index.
Use with care.

This also deletes the bulk ingest resume state file if present:
  - $RAG_BULK_STATE, or
  - ~/.thunderRAG/bulk_ingest_state.json

Example:
  ./reset_index.sh -p 8080
EOF
}

while (($#)); do
  case "$1" in
    -p)
      shift
      [[ $# -gt 0 ]] || { usage; exit 2; }
      port="$1"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    *)
      echo "Unknown option: $1" 1>&2
      usage
      exit 2
      ;;
  esac
  shift || true
done

if [[ -n "${bulk_state_path}" ]]; then
  rm -f "${bulk_state_path}.tmp" "${bulk_state_path}" || true
fi

curl -sS -X POST "http://localhost:${port}/admin/reset" \
  -H 'content-type: application/json' \
  -d '{}'
