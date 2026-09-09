#!/usr/bin/env bash
# Compatibility entry point; implementation lives with the web-switch client.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec bash "$ROOT/web-switch/scripts/install-network-client.sh" "$@"
