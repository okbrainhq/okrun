#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

STEP_LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/okrun-headless-e2e-logs.XXXXXX")"
STEP_COUNT=0
STATIC_PRIVATE_HOME=""
DHCP_HOME=""
SHARED_DIR=""
GUEST_LOGS_DIR=""
ASIF_IMPORT_DIR=""
cleanup() {
  rm -rf "$STEP_LOG_DIR"
  rm -rf "${STATIC_PRIVATE_HOME:-}"
  rm -rf "${DHCP_HOME:-}"
  rm -rf "${SHARED_DIR:-}"
  rm -rf "${GUEST_LOGS_DIR:-}"
  rm -rf "${ASIF_IMPORT_DIR:-}"
}
trap cleanup EXIT

run_step() {
  local name="$1"
  shift

  STEP_COUNT=$((STEP_COUNT + 1))
  local log_file="$STEP_LOG_DIR/step-$STEP_COUNT.log"
  local start="$SECONDS"

  printf '  -> %s\n' "$name"
  if "$@" >"$log_file" 2>&1; then
    printf '  OK %s (%ss)\n' "$name" "$((SECONDS - start))"
    return 0
  fi

  local status="$?"
  printf '  FAIL %s (%ss)\n' "$name" "$((SECONDS - start))" >&2
  printf '\n--- %s output ---\n' "$name" >&2
  sed -n '1,240p' "$log_file" >&2
  if [[ "$(wc -l <"$log_file")" -gt 240 ]]; then
    printf '... output truncated; full log: %s\n' "$log_file" >&2
  fi
  return "$status"
}

printf '  -> Prepare Alpine boot fixtures\n'
"$ROOT/scripts/prepare-e2e-linux.sh" >/tmp/okrun-e2e-linux-paths.txt
printf '  OK Prepare Alpine boot fixtures\n'

KERNEL="$(sed -n '1p' /tmp/okrun-e2e-linux-paths.txt)"
INITRAMFS="$(sed -n '2p' /tmp/okrun-e2e-linux-paths.txt)"
SHARED_INITRAMFS="$(sed -n '3p' /tmp/okrun-e2e-linux-paths.txt)"
PRIVATE_NETWORK_SERVER_INITRAMFS="$(sed -n '5p' /tmp/okrun-e2e-linux-paths.txt)"
PRIVATE_NETWORK_CLIENT_INITRAMFS="$(sed -n '6p' /tmp/okrun-e2e-linux-paths.txt)"
PRIVATE_NETWORK_DHCP_INITRAMFS="$(sed -n '7p' /tmp/okrun-e2e-linux-paths.txt)"
PRIVATE_NETWORK_DHCP_SERVER_INITRAMFS="$(sed -n '8p' /tmp/okrun-e2e-linux-paths.txt)"
PRIVATE_NETWORK_DHCP_CLIENT_INITRAMFS="$(sed -n '9p' /tmp/okrun-e2e-linux-paths.txt)"

run_step "Build production app" "$ROOT/scripts/build.sh"

run_asif_import_smoke() {
  if [[ ! -x /usr/sbin/diskutil ]]; then
    printf '  SKIP Headless ASIF import: diskutil is unavailable\n'
    return 0
  fi

  ASIF_IMPORT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/okrun-e2e-asif-import.XXXXXX")"
  local source_asif="$ASIF_IMPORT_DIR/source.asif"
  local project_root="$ASIF_IMPORT_DIR/imported-vm"
  local registry_path="$ASIF_IMPORT_DIR/registry.json"
  local create_log="$ASIF_IMPORT_DIR/create-asif.log"

  if ! /usr/sbin/diskutil image create blank --fs none --format ASIF --size 1537m "$source_asif" >"$create_log" 2>&1; then
    printf '  SKIP Headless ASIF import: ASIF disk creation is unavailable\n'
    sed -n '1,80p' "$create_log"
    return 0
  fi

  run_step "Headless ASIF import" \
    "$ROOT/OkrunVM.app/Contents/MacOS/OkrunVM" \
    --headless-import-asif \
    --source-asif "$source_asif" \
    --project-root "$project_root" \
    --registry-path "$registry_path"

  [[ -f "$project_root/okrun-vm.json" ]]
  [[ -f "$project_root/vm/linux.asif" ]]
  [[ -f "$project_root/vm/efi.variables" ]]
  [[ -f "$project_root/vm/machine.identifier" ]]
  grep -Fq '"diskFormat" : "asif"' "$project_root/okrun-vm.json"
  grep -Fq '"diskGB" : 2' "$project_root/okrun-vm.json"
  grep -Fq 'imported-vm' "$registry_path"
  grep -Fq '"selectedProject"' "$registry_path"
}

run_asif_import_smoke

STATIC_PRIVATE_HOME="$(mktemp -d "${TMPDIR:-/tmp}/okrun-e2e-static-private-home.XXXXXX")"
DHCP_HOME="$(mktemp -d "${TMPDIR:-/tmp}/okrun-e2e-dhcp-home.XXXXXX")"
SHARED_DIR="$(mktemp -d "${TMPDIR:-/tmp}/okrun-e2e-shared.XXXXXX")"
GUEST_LOGS_DIR="${SHARED_DIR%/*}/okrun-e2e-guest-logs.$$"

run_step "Boot minimal guest" \
  "$ROOT/OkrunVM.app/Contents/MacOS/OkrunVM" \
  --headless-boot-test \
  --kernel "$KERNEL" \
  --initramfs "$INITRAMFS" \
  --timeout 45

run_step "Boot guest with private network adapter" \
  env OKRUN_HOME="$STATIC_PRIVATE_HOME" "$ROOT/OkrunVM.app/Contents/MacOS/OkrunVM" \
  --headless-boot-test \
  --kernel "$KERNEL" \
  --initramfs "$INITRAMFS" \
  --private-network \
  --private-network-id "okrun-e2e-$$" \
  --timeout 45

run_step "Ping across static private network" \
  env OKRUN_HOME="$STATIC_PRIVATE_HOME" "$ROOT/OkrunVM.app/Contents/MacOS/OkrunVM" \
  --headless-private-network-test \
  --kernel "$KERNEL" \
  --server-initramfs "$PRIVATE_NETWORK_SERVER_INITRAMFS" \
  --client-initramfs "$PRIVATE_NETWORK_CLIENT_INITRAMFS" \
  --private-network-id "okrun-e2e-ping-$$" \
  --timeout 45

DHCP_NETWORK_ID="okrun-e2e-dhcp-$$"
DHCP_PAIR_NETWORK_ID="okrun-e2e-dhcp-pair-$$"
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
    },
    "$DHCP_PAIR_NETWORK_ID": {
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

run_step "Boot guest with private DHCP lease" \
  env OKRUN_HOME="$DHCP_HOME" "$ROOT/OkrunVM.app/Contents/MacOS/OkrunVM" \
  --headless-boot-test \
  --kernel "$KERNEL" \
  --initramfs "$PRIVATE_NETWORK_DHCP_INITRAMFS" \
  --private-network-dhcp \
  --private-network-id "$DHCP_NETWORK_ID" \
  --timeout 45

run_step "Ping across DHCP private network" \
  env OKRUN_HOME="$DHCP_HOME" "$ROOT/OkrunVM.app/Contents/MacOS/OkrunVM" \
  --headless-private-network-test \
  --kernel "$KERNEL" \
  --server-initramfs "$PRIVATE_NETWORK_DHCP_SERVER_INITRAMFS" \
  --client-initramfs "$PRIVATE_NETWORK_DHCP_CLIENT_INITRAMFS" \
  --private-network-id "$DHCP_PAIR_NETWORK_ID" \
  --timeout 45

echo hello-from-host > "$SHARED_DIR/host-to-guest.txt"

run_step "Mount guest logs share" \
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

run_step "Round trip shared directory file" \
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
