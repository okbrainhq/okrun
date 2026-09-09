#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
usage() {
  echo "Usage: sudo bash scripts/install-network-client.sh HOST_BUNDLE.json PRIVATE_IP/PREFIX [NETWORK=okrun] [INTERFACE=okrun0] [LOCAL_SERVER=host:9444]"
}
if [[ "${1:-}" == --help ]]; then usage; exit 0; fi
if [[ $# -lt 2 || $# -gt 5 ]]; then usage >&2; exit 1; fi
[[ "$(uname -s)" == Linux && $EUID -eq 0 ]] || { echo 'Run as root on Linux' >&2; exit 1; }
for cmd in node python3 ip systemctl; do
  command -v "$cmd" >/dev/null || { echo "Missing dependency: $cmd" >&2; exit 1; }
done
node -e 'if (+process.versions.node.split(".")[0] < 20) process.exit(1)' || { echo 'Node.js 20+ required' >&2; exit 1; }
[[ -c /dev/net/tun ]] || { echo 'Missing /dev/net/tun; enable TUN/TAP on this host' >&2; exit 1; }
BUNDLE="$1"
IP="$2"
NETWORK="${3:-okrun}"
IFACE="${4:-okrun0}"
LOCAL_ARGS=()
if [[ -n "${5:-}" ]]; then
  LOCAL_ARGS=(--local-server "$5")
fi
# Reject whitespace/metacharacters before interpolating into the unit.
[[ "$IP" =~ ^[0-9a-fA-F.:/]+$ && "$NETWORK" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.:-]*$ && "$IFACE" =~ ^[a-zA-Z0-9_-]+$ ]] || { echo 'Invalid arguments' >&2; exit 1; }
node "$ROOT/web-switch/bin/okrun-network.js" --bundle "$BUNDLE" --ip "$IP" --network "$NETWORK" --interface "$IFACE" "${LOCAL_ARGS[@]}" --check
NODE="$(command -v node)"
[[ "$NODE" == /usr/bin/node || "$NODE" == /usr/local/bin/node ]] || { echo 'Install Node.js system-wide at /usr/bin/node or /usr/local/bin/node (not a home-directory version manager)' >&2; exit 1; }
# Install only network code, not the Swift application or CA private keys.
install -d -m 755 /opt/okrun-network/src /opt/okrun-network/bin
install -d -m 700 /etc/okrun-network
install -m 600 "$BUNDLE" /etc/okrun-network/host.json
install -m 644 "$ROOT/web-switch/src/network-client.js" "$ROOT/web-switch/src/protocol.js" "$ROOT/web-switch/src/network-router.js" /opt/okrun-network/src/
install -m 644 "$ROOT/web-switch/bin/okrun-network.js" "$ROOT/web-switch/bin/okrun-switch-tap-helper.py" /opt/okrun-network/bin/
cat > /etc/systemd/system/okrun-network.service <<EOF
[Unit]
Description=OKRun network-only client
Wants=network-online.target
After=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=$NODE /opt/okrun-network/bin/okrun-network.js --bundle /etc/okrun-network/host.json --network $NETWORK --interface $IFACE --ip $IP ${LOCAL_ARGS[*]}
Restart=on-failure
RestartSec=5
TimeoutStopSec=5
User=root
UMask=0077
NoNewPrivileges=true
CapabilityBoundingSet=CAP_NET_ADMIN
AmbientCapabilities=CAP_NET_ADMIN
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
DevicePolicy=closed
DeviceAllow=/dev/net/tun rw

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable okrun-network.service
systemctl restart okrun-network.service
echo 'Installed. Check connection: journalctl -u okrun-network -n 30 --no-pager'
