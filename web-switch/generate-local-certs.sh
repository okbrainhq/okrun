#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: ./generate-local-certs.sh
       ./generate-local-certs.sh --certs-dir <dir>

Options:
  --certs-dir <dir>       Cert root containing ca/, server/, and hosts/.
  --ca-dir <dir>          Override CA directory.
  --server-output <dir>   Override server certificate output directory.
  --hosts-dir <dir>       Override host certificate root directory.
  --hostname <host>       Server certificate hostname. Default: localhost.
  --server <host:port>    Host bundle server address. Default: localhost:9443.
EOF
}

CERTS_DIR=""
CA_DIR=""
SERVER_OUTPUT=""
HOSTS_DIR=""
HOSTNAME="localhost"
SERVER="localhost:9443"

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
    --server-output)
      if [[ "$#" -lt 2 ]]; then
        echo "error: --server-output requires a value" >&2
        usage >&2
        exit 1
      fi
      SERVER_OUTPUT="$2"
      shift 2
      ;;
    --server-output=*)
      SERVER_OUTPUT="${1#*=}"
      shift
      ;;
    --hosts-dir)
      if [[ "$#" -lt 2 ]]; then
        echo "error: --hosts-dir requires a value" >&2
        usage >&2
        exit 1
      fi
      HOSTS_DIR="$2"
      shift 2
      ;;
    --hosts-dir=*)
      HOSTS_DIR="${1#*=}"
      shift
      ;;
    --hostname)
      if [[ "$#" -lt 2 ]]; then
        echo "error: --hostname requires a value" >&2
        usage >&2
        exit 1
      fi
      HOSTNAME="$2"
      shift 2
      ;;
    --hostname=*)
      HOSTNAME="${1#*=}"
      shift
      ;;
    --server)
      if [[ "$#" -lt 2 ]]; then
        echo "error: --server requires a value" >&2
        usage >&2
        exit 1
      fi
      SERVER="$2"
      shift 2
      ;;
    --server=*)
      SERVER="${1#*=}"
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
      echo "error: unexpected argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -n "$CERTS_DIR" ]]; then
  CA_DIR="${CA_DIR:-$CERTS_DIR/ca}"
  SERVER_OUTPUT="${SERVER_OUTPUT:-$CERTS_DIR/server}"
  HOSTS_DIR="${HOSTS_DIR:-$CERTS_DIR/hosts}"
else
  CA_DIR="${CA_DIR:-.ca}"
  SERVER_OUTPUT="${SERVER_OUTPUT:-.certs/server}"
  HOSTS_DIR="${HOSTS_DIR:-.certs/hosts}"
fi

cd "$(dirname "$0")"

./init-ca.sh --ca-dir "$CA_DIR"
./issue-server.sh --ca-dir "$CA_DIR" --output "$SERVER_OUTPUT" "$HOSTNAME"
./issue-client.sh --ca-dir "$CA_DIR" --output "$HOSTS_DIR/host-a" host-a "$SERVER"
./issue-client.sh --ca-dir "$CA_DIR" --output "$HOSTS_DIR/host-b" host-b "$SERVER"

cat <<MSG

Local switch bundles are ready.

Server bundle:
  $SERVER_OUTPUT/okrun-switch-server-bundle.json

Host bundles:
  $HOSTS_DIR/host-a/okrun-switch-bundle.json
  $HOSTS_DIR/host-b/okrun-switch-bundle.json

Run the server:
  npm run start -- --server-bundle "$SERVER_OUTPUT/okrun-switch-server-bundle.json" --crl "$CA_DIR/crl.txt"

Run e2e tests:
  npm test
MSG
