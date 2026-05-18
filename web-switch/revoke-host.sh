#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -lt 1 || "$#" -gt 2 ]]; then
  echo "usage: $0 <certificate-serial> [ca-dir]" >&2
  exit 1
fi

SERIAL="$1"
CA_DIR="${2:-.ca}"

cd "$(dirname "$0")"

npm run ca -- revoke --ca-dir "$CA_DIR" --serial "$SERIAL"

cat <<MSG

The CRL was updated at $CA_DIR/crl.txt.
Upload that file to the switch server and restart or reload the service.
MSG
