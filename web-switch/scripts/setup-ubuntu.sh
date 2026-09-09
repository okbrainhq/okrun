#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "${1:-}" == --help || $# -gt 1 ]]; then
  echo 'Usage: sudo bash web-switch/scripts/setup-ubuntu.sh [HOST_BUNDLE.json]'
  echo 'Default bundle: /etc/okrun-network/host.json (root-only, outside the checkout).'
  echo 'For first installation or credential rotation, pass a private host bundle path.'
  echo 'Attaches this host to okrun via 172.16.0.10:9443 and the cloud bundle.'
  echo 'No manual IP: automatic host address on the existing 10.77.0.0/24 VM subnet.'
  [[ "${1:-}" == --help ]] && exit 0
  exit 1
fi
exec bash "$ROOT/scripts/install-network-client.sh" "${1:-/etc/okrun-network/host.json}" auto okrun okrun0 172.16.0.10:9443
