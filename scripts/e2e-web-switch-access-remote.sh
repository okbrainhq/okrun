#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${1:-${OKRUN_ACCESS_E2E_TARGET:-arunoda@devbox-sandbox.local}}"
REMOTE_DIR="${OKRUN_ACCESS_E2E_REMOTE_DIR:-/tmp/okrun-web-switch-access-${USER:-user}}"

if ! command -v rsync >/dev/null 2>&1; then
  echo 'Missing required command: rsync' >&2
  exit 1
fi

printf '==> Sync repo to %s:%s\n' "$TARGET" "$REMOTE_DIR"
ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$TARGET" "mkdir -p '$REMOTE_DIR'"
rsync -az --delete \
  --exclude '.git/' \
  --exclude '.build/' \
  --exclude '.e2e/' \
  --exclude 'OkrunVM.app/' \
  --exclude 'OkrunVM-Dev.app/' \
  --exclude 'scripts/logs/' \
  "$ROOT/" "$TARGET:$REMOTE_DIR/"

printf '==> Run Linux access-port E2E on %s\n' "$TARGET"
ssh -tt -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$TARGET" \
  "cd '$REMOTE_DIR' && bash scripts/e2e-web-switch-access-linux.sh"
