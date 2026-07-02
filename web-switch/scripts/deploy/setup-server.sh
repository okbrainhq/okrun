#!/usr/bin/env bash

# setup-server.sh
# Purpose: Orchestrates an idempotent okrun-switch setup on a Linux VM.
# Usage: ./scripts/deploy/setup-server.sh [USER@HOST] [--upload-certs <certs-dir>] [--restart-only]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WEB_SWITCH_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DEPLOY_CONFIG="$WEB_SWITCH_ROOT/.deploy.switch"

usage() {
  cat <<'EOF'
Usage: ./scripts/deploy/setup-server.sh [USER@HOST] [--upload-certs <certs-dir>] [--restart-only]

Reads deployment settings from web-switch/.deploy.switch.

Options:
  --upload-certs [dir]   Upload certs from an explicit cert root before setup.
  --certs-dir <dir>      Cert root containing ca/ and server/ directories.
  --server-cert-dir <dir>
                         Directory containing server-cert.pem and server-key.pem.
  --ca-dir <dir>         Directory containing ca-cert.pem and crl.txt.
  --restart-only         Restart the existing remote okrun-switch service only.
  --help                 Show this help text.

Access port config comes from .deploy.switch:
  SWITCH_ACCESS_NETWORK  Private networkIdentifier to expose through Linux TAP; empty disables it.
                         Must match the clients' network shown in /status, e.g. okrun.
  SWITCH_ACCESS_IFACE    TAP interface name on the cloud host. Default: oksw0.
  SWITCH_ACCESS_IP       CIDR address for the TAP interface, e.g. 10.77.0.1/24.
  SWITCH_ACCESS_MTU      TAP MTU. Default: 1500.

Cert root layout:
  <certs-dir>/ca/ca-cert.pem
  <certs-dir>/ca/crl.txt
  <certs-dir>/server/server-cert.pem
  <certs-dir>/server/server-key.pem
EOF
}

for arg in "$@"; do
  case "$arg" in
    --help|-h)
      usage
      exit 0
      ;;
  esac
done

if [[ ! -f "$DEPLOY_CONFIG" ]]; then
  echo "Error: .deploy.switch file not found in web-switch/."
  echo "Create one from web-switch/.deploy.switch.example."
  exit 1
fi

# shellcheck source=/dev/null
source "$DEPLOY_CONFIG"

HOSTNAME="${HOSTNAME:-}"
REPO_URL="${REPO_URL:-}"
DEPLOY_HOST="${DEPLOY_HOST:-}"
SSH_PORT="${SSH_PORT:-22}"
SWITCH_TLS_PORT="${SWITCH_TLS_PORT:-9443}"
SWITCH_STATUS_PORT="${SWITCH_STATUS_PORT:-8080}"
SWITCH_ACCESS_NETWORK="${SWITCH_ACCESS_NETWORK:-${OKRUN_SWITCH_ACCESS_NETWORK:-}}"
SWITCH_ACCESS_IFACE="${SWITCH_ACCESS_IFACE:-${OKRUN_SWITCH_ACCESS_IFACE:-oksw0}}"
SWITCH_ACCESS_IP="${SWITCH_ACCESS_IP:-${OKRUN_SWITCH_ACCESS_IP:-}}"
SWITCH_ACCESS_MTU="${SWITCH_ACCESS_MTU:-${OKRUN_SWITCH_ACCESS_MTU:-1500}}"
CERTS_DIR="${CERTS_DIR:-}"
SERVER_CERT_DIR="${SERVER_CERT_DIR:-}"
CA_DIR="${CA_DIR:-}"

if [[ -z "$HOSTNAME" ]]; then
  echo "Error: HOSTNAME not set in .deploy.switch"
  exit 1
fi

if [[ -z "$REPO_URL" ]]; then
  echo "Error: REPO_URL not set in .deploy.switch"
  exit 1
fi

HOST=""
UPLOAD_CERTS=false
RESTART_ONLY=false

index=1
while [[ "$index" -le "$#" ]]; do
  arg="${!index}"
  case "$arg" in
    --upload-certs)
      UPLOAD_CERTS=true
      next_index=$((index + 1))
      if [[ "$next_index" -le "$#" ]]; then
        next_arg="${!next_index}"
        if [[ "$next_arg" != --* ]]; then
          CERTS_DIR="$next_arg"
          index="$next_index"
        fi
      fi
      ;;
    --upload-certs=*)
      UPLOAD_CERTS=true
      CERTS_DIR="${arg#*=}"
      ;;
    --certs-dir)
      index=$((index + 1))
      if [[ "$index" -gt "$#" ]]; then
        echo "Error: --certs-dir requires a value"
        usage
        exit 1
      fi
      CERTS_DIR="${!index}"
      ;;
    --certs-dir=*)
      CERTS_DIR="${arg#*=}"
      ;;
    --server-cert-dir)
      index=$((index + 1))
      if [[ "$index" -gt "$#" ]]; then
        echo "Error: --server-cert-dir requires a value"
        usage
        exit 1
      fi
      SERVER_CERT_DIR="${!index}"
      ;;
    --server-cert-dir=*)
      SERVER_CERT_DIR="${arg#*=}"
      ;;
    --ca-dir)
      index=$((index + 1))
      if [[ "$index" -gt "$#" ]]; then
        echo "Error: --ca-dir requires a value"
        usage
        exit 1
      fi
      CA_DIR="${!index}"
      ;;
    --ca-dir=*)
      CA_DIR="${arg#*=}"
      ;;
    --restart-only)
      RESTART_ONLY=true
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --*)
      echo "Error: Unknown option: $arg"
      usage
      exit 1
      ;;
    *)
      if [[ -n "$HOST" ]]; then
        echo "Error: Multiple hosts provided: $HOST and $arg"
        usage
        exit 1
      fi
      HOST="$arg"
      ;;
  esac
  index=$((index + 1))
done

if [[ -z "$HOST" && -n "$DEPLOY_HOST" ]]; then
  HOST="$DEPLOY_HOST"
fi

if [[ -z "$HOST" ]]; then
  echo "Error: No host specified and DEPLOY_HOST is not set in .deploy.switch."
  usage
  exit 1
fi

is_port() {
  local value="$1"
  [[ "$value" =~ ^[0-9]+$ ]] && (( 10#$value >= 1 && 10#$value <= 65535 ))
}

if ! is_port "$SSH_PORT"; then
  echo "Error: SSH_PORT must be a TCP port number, got: $SSH_PORT"
  exit 1
fi

if ! is_port "$SWITCH_TLS_PORT"; then
  echo "Error: SWITCH_TLS_PORT must be a TCP port number, got: $SWITCH_TLS_PORT"
  exit 1
fi

if ! is_port "$SWITCH_STATUS_PORT"; then
  echo "Error: SWITCH_STATUS_PORT must be a TCP port number, got: $SWITCH_STATUS_PORT"
  exit 1
fi

if [[ -n "$SWITCH_ACCESS_NETWORK" ]]; then
  if [[ -z "$SWITCH_ACCESS_IP" ]]; then
    echo "Error: SWITCH_ACCESS_IP is required when SWITCH_ACCESS_NETWORK is set."
    exit 1
  fi
  if [[ ! "$SWITCH_ACCESS_MTU" =~ ^[0-9]+$ ]] || (( 10#$SWITCH_ACCESS_MTU < 576 || 10#$SWITCH_ACCESS_MTU > 9000 )); then
    echo "Error: SWITCH_ACCESS_MTU must be a number from 576 to 9000, got: $SWITCH_ACCESS_MTU"
    exit 1
  fi
  if [[ "$SWITCH_ACCESS_NETWORK" =~ [[:space:]] || "$SWITCH_ACCESS_IFACE" =~ [[:space:]] || "$SWITCH_ACCESS_IP" =~ [[:space:]] ]]; then
    echo "Error: SWITCH_ACCESS_* values must not contain whitespace."
    exit 1
  fi
fi

echo "Setting up okrun-switch on $HOST..."
echo "Hostname: $HOSTNAME"
echo "Repository: $REPO_URL"
echo "TLS port: $SWITCH_TLS_PORT"
echo "Status port: $SWITCH_STATUS_PORT (not opened in UFW)"
if [[ -n "$SWITCH_ACCESS_NETWORK" ]]; then
  echo "Access port: enabled network=$SWITCH_ACCESS_NETWORK iface=$SWITCH_ACCESS_IFACE ip=$SWITCH_ACCESS_IP mtu=$SWITCH_ACCESS_MTU"
else
  echo "Access port: disabled"
fi

ssh_remote() {
  if [[ "$SSH_PORT" != "22" ]]; then
    ssh -p "$SSH_PORT" "$@"
  else
    ssh "$@"
  fi
}

scp_remote() {
  if [[ "$SSH_PORT" != "22" ]]; then
    scp -P "$SSH_PORT" "$@"
  else
    scp "$@"
  fi
}

if [[ "$SSH_PORT" != "22" ]]; then
  echo "Using custom SSH port: $SSH_PORT"
fi

resolve_path() {
  local value="$1"
  if [[ "$value" = /* ]]; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "$WEB_SWITCH_ROOT/$value"
  fi
}

CERT_DIR="/opt/okrun-switch/certs"
if [[ "$UPLOAD_CERTS" == true ]]; then
  if [[ -z "$CERTS_DIR" && ( -z "$SERVER_CERT_DIR" || -z "$CA_DIR" ) ]]; then
    echo "Error: --upload-certs requires --certs-dir, or both --server-cert-dir and --ca-dir."
    echo "Example: ./scripts/deploy/setup-server.sh deploy@switch.example.com --upload-certs .certs/prod"
    exit 1
  fi

  if [[ -z "$SERVER_CERT_DIR" ]]; then
    SERVER_CERT_DIR="$CERTS_DIR/server"
  fi
  if [[ -z "$CA_DIR" ]]; then
    CA_DIR="$CERTS_DIR/ca"
  fi

  SERVER_CERT_DIR="$(resolve_path "$SERVER_CERT_DIR")"
  CA_DIR="$(resolve_path "$CA_DIR")"
  SERVER_CERT="$SERVER_CERT_DIR/server-cert.pem"
  SERVER_KEY="$SERVER_CERT_DIR/server-key.pem"
  CA_CERT="$CA_DIR/ca-cert.pem"
  CRL_FILE="$CA_DIR/crl.txt"

  echo "Validating local switch certificates..."
  echo "Server cert directory: $SERVER_CERT_DIR"
  echo "CA directory: $CA_DIR"
  if [[ ! -f "$SERVER_CERT" || ! -f "$SERVER_KEY" ]]; then
    echo "Error: Server certificate files not found."
    echo "Expected: $SERVER_CERT"
    echo "Expected: $SERVER_KEY"
    echo "Generate them with: npm run cert:init -- --certs-dir <dir> && npm run cert:server -- --certs-dir <dir> $HOSTNAME"
    exit 1
  fi
  if [[ ! -f "$CA_CERT" ]]; then
    echo "Error: CA certificate not found."
    echo "Expected: $CA_CERT"
    echo "Generate it with: npm run cert:init -- --certs-dir <dir>"
    exit 1
  fi
  if [[ ! -f "$CRL_FILE" ]]; then
    echo "Error: CRL not found."
    echo "Expected: $CRL_FILE"
    echo "Generate it with: npm run cert:init -- --certs-dir <dir>"
    exit 1
  fi
fi

echo "Copying setup-server-remote.sh..."
scp_remote "$SCRIPT_DIR/setup-server-remote.sh" "$HOST:~/setup-server-remote.sh"

if [[ "$UPLOAD_CERTS" == true ]]; then
  echo "Preparing remote certificate directory..."
  ssh_remote "$HOST" "sudo mkdir -p '$CERT_DIR' && sudo chown -R \"\$(id -un):\$(id -gn)\" /opt/okrun-switch && sudo chmod 700 '$CERT_DIR'"

  echo "Uploading certificates to $CERT_DIR..."
  scp_remote "$SERVER_CERT" "$HOST:$CERT_DIR/"
  scp_remote "$SERVER_KEY" "$HOST:$CERT_DIR/"
  scp_remote "$CA_CERT" "$HOST:$CERT_DIR/"
  scp_remote "$CRL_FILE" "$HOST:$CERT_DIR/"

  echo "Locking down uploaded certificate permissions..."
  ssh_remote "$HOST" "sudo chmod 700 '$CERT_DIR' && sudo chmod 600 '$CERT_DIR/server-key.pem' && sudo chmod 644 '$CERT_DIR/server-cert.pem' '$CERT_DIR/ca-cert.pem' '$CERT_DIR/crl.txt'"
fi

REMOTE_ARGS=()
if [[ "$RESTART_ONLY" == true ]]; then
  REMOTE_ARGS+=(--restart-only)
fi
REMOTE_ARGS+=(
  "$HOSTNAME"
  "$REPO_URL"
  "$SWITCH_TLS_PORT"
  "$SWITCH_STATUS_PORT"
  "$SSH_PORT"
  "$SWITCH_ACCESS_NETWORK"
  "$SWITCH_ACCESS_IFACE"
  "$SWITCH_ACCESS_IP"
  "$SWITCH_ACCESS_MTU"
)

REMOTE_CMD="chmod +x ~/setup-server-remote.sh && sudo ~/setup-server-remote.sh"
for remote_arg in "${REMOTE_ARGS[@]}"; do
  REMOTE_CMD+=" $(printf '%q' "$remote_arg")"
done

echo "Executing setup script on remote host..."
ssh_remote "$HOST" "$REMOTE_CMD"

echo "Remote setup completed successfully!"
