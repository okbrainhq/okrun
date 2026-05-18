#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <certificate-serial>" >&2
  exit 1
fi

cd "$(dirname "$0")/../.."

npm run ca -- revoke --serial "$1"

cat <<'MSG'

The local CRL was updated at .ca/crl.txt.
Upload that file to the switch server and restart or reload the service.
MSG
