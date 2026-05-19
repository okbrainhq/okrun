#!/usr/bin/env bash

# setup-local.sh
# Purpose: Orchestrates the setup of a local (non-TLS) okrun-switch on a remote Mac.
# Usage: ./scripts/deploy/setup-local.sh [USER@HOST]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WEB_SWITCH_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DEPLOY_CONFIG="$WEB_SWITCH_ROOT/.deploy.local"

usage() {
  cat <<'EOF'
Usage: ./scripts/deploy/setup-local.sh [USER@HOST]

Reads deployment settings from web-switch/.deploy.local.

Options:
  --help                 Show this help text.
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
  echo "Error: .deploy.local file not found in web-switch/."
  echo "Create one from web-switch/.deploy.local.example."
  exit 1
fi

# shellcheck source=/dev/null
source "$DEPLOY_CONFIG"

# Read APP_DIR raw so ~ stays literal and expands on the remote Mac.
read_raw_value() {
  local key="$1"
  grep -E "^${key}=" "$DEPLOY_CONFIG" | head -1 | sed "s/^${key}=//" || true
}

APP_DIR_RAW=$(read_raw_value "APP_DIR")

REPO_URL="${REPO_URL:-}"
DEPLOY_HOST="${DEPLOY_HOST:-}"
SSH_PORT="${SSH_PORT:-22}"
LOCAL_PORT="${LOCAL_PORT:-9444}"
STATUS_PORT="${STATUS_PORT:-8080}"
HOST="${HOST:-127.0.0.1}"
APP_DIR="${APP_DIR_RAW:-~/okrun-switch}"

if [[ -z "$REPO_URL" ]]; then
  echo "Error: REPO_URL not set in .deploy.local"
  exit 1
fi

HOST_ARG=""
for arg in "$@"; do
  case "$arg" in
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
      if [[ -n "$HOST_ARG" ]]; then
        echo "Error: Multiple hosts provided: $HOST_ARG and $arg"
        usage
        exit 1
      fi
      HOST_ARG="$arg"
      ;;
  esac
done

if [[ -z "$HOST_ARG" && -n "$DEPLOY_HOST" ]]; then
  HOST_ARG="$DEPLOY_HOST"
fi

if [[ -z "$HOST_ARG" ]]; then
  echo "Error: No host specified and DEPLOY_HOST is not set in .deploy.local."
  usage
  exit 1
fi

echo "Setting up okrun-switch (local mode) on $HOST_ARG..."
echo "Repository: $REPO_URL"
echo "Local port: $LOCAL_PORT"
echo "Status port: $STATUS_PORT"
echo "Bind host: $HOST"
echo "App dir: $APP_DIR"

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

echo "Copying setup-local-remote.sh..."
scp_remote "$SCRIPT_DIR/setup-local-remote.sh" "$HOST_ARG:~/setup-local-remote.sh"

REMOTE_CMD="chmod +x ~/setup-local-remote.sh && ~/setup-local-remote.sh"
REMOTE_CMD+=" $(printf '%q' "$REPO_URL")"
REMOTE_CMD+=" $(printf '%q' "$LOCAL_PORT")"
REMOTE_CMD+=" $(printf '%q' "$STATUS_PORT")"
REMOTE_CMD+=" $(printf '%q' "$HOST")"
REMOTE_CMD+=" $(printf '%q' "$APP_DIR")"

echo "Executing setup script on remote Mac..."
ssh_remote "$HOST_ARG" "$REMOTE_CMD"

echo ""
echo "Local switch setup completed successfully on $HOST_ARG!"
