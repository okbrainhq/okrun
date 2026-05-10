#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/okrun-guest-tools-e2e.XXXXXX")"
BIN_DIR="$WORK_DIR/bin"
LOG_FILE="$WORK_DIR/commands.log"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

mkdir -p "$BIN_DIR"

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

OKRUN_E2E_LOG="$LOG_FILE" PATH="$BIN_DIR:$PATH" "$ROOT/scripts/install-guest-tools.sh" \
  --user tester \
  --port 2222 \
  --identity "$WORK_DIR/id_ed25519" \
  --private-ip 10.77.0.9/24 \
  --health-interval 5 \
  --resize-root \
  example.test

if ! grep -q 'scp.*install-okrun-guest-tools.sh.*okrun-guest-health.sh.*tester@example.test' "$LOG_FILE"; then
  echo "Expected payload scp command was not recorded." >&2
  cat "$LOG_FILE" >&2
  exit 1
fi

if ! grep -q 'sudo.*install-okrun-guest-tools.sh.*--health-interval.*5.*--resize-root.*--private-ip.*10.77.0.9/24.*--private-iface.*auto' "$LOG_FILE"; then
  echo "Expected remote install command was not recorded." >&2
  cat "$LOG_FILE" >&2
  exit 1
fi

if ! bash -n "$ROOT/scripts/install-guest-tools.sh" \
  || ! bash -n "$ROOT/scripts/guest-tools/install-okrun-guest-tools.sh" \
  || ! bash -n "$ROOT/scripts/guest-tools/okrun-guest-health.sh"; then
  echo "Shell syntax validation failed." >&2
  exit 1
fi

GUEST_ROOT="$WORK_DIR/guest-root"
OKRUN_GUEST_ROOT="$GUEST_ROOT" "$ROOT/scripts/guest-tools/install-okrun-guest-tools.sh" \
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
[[ -d "$GUEST_ROOT/mnt/okrun" ]]

assert_file_contains "$GUEST_ROOT/etc/systemd/system/okrun-guest-health.service" "Environment=OKRUN_HEALTH_INTERVAL=7"
assert_file_contains "$GUEST_ROOT/etc/systemd/system/okrun-guest-health.service" "ExecStart=/usr/local/lib/okrun/okrun-guest-health.sh"
assert_file_contains "$GUEST_ROOT/etc/systemd/system/mnt-okrun.mount" "What=okrun"
assert_file_contains "$GUEST_ROOT/etc/systemd/system/mnt-okrun.mount" "Where=/mnt/okrun"
assert_file_contains "$GUEST_ROOT/etc/systemd/system/mnt-okrun.mount" "Type=virtiofs"
assert_file_contains "$GUEST_ROOT/etc/systemd/network/20-okrun-private.network" "Name=enp0s2"
assert_file_contains "$GUEST_ROOT/etc/systemd/network/20-okrun-private.network" "Address=10.77.0.9/24"

MANUAL_ROOT="$WORK_DIR/manual-root"
mkdir -p "$MANUAL_ROOT/etc/systemd/network" "$MANUAL_ROOT/etc/systemd/system" "$MANUAL_ROOT/etc"
cat >"$MANUAL_ROOT/etc/fstab" <<'EOF'
okrun /mnt/okrun virtiofs defaults 0 0
EOF
cat >"$MANUAL_ROOT/etc/systemd/network/20-okrun-private.network" <<'EOF'
# manually managed
[Match]
Name=enp0s9

[Network]
Address=10.77.0.44/24
EOF

OKRUN_GUEST_ROOT="$MANUAL_ROOT" "$ROOT/scripts/guest-tools/install-okrun-guest-tools.sh" \
  --private-ip 10.77.0.9/24 \
  --private-iface enp0s2 \
  --health-interval 9

if [[ -f "$MANUAL_ROOT/etc/systemd/system/mnt-okrun.mount" ]]; then
  echo "Installer should not create mnt-okrun.mount when /etc/fstab already mounts /mnt/okrun." >&2
  exit 1
fi

assert_file_contains "$MANUAL_ROOT/etc/fstab" "okrun /mnt/okrun virtiofs"
assert_file_contains "$MANUAL_ROOT/etc/systemd/network/20-okrun-private.network" "manually managed"
assert_file_contains "$MANUAL_ROOT/etc/systemd/network/20-okrun-private.network" "Address=10.77.0.44/24"
if grep -q "10.77.0.9/24" "$MANUAL_ROOT/etc/systemd/network/20-okrun-private.network"; then
  echo "Installer should not overwrite existing private network config." >&2
  exit 1
fi

echo "Guest tools installer E2E passed."
