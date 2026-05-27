#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/okrun-guest-tools-e2e.XXXXXX")"
BIN_DIR="$WORK_DIR/bin"
LOG_FILE="$WORK_DIR/commands.log"
DEFAULT_LOG_FILE="$WORK_DIR/default-commands.log"
MACOS_LOG_FILE="$WORK_DIR/macos-commands.log"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

mkdir -p "$BIN_DIR"

STEP_COUNT=0
run_step() {
  local name="$1"
  shift

  STEP_COUNT=$((STEP_COUNT + 1))
  local log_file="$WORK_DIR/step-$STEP_COUNT.log"
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

cat >"$BIN_DIR/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'ssh' >>"$OKRUN_E2E_LOG"
for arg in "$@"; do printf ' [%s]' "$arg" >>"$OKRUN_E2E_LOG"; done
printf '\n' >>"$OKRUN_E2E_LOG"
EOF

cat >"$BIN_DIR/scp" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'scp' >>"$OKRUN_E2E_LOG"
for arg in "$@"; do printf ' [%s]' "$arg" >>"$OKRUN_E2E_LOG"; done
printf '\n' >>"$OKRUN_E2E_LOG"
EOF

chmod +x "$BIN_DIR/ssh" "$BIN_DIR/scp"

run_step "Record remote guest tools install command" \
  env OKRUN_E2E_LOG="$LOG_FILE" PATH="$BIN_DIR:$PATH" "$ROOT/scripts/install-guest-tools.sh" \
  --user tester \
  --port 2222 \
  --identity "$WORK_DIR/id_ed25519" \
  --private-dhcp \
  --private-ip 10.77.0.9/24 \
  --health-interval 5 \
  --resize-root \
  example.test

if ! grep -q 'scp.*install-okrun-guest-tools.sh.*okrun-guest-health.sh.*tester@example.test' "$LOG_FILE"; then
  echo "Expected payload scp command was not recorded." >&2
  cat "$LOG_FILE" >&2
  exit 1
fi

if ! grep -q 'sudo.*install-okrun-guest-tools.sh.*--health-interval.*5.*--log-share.*okrun-guest-logs.*--resize-root.*--private-dhcp.*--private-ip.*10.77.0.9/24.*--private-iface.*auto' "$LOG_FILE"; then
  echo "Expected remote install command was not recorded." >&2
  cat "$LOG_FILE" >&2
  exit 1
fi

run_step "Record default remote guest tools install command" \
  env OKRUN_E2E_LOG="$DEFAULT_LOG_FILE" PATH="$BIN_DIR:$PATH" "$ROOT/scripts/install-guest-tools.sh" \
  --user tester \
  --port 2222 \
  --identity "$WORK_DIR/id_ed25519" \
  example-default.test

if ! grep -q 'sudo.*install-okrun-guest-tools.sh.*--health-interval.*60.*--log-share.*okrun-guest-logs.*--private-dhcp' "$DEFAULT_LOG_FILE"; then
  echo "Expected default remote install command to request DHCP." >&2
  cat "$DEFAULT_LOG_FILE" >&2
  exit 1
fi

if grep -q -- '--private-ip' "$DEFAULT_LOG_FILE"; then
  echo "Default remote install command should not request a static private IP." >&2
  cat "$DEFAULT_LOG_FILE" >&2
  exit 1
fi

run_step "Record macOS remote guest tools install command" \
  env OKRUN_E2E_LOG="$MACOS_LOG_FILE" PATH="$BIN_DIR:$PATH" "$ROOT/scripts/install-guest-tools.sh" \
  --guest-os macos \
  --user tester \
  --port 2222 \
  --identity "$WORK_DIR/id_ed25519" \
  --private-iface en1 \
  example-macos.test

if ! grep -q 'sudo.*install-okrun-guest-tools.sh.*--health-interval.*60.*--log-share.*okrun-guest-logs.*--guest-os.*macos.*--private-dhcp.*--private-iface.*en1' "$MACOS_LOG_FILE"; then
  echo "Expected macOS remote install command was not recorded." >&2
  cat "$MACOS_LOG_FILE" >&2
  exit 1
fi

run_step "Validate guest tools shell syntax" \
  bash -c 'bash -n "$1" && bash -n "$2" && bash -n "$3"' _ \
  "$ROOT/scripts/install-guest-tools.sh" \
  "$ROOT/scripts/guest-tools/install-okrun-guest-tools.sh" \
  "$ROOT/scripts/guest-tools/okrun-guest-health.sh"

GUEST_ROOT="$WORK_DIR/guest-root"
mkdir -p "$GUEST_ROOT/mnt/okrun/okrun-guest-logs"
run_step "Install into test guest root with static private IP" \
  env OKRUN_GUEST_ROOT="$GUEST_ROOT" "$ROOT/scripts/guest-tools/install-okrun-guest-tools.sh" \
  --private-ip 10.77.0.9/24 \
  --private-iface enp0s2 \
  --health-interval 7 \
  --resize-root

assert_file_contains() {
  local file="$1"
  local pattern="$2"
  if ! grep -q "$pattern" "$file"; then
    echo "Expected $file to contain: $pattern" >&2
    sed -n '1,160p' "$file" >&2
    exit 1
  fi
}

[[ -x "$GUEST_ROOT/usr/local/lib/okrun/okrun-guest-health.sh" ]]
[[ -x "$GUEST_ROOT/usr/local/sbin/okrun-guest-diagnose" ]]
[[ -d "$GUEST_ROOT/var/log/okrun" ]]
[[ -d "$GUEST_ROOT/mnt/okrun/okrun-guest-logs" ]]

assert_file_contains "$GUEST_ROOT/etc/systemd/system/okrun-guest-health.service" "Environment=OKRUN_HEALTH_INTERVAL=7"
assert_file_contains "$GUEST_ROOT/etc/systemd/system/okrun-guest-health.service" "EnvironmentFile=/etc/okrun/guest-tools.env"
assert_file_contains "$GUEST_ROOT/etc/systemd/system/okrun-guest-health.service" "ExecStart=/usr/local/lib/okrun/okrun-guest-health.sh"
assert_file_contains "$GUEST_ROOT/etc/okrun/guest-tools.env" "OKRUN_LOG_DIR=/mnt/okrun/okrun-guest-logs"
assert_file_contains "$GUEST_ROOT/etc/okrun/guest-tools.env" "OKRUN_LOG_PROBE_TIMEOUT=8"
assert_file_contains "$GUEST_ROOT/etc/systemd/system/mnt-okrun.mount" "What=okrun"
assert_file_contains "$GUEST_ROOT/etc/systemd/system/mnt-okrun.mount" "Where=/mnt/okrun"
assert_file_contains "$GUEST_ROOT/etc/systemd/system/mnt-okrun.mount" "Type=virtiofs"
assert_file_contains "$GUEST_ROOT/etc/systemd/network/20-okrun-private.network" "Name=enp0s2"
assert_file_contains "$GUEST_ROOT/etc/systemd/network/20-okrun-private.network" "Address=10.77.0.9/24"
if grep -q "DHCP=ipv4" "$GUEST_ROOT/etc/systemd/network/20-okrun-private.network"; then
  echo "Static --private-ip should win when --private-dhcp is also supplied." >&2
  exit 1
fi

run_step "Replace existing static private IP" \
  env OKRUN_GUEST_ROOT="$GUEST_ROOT" "$ROOT/scripts/guest-tools/install-okrun-guest-tools.sh" \
  --private-ip 10.77.0.10/24 \
  --health-interval 7

assert_file_contains "$GUEST_ROOT/etc/systemd/network/20-okrun-private.network" "Managed by Okrun guest tools"
assert_file_contains "$GUEST_ROOT/etc/systemd/network/20-okrun-private.network" "Name=enp0s2"
assert_file_contains "$GUEST_ROOT/etc/systemd/network/20-okrun-private.network" "Address=10.77.0.10/24"
if grep -q "10.77.0.9/24" "$GUEST_ROOT/etc/systemd/network/20-okrun-private.network"; then
  echo "Installer should replace an existing Okrun private IP when rerun with a new one." >&2
  exit 1
fi

DHCP_ROOT="$WORK_DIR/dhcp-root"
mkdir -p "$DHCP_ROOT/mnt/okrun/okrun-guest-logs"
run_step "Install DHCP private network config" \
  env OKRUN_GUEST_ROOT="$DHCP_ROOT" "$ROOT/scripts/guest-tools/install-okrun-guest-tools.sh" \
  --private-iface enp0s2 \
  --health-interval 7

assert_file_contains "$DHCP_ROOT/etc/systemd/network/20-okrun-private.network" "Managed by Okrun guest tools"
assert_file_contains "$DHCP_ROOT/etc/systemd/network/20-okrun-private.network" "Name=enp0s2"
assert_file_contains "$DHCP_ROOT/etc/systemd/network/20-okrun-private.network" "DHCP=ipv4"
assert_file_contains "$DHCP_ROOT/etc/systemd/network/20-okrun-private.network" "LinkLocalAddressing=no"
assert_file_contains "$DHCP_ROOT/etc/systemd/network/20-okrun-private.network" "IPv6AcceptRA=no"
assert_file_contains "$DHCP_ROOT/etc/systemd/network/20-okrun-private.network" "UseDNS=false"
assert_file_contains "$DHCP_ROOT/etc/systemd/network/20-okrun-private.network" "UseRoutes=false"
if grep -q "^Address=" "$DHCP_ROOT/etc/systemd/network/20-okrun-private.network"; then
  echo "DHCP private network config should not include a static Address line." >&2
  exit 1
fi

STATIC_TO_DHCP_ROOT="$WORK_DIR/static-to-dhcp-root"
mkdir -p "$STATIC_TO_DHCP_ROOT/etc/systemd/network" "$STATIC_TO_DHCP_ROOT/mnt/okrun/okrun-guest-logs"
cat >"$STATIC_TO_DHCP_ROOT/etc/systemd/network/20-okrun-private.network" <<'EOF'
# Managed by Okrun guest tools.
[Match]
Name=enp0s2

[Network]
Address=10.77.0.55/24
EOF

run_step "Replace existing static private config with DHCP by default" \
  env OKRUN_GUEST_ROOT="$STATIC_TO_DHCP_ROOT" "$ROOT/scripts/guest-tools/install-okrun-guest-tools.sh" \
  --health-interval 7

assert_file_contains "$STATIC_TO_DHCP_ROOT/etc/systemd/network/20-okrun-private.network" "DHCP=ipv4"
assert_file_contains "$STATIC_TO_DHCP_ROOT/etc/systemd/network/20-okrun-private.network" "UseRoutes=false"
if grep -q "^Address=" "$STATIC_TO_DHCP_ROOT/etc/systemd/network/20-okrun-private.network"; then
  echo "Default installer run should replace an existing Okrun-managed static private config with DHCP." >&2
  exit 1
fi

cat >"$STATIC_TO_DHCP_ROOT/etc/systemd/network/20-okrun-private.network" <<'EOF'
# Managed by Okrun guest tools.
[Match]
Name=enp0s2

[Network]
Address=10.77.0.55/24
EOF

run_step "Accept explicit DHCP option" \
  env OKRUN_GUEST_ROOT="$STATIC_TO_DHCP_ROOT" "$ROOT/scripts/guest-tools/install-okrun-guest-tools.sh" \
  --private-dhcp \
  --health-interval 7

assert_file_contains "$STATIC_TO_DHCP_ROOT/etc/systemd/network/20-okrun-private.network" "DHCP=ipv4"
assert_file_contains "$STATIC_TO_DHCP_ROOT/etc/systemd/network/20-okrun-private.network" "UseRoutes=false"
if grep -q "^Address=" "$STATIC_TO_DHCP_ROOT/etc/systemd/network/20-okrun-private.network"; then
  echo "--private-dhcp should replace an existing Okrun-managed static Address line." >&2
  exit 1
fi

MACOS_ROOT="$WORK_DIR/macos-root"
mkdir -p "$MACOS_ROOT/Volumes/okrun/okrun-guest-logs"
run_step "Install into macOS test guest root with DHCP private network" \
  env OKRUN_GUEST_ROOT="$MACOS_ROOT" "$ROOT/scripts/guest-tools/install-okrun-guest-tools.sh" \
  --guest-os macos \
  --private-iface en1 \
  --health-interval 17 \
  --resize-root

[[ -x "$MACOS_ROOT/usr/local/lib/okrun/okrun-guest-health.sh" ]]
[[ -x "$MACOS_ROOT/usr/local/sbin/okrun-guest-diagnose" ]]
[[ -x "$MACOS_ROOT/usr/local/sbin/okrun-mount-virtiofs" ]]
[[ -x "$MACOS_ROOT/usr/local/sbin/okrun-private-network" ]]
[[ -d "$MACOS_ROOT/var/log/okrun" ]]
[[ -d "$MACOS_ROOT/Volumes/okrun/okrun-guest-logs" ]]

assert_file_contains "$MACOS_ROOT/etc/okrun/guest-tools.env" "OKRUN_LOG_DIR=/Volumes/okrun/okrun-guest-logs"
assert_file_contains "$MACOS_ROOT/Library/LaunchDaemons/com.okrun.guest-health.plist" "com.okrun.guest-health"
assert_file_contains "$MACOS_ROOT/Library/LaunchDaemons/com.okrun.guest-health.plist" "<string>17</string>"
assert_file_contains "$MACOS_ROOT/Library/LaunchDaemons/com.okrun.virtiofs.plist" "com.okrun.virtiofs"
assert_file_contains "$MACOS_ROOT/usr/local/sbin/okrun-mount-virtiofs" 'MOUNT_POINT="/Volumes/okrun"'
assert_file_contains "$MACOS_ROOT/Library/LaunchDaemons/com.okrun.private-network.plist" "com.okrun.private-network"
assert_file_contains "$MACOS_ROOT/usr/local/sbin/okrun-private-network" 'ipconfig set "en1" DHCP'

MACOS_STATIC_ROOT="$WORK_DIR/macos-static-root"
mkdir -p "$MACOS_STATIC_ROOT/Volumes/okrun/okrun-guest-logs"
run_step "Install into macOS test guest root with static private IP" \
  env OKRUN_GUEST_ROOT="$MACOS_STATIC_ROOT" "$ROOT/scripts/guest-tools/install-okrun-guest-tools.sh" \
  --guest-os macos \
  --private-iface en2 \
  --private-ip 10.77.0.12/24 \
  --health-interval 19

assert_file_contains "$MACOS_STATIC_ROOT/usr/local/sbin/okrun-private-network" 'ifconfig "en2" inet "10.77.0.12" netmask "255.255.255.0" up'
assert_file_contains "$MACOS_STATIC_ROOT/Library/LaunchDaemons/com.okrun.guest-health.plist" "<string>19</string>"

MACOS_MISSING_SHARE_ROOT="$WORK_DIR/macos-missing-share-root"
printf '  -> Reject missing macOS guest log share\n'
MACOS_MISSING_START="$SECONDS"
set +e
MACOS_MISSING_OUTPUT="$(
  OKRUN_GUEST_ROOT="$MACOS_MISSING_SHARE_ROOT" "$ROOT/scripts/guest-tools/install-okrun-guest-tools.sh" \
    --guest-os macos \
    --health-interval 13 2>&1
)"
MACOS_MISSING_STATUS=$?
set -e

if [[ "$MACOS_MISSING_STATUS" -ne 78 ]]; then
  echo "macOS installer should fail with exit 78 when the guest log share is missing." >&2
  printf '%s\n' "$MACOS_MISSING_OUTPUT" >&2
  exit 1
fi

if ! grep -q 'Missing writable Okrun guest log share: /Volumes/okrun/okrun-guest-logs' <<<"$MACOS_MISSING_OUTPUT"; then
  echo "macOS missing-share error did not mention /Volumes/okrun." >&2
  printf '%s\n' "$MACOS_MISSING_OUTPUT" >&2
  exit 1
fi

printf '  OK Reject missing macOS guest log share (%ss)\n' "$((SECONDS - MACOS_MISSING_START))"

MANUAL_ROOT="$WORK_DIR/manual-root"
mkdir -p "$MANUAL_ROOT/etc/systemd/network" "$MANUAL_ROOT/etc/systemd/system" "$MANUAL_ROOT/etc" "$MANUAL_ROOT/mnt/okrun/okrun-guest-logs"
cat >"$MANUAL_ROOT/etc/fstab" <<'EOF'
okrun /mnt/okrun virtiofs defaults 0 0
EOF
cat >"$MANUAL_ROOT/etc/systemd/network/10-manual-private.network" <<'EOF'
# manually managed
[Match]
Name=enp0s9

[Network]
Address=10.77.0.44/24
EOF

run_step "Preserve unrelated manual network config" \
  env OKRUN_GUEST_ROOT="$MANUAL_ROOT" "$ROOT/scripts/guest-tools/install-okrun-guest-tools.sh" \
  --private-ip 10.77.0.9/24 \
  --private-iface enp0s2 \
  --health-interval 9

if [[ -f "$MANUAL_ROOT/etc/systemd/system/mnt-okrun.mount" ]]; then
  echo "Installer should not create mnt-okrun.mount when /etc/fstab already mounts /mnt/okrun." >&2
  exit 1
fi

assert_file_contains "$MANUAL_ROOT/etc/fstab" "okrun /mnt/okrun virtiofs"
assert_file_contains "$MANUAL_ROOT/etc/systemd/network/10-manual-private.network" "manually managed"
assert_file_contains "$MANUAL_ROOT/etc/systemd/network/10-manual-private.network" "Address=10.77.0.44/24"
assert_file_contains "$MANUAL_ROOT/etc/systemd/network/20-okrun-private.network" "Address=10.77.0.9/24"
if grep -q "10.77.0.9/24" "$MANUAL_ROOT/etc/systemd/network/10-manual-private.network"; then
  echo "Installer should not overwrite unrelated private network config." >&2
  exit 1
fi

cat >"$BIN_DIR/ip" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
scenario="${OKRUN_FAKE_IP_SCENARIO:-nat-only}"
if [[ "$*" == "-o link show" ]]; then
  printf '1: lo: <LOOPBACK,UP> mtu 65536\n'
  printf '2: enp0s1: <BROADCAST,MULTICAST,UP> mtu 1500\n'
  if [[ "$scenario" == "private-with-dhcp-lease" ]]; then
    printf '3: enp0s2: <BROADCAST,MULTICAST,UP> mtu 1500\n'
  fi
elif [[ "$*" == "-4 -o addr show dev enp0s1" ]]; then
  printf '2: enp0s1 inet 192.168.64.16/24 brd 192.168.64.255 scope global enp0s1\n'
elif [[ "$*" == "-4 -o addr show dev enp0s2" && "$scenario" == "private-with-dhcp-lease" ]]; then
  printf '3: enp0s2 inet 10.77.0.20/24 brd 10.77.0.255 scope global enp0s2\n'
elif [[ "$*" == "-4 -o addr show dev lo" ]]; then
  printf '1: lo inet 127.0.0.1/8 scope host lo\n'
elif [[ "$*" == "-4 route show default" ]]; then
  printf 'default via 192.168.64.1 dev enp0s1 proto dhcp src 192.168.64.16 metric 100\n'
elif [[ "$1" == "link" && "$2" == "show" && "$3" == "dev" ]]; then
  printf '2: %s: <BROADCAST,MULTICAST,UP> mtu 1500\n' "$4"
fi
EOF
chmod +x "$BIN_DIR/ip"

AUTO_DHCP_ROOT="$WORK_DIR/auto-dhcp-root"
mkdir -p "$AUTO_DHCP_ROOT/mnt/okrun/okrun-guest-logs"
run_step "Auto-detect private interface with existing DHCP lease" \
  env PATH="$BIN_DIR:$PATH" OKRUN_FAKE_IP_SCENARIO=private-with-dhcp-lease OKRUN_GUEST_ROOT="$AUTO_DHCP_ROOT" "$ROOT/scripts/guest-tools/install-okrun-guest-tools.sh" \
  --health-interval 11

assert_file_contains "$AUTO_DHCP_ROOT/etc/systemd/network/20-okrun-private.network" "Name=enp0s2"
assert_file_contains "$AUTO_DHCP_ROOT/etc/systemd/network/20-okrun-private.network" "DHCP=ipv4"

NO_PRIVATE_ROOT="$WORK_DIR/no-private-root"
mkdir -p "$NO_PRIVATE_ROOT/mnt/okrun/okrun-guest-logs"
run_step "Skip private config when no private interface exists" \
  env PATH="$BIN_DIR:$PATH" OKRUN_GUEST_ROOT="$NO_PRIVATE_ROOT" "$ROOT/scripts/guest-tools/install-okrun-guest-tools.sh" \
  --private-ip 10.77.0.9/24 \
  --health-interval 11

if [[ -e "$NO_PRIVATE_ROOT/etc/systemd/network/20-okrun-private.network" ]]; then
  echo "Installer should not create private network config when only the NAT interface is detected." >&2
  exit 1
fi

cat >"$BIN_DIR/cut" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${*: -1}" == "/proc/uptime" ]]; then
  printf '123.45 67.89\n'
else
  /usr/bin/cut "$@"
fi
EOF
cat >"$BIN_DIR/date" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "-Is" ]]; then
  printf '2026-05-10T00:00:00+00:00\n'
else
  /bin/date "$@"
fi
EOF
chmod +x "$BIN_DIR/cut" "$BIN_DIR/date"

ROTATE_LOG_DIR="$WORK_DIR/rotate-logs"
mkdir -p "$ROTATE_LOG_DIR"
printf '%060000d\n' 1 >"$ROTATE_LOG_DIR/guest-health.log"
run_step "Rotate guest health log" \
  env OKRUN_LOG_DIR="$ROTATE_LOG_DIR" \
  OKRUN_LOG_MAX_BYTES=50000 \
  OKRUN_LOG_KEEP=2 \
  OKRUN_HEALTH_ONCE=1 \
  PATH="$BIN_DIR:$PATH" \
  "$ROOT/scripts/guest-tools/okrun-guest-health.sh"

if [[ ! -f "$ROTATE_LOG_DIR/guest-health.log.1" ]]; then
  echo "Guest health log should rotate before appending when over the size limit." >&2
  ls -la "$ROTATE_LOG_DIR" >&2
  exit 1
fi

assert_file_contains "$ROTATE_LOG_DIR/guest-health.log" "health-start"
assert_file_contains "$ROTATE_LOG_DIR/guest-health.log.1" "000000000000"

MISSING_SHARE_ROOT="$WORK_DIR/missing-share-root"
printf '  -> Reject missing guest log share\n'
MISSING_START="$SECONDS"
set +e
MISSING_OUTPUT="$(
  OKRUN_GUEST_ROOT="$MISSING_SHARE_ROOT" "$ROOT/scripts/guest-tools/install-okrun-guest-tools.sh" \
    --health-interval 13 2>&1
)"
MISSING_STATUS=$?
set -e

if [[ "$MISSING_STATUS" -ne 78 ]]; then
  echo "Installer should fail with exit 78 when the guest log share is missing." >&2
  printf '%s\n' "$MISSING_OUTPUT" >&2
  exit 1
fi

if ! grep -q 'Missing writable Okrun guest log share: /mnt/okrun/okrun-guest-logs' <<<"$MISSING_OUTPUT" ||
   ! grep -q '<project>/vm/guest-logs' <<<"$MISSING_OUTPUT" ||
   ! grep -q 'fully stop the VM, and start it again' <<<"$MISSING_OUTPUT"; then
  echo "Missing-share error did not include the expected setup instructions." >&2
  printf '%s\n' "$MISSING_OUTPUT" >&2
  exit 1
fi

printf '  OK Reject missing guest log share (%ss)\n' "$((SECONDS - MISSING_START))"
