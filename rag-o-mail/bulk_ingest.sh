#!/usr/bin/env bash
set -euo pipefail

port=8090
recursive=false
concurrency=4
reset_state=false

usage() {
  cat <<'EOF'
Usage:
  bulk_ingest.sh [-p PORT] [-recursive] [-concurrency N] PATH [PATH ...]

Options:
  -p PORT          OCaml server port (default: 8090)
  -recursive       Recurse into directories (default: off)
  -concurrency N   Number of concurrent ingesters (default: 4)
  -reset-state     Delete bulk ingest state file before starting (default: off)

Example:
  ./bulk_ingest.sh -p 8090 -recursive -concurrency 4 \
    ~/Library/Thunderbird/Profiles/YOURPROFILE/Mail \
    ~/Library/Thunderbird/Profiles/YOURPROFILE/ImapMail
EOF
}

json_escape() {
  local s="$1"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  printf '%s' "$s"
}

paths=()
while (($#)); do
  case "$1" in
    -p)
      shift
      [[ $# -gt 0 ]] || { usage; exit 2; }
      port="$1"
      ;;
    -recursive)
      recursive=true
      ;;
    -concurrency)
      shift
      [[ $# -gt 0 ]] || { usage; exit 2; }
      concurrency="$1"
      ;;
    -reset-state)
      reset_state=true
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      while (($#)); do
        paths+=("$1")
        shift
      done
      break
      ;;
    -*)
      echo "Unknown option: $1" 1>&2
      usage
      exit 2
      ;;
    *)
      paths+=("$1")
      ;;
  esac
  shift || true
done

if [[ ${#paths[@]} -eq 0 ]]; then
  usage
  exit 2
fi

json_paths=""
for p in "${paths[@]}"; do
  ep=$(json_escape "$p")
  if [[ -z "$json_paths" ]]; then
    json_paths="\"$ep\""
  else
    json_paths+=" , \"$ep\""
  fi
done

payload=$(cat <<EOF
{"paths": [ $json_paths ], "recursive": $recursive, "concurrency": $concurrency, "max_messages": 0, "reset_state": $reset_state}
EOF
)

curl -sS -X POST "http://localhost:${port}/admin/bulk_ingest" \
  -H 'content-type: application/json' \
  -d "$payload"
