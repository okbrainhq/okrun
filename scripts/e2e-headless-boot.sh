#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"$ROOT/scripts/prepare-e2e-linux.sh" >/tmp/okrun-e2e-linux-paths.txt

KERNEL="$(sed -n '1p' /tmp/okrun-e2e-linux-paths.txt)"
INITRAMFS="$(sed -n '2p' /tmp/okrun-e2e-linux-paths.txt)"
SHARED_INITRAMFS="$(sed -n '3p' /tmp/okrun-e2e-linux-paths.txt)"
PRIVATE_NETWORK_SERVER_INITRAMFS="$(sed -n '5p' /tmp/okrun-e2e-linux-paths.txt)"
PRIVATE_NETWORK_CLIENT_INITRAMFS="$(sed -n '6p' /tmp/okrun-e2e-linux-paths.txt)"

"$ROOT/scripts/build.sh"

"$ROOT/OkrunVM.app/Contents/MacOS/OkrunVM" \
  --headless-boot-test \
  --kernel "$KERNEL" \
  --initramfs "$INITRAMFS" \
  --timeout 45

"$ROOT/OkrunVM.app/Contents/MacOS/OkrunVM" \
  --headless-boot-test \
  --kernel "$KERNEL" \
  --initramfs "$INITRAMFS" \
  --private-network \
  --private-network-id "okrun-e2e-$$" \
  --timeout 45

"$ROOT/OkrunVM.app/Contents/MacOS/OkrunVM" \
  --headless-private-network-test \
  --kernel "$KERNEL" \
  --server-initramfs "$PRIVATE_NETWORK_SERVER_INITRAMFS" \
  --client-initramfs "$PRIVATE_NETWORK_CLIENT_INITRAMFS" \
  --private-network-id "okrun-e2e-ping-$$" \
  --timeout 45

SHARED_DIR="$(mktemp -d "${TMPDIR:-/tmp}/okrun-e2e-shared.XXXXXX")"
cleanup() {
  rm -rf "$SHARED_DIR"
}
trap cleanup EXIT

echo hello-from-host > "$SHARED_DIR/host-to-guest.txt"

"$ROOT/OkrunVM.app/Contents/MacOS/OkrunVM" \
  --headless-boot-test \
  --kernel "$KERNEL" \
  --initramfs "$SHARED_INITRAMFS" \
  --shared-directory "$SHARED_DIR" \
  --timeout 45

if [[ "$(cat "$SHARED_DIR/guest-to-host.txt" 2>/dev/null)" != "hello-from-guest" ]]; then
  echo "Shared directory E2E failed: guest-to-host sentinel was not written." >&2
  exit 1
fi
