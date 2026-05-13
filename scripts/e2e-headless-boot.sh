#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"$ROOT/scripts/prepare-e2e-linux.sh" >/tmp/okrun-e2e-linux-paths.txt

KERNEL="$(sed -n '1p' /tmp/okrun-e2e-linux-paths.txt)"
INITRAMFS="$(sed -n '2p' /tmp/okrun-e2e-linux-paths.txt)"
SHARED_INITRAMFS="$(sed -n '3p' /tmp/okrun-e2e-linux-paths.txt)"
PRIVATE_NETWORK_SERVER_INITRAMFS="$(sed -n '5p' /tmp/okrun-e2e-linux-paths.txt)"
PRIVATE_NETWORK_CLIENT_INITRAMFS="$(sed -n '6p' /tmp/okrun-e2e-linux-paths.txt)"
PRIVATE_NETWORK_DHCP_INITRAMFS="$(sed -n '7p' /tmp/okrun-e2e-linux-paths.txt)"

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

DHCP_HOME="$(mktemp -d "${TMPDIR:-/tmp}/okrun-e2e-dhcp-home.XXXXXX")"
DHCP_NETWORK_ID="okrun-e2e-dhcp-$$"
mkdir -p "$DHCP_HOME"
cat >"$DHCP_HOME/private-networks.json" <<EOF
{
  "version": 1,
  "privateNetworks": {
    "$DHCP_NETWORK_ID": {
      "dhcp": {
        "enabled": true,
        "mode": "range",
        "cidr": "10.77.0.0/24",
        "rangeStart": "10.77.0.20",
        "rangeEnd": "10.77.0.30",
        "leaseSeconds": 3600
      }
    }
  }
}
EOF

OKRUN_HOME="$DHCP_HOME" "$ROOT/OkrunVM.app/Contents/MacOS/OkrunVM" \
  --headless-boot-test \
  --kernel "$KERNEL" \
  --initramfs "$PRIVATE_NETWORK_DHCP_INITRAMFS" \
  --private-network-dhcp \
  --private-network-id "$DHCP_NETWORK_ID" \
  --timeout 45

SHARED_DIR="$(mktemp -d "${TMPDIR:-/tmp}/okrun-e2e-shared.XXXXXX")"
GUEST_LOGS_DIR="${SHARED_DIR%/*}/okrun-e2e-guest-logs.$$"
cleanup() {
  rm -rf "$SHARED_DIR"
  rm -rf "$GUEST_LOGS_DIR"
  rm -rf "$DHCP_HOME"
}
trap cleanup EXIT

echo hello-from-host > "$SHARED_DIR/host-to-guest.txt"

"$ROOT/OkrunVM.app/Contents/MacOS/OkrunVM" \
  --headless-boot-test \
  --kernel "$KERNEL" \
  --initramfs "$SHARED_INITRAMFS" \
  --guest-logs-directory "$GUEST_LOGS_DIR" \
  --timeout 45

if [[ ! -d "$GUEST_LOGS_DIR" ]]; then
  echo "Guest logs share E2E failed: host log directory was not created." >&2
  exit 1
fi

"$ROOT/OkrunVM.app/Contents/MacOS/OkrunVM" \
  --headless-boot-test \
  --kernel "$KERNEL" \
  --initramfs "$SHARED_INITRAMFS" \
  --shared-directory "$SHARED_DIR" \
  --guest-logs-directory "$GUEST_LOGS_DIR" \
  --timeout 45

if [[ "$(cat "$SHARED_DIR/guest-to-host.txt" 2>/dev/null)" != "hello-from-guest" ]]; then
  echo "Shared directory E2E failed: guest-to-host sentinel was not written." >&2
  exit 1
fi
