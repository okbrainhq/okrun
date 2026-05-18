#!/usr/bin/env bash
set -euo pipefail

CA_DIR="${1:-.ca}"

cd "$(dirname "$0")"

npm run ca -- init --ca-dir "$CA_DIR"

cat <<MSG

CA ready:
  CA directory: $CA_DIR
  CA cert:      $CA_DIR/ca-cert.pem
  CA key:       $CA_DIR/ca-key.pem
  CRL:          $CA_DIR/crl.txt
MSG
