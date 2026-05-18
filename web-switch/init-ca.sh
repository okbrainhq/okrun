#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: ./init-ca.sh [ca-dir]
       ./init-ca.sh --certs-dir <dir>
       ./init-ca.sh --ca-dir <dir>
EOF
}

CA_DIR=""
CERTS_DIR=""
POSITIONAL=()

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --certs-dir)
      if [[ "$#" -lt 2 ]]; then
        echo "error: --certs-dir requires a value" >&2
        usage >&2
        exit 1
      fi
      CERTS_DIR="$2"
      shift 2
      ;;
    --certs-dir=*)
      CERTS_DIR="${1#*=}"
      shift
      ;;
    --ca-dir)
      if [[ "$#" -lt 2 ]]; then
        echo "error: --ca-dir requires a value" >&2
        usage >&2
        exit 1
      fi
      CA_DIR="$2"
      shift 2
      ;;
    --ca-dir=*)
      CA_DIR="${1#*=}"
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --*)
      echo "error: unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done

if [[ "${#POSITIONAL[@]}" -gt 1 ]]; then
  echo "error: too many positional arguments" >&2
  usage >&2
  exit 1
fi

if [[ -z "$CA_DIR" && "${#POSITIONAL[@]}" -eq 1 ]]; then
  CA_DIR="${POSITIONAL[0]}"
fi

if [[ -z "$CA_DIR" && -n "$CERTS_DIR" ]]; then
  CA_DIR="$CERTS_DIR/ca"
fi

CA_DIR="${CA_DIR:-.ca}"

cd "$(dirname "$0")"

npm run ca -- init --ca-dir "$CA_DIR"

cat <<MSG

CA ready:
  CA directory: $CA_DIR
  CA cert:      $CA_DIR/ca-cert.pem
  CA key:       $CA_DIR/ca-key.pem
  CRL:          $CA_DIR/crl.txt
MSG
