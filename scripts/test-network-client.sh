#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node --check "$ROOT/web-switch/src/network-client.js"
node --check "$ROOT/web-switch/bin/okrun-network.js"
bash -n "$ROOT/scripts/install-network-client.sh"
node --check "$ROOT/web-switch/src/network-router.js"
node --test "$ROOT/web-switch/tests/network-client.test.js" "$ROOT/web-switch/tests/network-router.test.js"
node "$ROOT/web-switch/tests/e2e/run.js"
