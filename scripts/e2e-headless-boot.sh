#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"$ROOT/scripts/prepare-e2e-linux.sh" >/tmp/okrun-e2e-linux-paths.txt

KERNEL="$(sed -n '1p' /tmp/okrun-e2e-linux-paths.txt)"
INITRAMFS="$(sed -n '2p' /tmp/okrun-e2e-linux-paths.txt)"

"$ROOT/scripts/build.sh"

"$ROOT/OkrunVM.app/Contents/MacOS/OkrunVM" \
  --headless-boot-test \
  --kernel "$KERNEL" \
  --initramfs "$INITRAMFS" \
  --timeout 45
