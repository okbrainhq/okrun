#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: ./issue-server.sh <server-hostname> [output-dir] [ca-dir]
       ./issue-server.sh --certs-dir <dir> <server-hostname>
       ./issue-server.sh --output <dir> --ca-dir <dir> <server-hostname>
EOF
}

HOSTNAME=""
OUTPUT_DIR=""
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
    --output)
      if [[ "$#" -lt 2 ]]; then
        echo "error: --output requires a value" >&2
        usage >&2
        exit 1
      fi
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --output=*)
      OUTPUT_DIR="${1#*=}"
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

if [[ "${#POSITIONAL[@]}" -lt 1 || "${#POSITIONAL[@]}" -gt 3 ]]; then
  usage >&2
  exit 1
fi

HOSTNAME="${POSITIONAL[0]}"
if [[ -z "$OUTPUT_DIR" && "${#POSITIONAL[@]}" -ge 2 ]]; then
  OUTPUT_DIR="${POSITIONAL[1]}"
fi
if [[ -z "$CA_DIR" && "${#POSITIONAL[@]}" -ge 3 ]]; then
  CA_DIR="${POSITIONAL[2]}"
fi

if [[ -n "$CERTS_DIR" ]]; then
  OUTPUT_DIR="${OUTPUT_DIR:-$CERTS_DIR/server}"
  CA_DIR="${CA_DIR:-$CERTS_DIR/ca}"
else
  OUTPUT_DIR="${OUTPUT_DIR:-.certs/server}"
  CA_DIR="${CA_DIR:-.ca}"
fi

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
