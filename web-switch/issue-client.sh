#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: ./issue-client.sh <client-name> [server-host:port] [output-dir] [ca-dir]
       ./issue-client.sh --certs-dir <dir> <client-name> [server-host:port]
       ./issue-client.sh --output <dir> --ca-dir <dir> <client-name> [server-host:port]
EOF
}

CLIENT_NAME=""
SERVER=""
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

if [[ "${#POSITIONAL[@]}" -lt 1 || "${#POSITIONAL[@]}" -gt 4 ]]; then
  usage >&2
  exit 1
fi

CLIENT_NAME="${POSITIONAL[0]}"
if [[ "${#POSITIONAL[@]}" -ge 2 ]]; then
  SERVER="${POSITIONAL[1]}"
fi
if [[ -z "$OUTPUT_DIR" && "${#POSITIONAL[@]}" -ge 3 ]]; then
  OUTPUT_DIR="${POSITIONAL[2]}"
fi
if [[ -z "$CA_DIR" && "${#POSITIONAL[@]}" -ge 4 ]]; then
  CA_DIR="${POSITIONAL[3]}"
fi

SERVER="${SERVER:-localhost:9443}"
if [[ -n "$CERTS_DIR" ]]; then
  OUTPUT_DIR="${OUTPUT_DIR:-$CERTS_DIR/hosts/$CLIENT_NAME}"
  CA_DIR="${CA_DIR:-$CERTS_DIR/ca}"
else
  OUTPUT_DIR="${OUTPUT_DIR:-.certs/hosts/$CLIENT_NAME}"
  CA_DIR="${CA_DIR:-.ca}"
fi

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
