#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
usage() {
  echo "Usage: sudo bash web-switch/scripts/install-network-client.sh HOST_BUNDLE.json [IP=auto] [NETWORK=okrun] [INTERFACE=okrun0] [LOCAL_SERVER=host:9444] [SUBNET=10.77.0.0/24]"
}
if [[ "${1:-}" == --help ]]; then usage; exit 0; fi
if [[ $# -lt 1 || $# -gt 6 ]]; then usage >&2; exit 1; fi
[[ "$(uname -s)" == Linux && $EUID -eq 0 ]] || { echo 'Run as root on Linux' >&2; exit 1; }
for cmd in node python3 ip systemctl; do
  command -v "$cmd" >/dev/null || { echo "Missing dependency: $cmd" >&2; exit 1; }
done
node -e 'if (+process.versions.node.split(".")[0] < 20) process.exit(1)' || { echo 'Node.js 20+ required' >&2; exit 1; }
[[ -c /dev/net/tun ]] || { echo 'Missing /dev/net/tun; enable TUN/TAP on this host' >&2; exit 1; }
BUNDLE="$1"
CONFIG_DIR=/etc/okrun-network
BUNDLE_TARGET="$CONFIG_DIR/host.json"
[[ -f "$BUNDLE" && ! -L "$BUNDLE" ]] || {
  echo 'Bundle must be an existing regular file, not a symlink. For first installation, pass the private host bundle path.' >&2
  exit 1
}
[[ ! -L "$CONFIG_DIR" && ( ! -e "$CONFIG_DIR" || -d "$CONFIG_DIR" ) && ! -L "$BUNDLE_TARGET" && ( ! -e "$BUNDLE_TARGET" || -f "$BUNDLE_TARGET" ) ]] || {
  echo 'Credential destination must be a real directory and regular file, not symlinks.' >&2
  exit 1
}
IP="${2:-auto}"
SUBNET="${6:-10.77.0.0/24}"
NETWORK="${3:-okrun}"
IFACE="${4:-okrun0}"
LOCAL_ARGS=()
if [[ -n "${5:-}" ]]; then
  LOCAL_ARGS=(--local-server "$5")
fi
# Reject whitespace/metacharacters before interpolating into the unit.
[[ ( "$IP" == auto || "$IP" =~ ^[0-9a-fA-F.:/]+$ ) && "$SUBNET" =~ ^[0-9./]+$ && "$NETWORK" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.:-]*$ && "$IFACE" =~ ^[a-zA-Z0-9_-]+$ ]] || { echo 'Invalid arguments' >&2; exit 1; }
node "$ROOT/bin/okrun-network.js" --bundle "$BUNDLE" --ip "$IP" --subnet "$SUBNET" --network "$NETWORK" --interface "$IFACE" "${LOCAL_ARGS[@]}" --check
NODE="$(command -v node)"
[[ "$NODE" == /usr/bin/node || "$NODE" == /usr/local/bin/node ]] || { echo 'Install Node.js system-wide at /usr/bin/node or /usr/local/bin/node (not a home-directory version manager)' >&2; exit 1; }
if [[ "$IP" == auto ]]; then
  command -v avahi-daemon >/dev/null || { echo 'Install avahi-daemon (sudo apt install avahi-daemon) for .local discovery' >&2; exit 1; }
fi
# Always stage a private copy, including when reusing the installed bundle.
# Copying directly onto itself would fail and could leave the service stopped.
# Stage/validate before touching the running service; rename on the same filesystem
# so a replacement is never partially written. Never print credential contents.
umask 077
install -d -o root -g root -m 700 "$CONFIG_DIR"
STAGED_BUNDLE="$(mktemp "$CONFIG_DIR/.host.json.XXXXXX")"
trap 'rm -f -- "$STAGED_BUNDLE"' EXIT
install -o root -g root -m 600 -- "$BUNDLE" "$STAGED_BUNDLE"
node "$ROOT/bin/okrun-network.js" --bundle "$STAGED_BUNDLE" --ip "$IP" --subnet "$SUBNET" --network "$NETWORK" --interface "$IFACE" "${LOCAL_ARGS[@]}" --check
if [[ "$IP" == auto ]]; then
  systemctl enable --now avahi-daemon.service
fi
# Stop before replacing files so restarts cannot load a partial installation.
systemctl stop okrun-network.service 2>/dev/null || {
  if systemctl cat okrun-network.service >/dev/null 2>&1; then
    echo "Could not stop existing service" >&2; exit 1
  fi
}
# Install only network code, not the Swift application or CA private keys.
install -d -m 755 /opt/okrun-network/src /opt/okrun-network/bin
mv -fT -- "$STAGED_BUNDLE" "$BUNDLE_TARGET"
trap - EXIT
install -m 644 "$ROOT/src/network-client.js" "$ROOT/src/protocol.js" "$ROOT/src/network-router.js" "$ROOT/src/host-address.js" "$ROOT/src/host-client.js" /opt/okrun-network/src/
install -m 644 "$ROOT/bin/okrun-network.js" "$ROOT/bin/okrun-switch-tap-helper.py" /opt/okrun-network/bin/
sed -e "s|@NODE@|$NODE|g" \
    -e "s|@NETWORK@|$NETWORK|g" \
    -e "s|@IFACE@|$IFACE|g" \
    -e "s|@IP@|$IP|g" \
    -e "s|@SUBNET@|$SUBNET|g" \
    -e "s|@LOCAL_ARGS@|${LOCAL_ARGS[*]}|g" \
    "$ROOT/systemd/okrun-network.service.in" > /etc/systemd/system/okrun-network.service
chmod 644 /etc/systemd/system/okrun-network.service
# Do not let NetworkManager race the TAP helper with DHCP or route changes.
# Only the dedicated TAP is excluded; no physical interfaces are reconfigured.
if command -v nmcli >/dev/null && systemctl is-active --quiet NetworkManager; then
  install -d -m 755 /etc/NetworkManager/conf.d
  cat > /etc/NetworkManager/conf.d/90-okrun-network.conf <<EOF
[device-okrun-network]
match-device=interface-name:$IFACE
managed=0
EOF
  nmcli general reload conf
fi
systemctl daemon-reload
systemctl enable okrun-network.service
systemctl restart okrun-network.service
echo 'Installed. Check connection: journalctl -u okrun-network -n 30 --no-pager'
