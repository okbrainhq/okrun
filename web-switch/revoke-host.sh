#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: ./revoke-host.sh <certificate-serial> [ca-dir]
       ./revoke-host.sh --certs-dir <dir> <certificate-serial>
       ./revoke-host.sh --ca-dir <dir> <certificate-serial>
EOF
}

SERIAL=""
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

if [[ "${#POSITIONAL[@]}" -lt 1 || "${#POSITIONAL[@]}" -gt 2 ]]; then
  usage >&2
  exit 1
fi

SERIAL="${POSITIONAL[0]}"
if [[ -z "$CA_DIR" && "${#POSITIONAL[@]}" -ge 2 ]]; then
  CA_DIR="${POSITIONAL[1]}"
fi

if [[ -z "$CA_DIR" && -n "$CERTS_DIR" ]]; then
  CA_DIR="$CERTS_DIR/ca"
fi

CA_DIR="${CA_DIR:-.ca}"

cd "$(dirname "$0")"

npm run ca -- revoke --ca-dir "$CA_DIR" --serial "$SERIAL"

cat <<MSG

The CRL was updated at $CA_DIR/crl.txt.
Upload that file to the switch server and restart or reload the service.
MSG
