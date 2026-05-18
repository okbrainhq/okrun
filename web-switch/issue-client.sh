#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -lt 1 || "$#" -gt 4 ]]; then
  echo "usage: $0 <client-name> [server-host:port] [output-dir] [ca-dir]" >&2
  exit 1
fi

CLIENT_NAME="$1"
SERVER="${2:-localhost:9443}"
OUTPUT_DIR="${3:-.certs/hosts/$CLIENT_NAME}"
CA_DIR="${4:-.ca}"

cd "$(dirname "$0")"

npm run --silent ca -- issue-host \
  --ca-dir "$CA_DIR" \
  --name "$CLIENT_NAME" \
  --server "$SERVER" \
  --output "$OUTPUT_DIR" >/dev/null

cat <<MSG

Host bundle ready:
  Bundle: $OUTPUT_DIR/okrun-switch-bundle.json

Paste this bundle into OkRun's Private Network > Web Switch > Host Bundle JSON field:
MSG

npm run --silent ca -- print-host-bundle --input "$OUTPUT_DIR"
