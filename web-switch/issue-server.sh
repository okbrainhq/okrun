#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -lt 1 || "$#" -gt 3 ]]; then
  echo "usage: $0 <server-hostname> [output-dir] [ca-dir]" >&2
  exit 1
fi

HOSTNAME="$1"
OUTPUT_DIR="${2:-.certs/server}"
CA_DIR="${3:-.ca}"

cd "$(dirname "$0")"

npm run --silent ca -- issue-server \
  --ca-dir "$CA_DIR" \
  --hostname "$HOSTNAME" \
  --output "$OUTPUT_DIR" >/dev/null

cat <<MSG

Server bundle ready:
  Bundle: $OUTPUT_DIR/okrun-switch-server-bundle.json

Start web-switch with:
  npm run start -- --server-bundle "$OUTPUT_DIR/okrun-switch-server-bundle.json" --crl "$CA_DIR/crl.txt"
MSG
