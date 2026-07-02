#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NODE="${NODE:-node}"
PYTHON="${PYTHON:-python3}"
WORK_DIR="$(mktemp -d /tmp/okrun-switch-access.XXXXXX)"
SWITCH_PID=""
TAP_CLIENT_PID=""
SSHD_PID=""
MDNS_PID=""
NETNS=""
VETH_ROOT=""
ACCESS_IFACE=""

cleanup() {
  local status="$?"
  set +e
  for pid in "$MDNS_PID" "$SSHD_PID" "$TAP_CLIENT_PID" "$SWITCH_PID"; do
    if [[ -n "${pid:-}" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
  if [[ -n "${NETNS:-}" ]]; then
    sudo -n ip netns delete "$NETNS" >/dev/null 2>&1 || true
  fi
  if [[ -n "${VETH_ROOT:-}" ]]; then
    sudo -n ip link delete "$VETH_ROOT" >/dev/null 2>&1 || true
  fi
  if [[ -n "${ACCESS_IFACE:-}" ]]; then
    sudo -n ip link delete "$ACCESS_IFACE" >/dev/null 2>&1 || true
  fi
  if [[ "$status" -eq 0 && -z "${KEEP_OKRUN_SWITCH_E2E_LOGS:-}" ]]; then
    rm -rf "$WORK_DIR"
  else
    printf 'Logs kept in %s\n' "$WORK_DIR" >&2
  fi
}
trap cleanup EXIT

require_cmd() {
  local name="$1"
  shift || true
  if ! command -v "$name" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "$name" >&2
    exit 1
  fi
}

find_sshd() {
  command -v sshd 2>/dev/null \
    || command -v /usr/sbin/sshd 2>/dev/null \
    || command -v /usr/local/sbin/sshd 2>/dev/null
}

free_port() {
  "$NODE" -e 'const net = require("node:net"); const s = net.createServer(); s.listen(0, "127.0.0.1", () => { console.log(s.address().port); s.close(); });'
}

wait_for_http_ok() {
  local port="$1"
  local deadline=$((SECONDS + 15))
  until curl -fsS "http://127.0.0.1:${port}/healthz" >/dev/null 2>&1; do
    if [[ "$SECONDS" -ge "$deadline" ]]; then
      printf 'Timed out waiting for web-switch health.\n' >&2
      sed -n '1,240p' "$WORK_DIR/web-switch.log" >&2 || true
      exit 1
    fi
    sleep 0.2
  done
}

wait_for_status_host_count() {
  local expected="$1"
  local port="$2"
  local timeout="$3"
  local deadline=$((SECONDS + timeout))
  local count="0"
  until [[ "$count" -ge "$expected" ]]; do
    count="$(curl -fsS "http://127.0.0.1:${port}/status" 2>/dev/null | "$NODE" -e 'let t=""; process.stdin.on("data", c => t += c); process.stdin.on("end", () => console.log(JSON.parse(t).hostCount ?? 0));' 2>/dev/null || echo 0)"
    if [[ "$SECONDS" -ge "$deadline" ]]; then
      printf 'Timed out waiting for %s fabric host(s); last count=%s.\n' "$expected" "$count" >&2
      sed -n '1,260p' "$WORK_DIR/web-switch.log" >&2 || true
      sed -n '1,260p' "$WORK_DIR/tap-client.log" >&2 || true
      exit 1
    fi
    sleep 0.2
  done
}

wait_for_log_marker() {
  local file="$1"
  local marker="$2"
  local timeout="$3"
  local deadline=$((SECONDS + timeout))
  until grep -Fq "$marker" "$file" 2>/dev/null; do
    if [[ "$SECONDS" -ge "$deadline" ]]; then
      printf 'Timed out waiting for %s in %s.\n' "$marker" "$file" >&2
      sed -n '1,260p' "$file" >&2 || true
      exit 1
    fi
    sleep 0.2
  done
}

wait_for_ssh() {
  local target="$1"
  local timeout="$2"
  local deadline=$((SECONDS + timeout))
  until ssh -F "$WORK_DIR/ssh_config" "$target" 'printf OKRUN_ACCESS_SSH_OK' 2>"$WORK_DIR/ssh-attempt.log" | grep -Fq OKRUN_ACCESS_SSH_OK; do
    if [[ "$SECONDS" -ge "$deadline" ]]; then
      printf 'Timed out waiting for SSH to %s.\n' "$target" >&2
      cat "$WORK_DIR/ssh-attempt.log" >&2 || true
      sed -n '1,260p' "$WORK_DIR/sshd.log" >&2 || true
      exit 1
    fi
    sleep 0.5
  done
}

write_mdns_tools() {
  cat >"$WORK_DIR/mdns_responder.py" <<'PY'
import socket, struct, sys
name = sys.argv[1].rstrip('.') + '.'
ip = sys.argv[2]
iface_ip = sys.argv[3]
wire = b''.join(bytes([len(p)]) + p.encode() for p in name.split('.') if p) + b'\0'
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
if hasattr(socket, 'SO_REUSEPORT'):
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
sock.bind(('', 5353))
sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, socket.inet_aton('224.0.0.251') + socket.inet_aton(iface_ip))
sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF, socket.inet_aton(iface_ip))
print('OKRUN_MDNS_RESPONDER_READY', flush=True)
while True:
    data, addr = sock.recvfrom(9000)
    if wire.lower() not in data.lower():
        continue
    if len(data) < 12:
        continue
    txid = data[:2]
    question = data[12:]
    header = txid + struct.pack('!HHHHH', 0x8400, 1, 1, 0, 0)
    answer = b'\xc0\x0c' + struct.pack('!HHIH', 1, 0x8001, 120, 4) + socket.inet_aton(ip)
    response = header + question + answer
    sock.sendto(response, addr)
    sock.sendto(response, ('224.0.0.251', 5353))
PY

  cat >"$WORK_DIR/mdns_query.py" <<'PY'
import random, socket, struct, sys, time
name = sys.argv[1].rstrip('.') + '.'
iface_ip = sys.argv[2]
expected = sys.argv[3]
wire = b''.join(bytes([len(p)]) + p.encode() for p in name.split('.') if p) + b'\0'
txid = random.randrange(0, 65536)
query = struct.pack('!HHHHHH', txid, 0, 1, 0, 0, 0) + wire + struct.pack('!HH', 1, 0x8001)
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
sock.settimeout(0.5)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
if hasattr(socket, 'SO_REUSEPORT'):
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
try:
    sock.bind(('', 5353))
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, socket.inet_aton('224.0.0.251') + socket.inet_aton(iface_ip))
except OSError:
    sock.bind((iface_ip, 0))
sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF, socket.inet_aton(iface_ip))
sock.sendto(query, ('224.0.0.251', 5353))
deadline = time.time() + 5
while time.time() < deadline:
    try:
        data, _addr = sock.recvfrom(9000)
    except socket.timeout:
        continue
    if len(data) < 16 or data[:2] != struct.pack('!H', txid):
        continue
    if socket.inet_aton(expected) in data:
        print(expected)
        sys.exit(0)
print('mDNS response not received', file=sys.stderr)
sys.exit(1)
PY
}

printf '==> Web-switch Linux access-port E2E\n'
require_cmd "$NODE"
require_cmd "$PYTHON"
require_cmd ip
require_cmd curl
require_cmd openssl
require_cmd ssh
require_cmd ssh-keygen
SSHD="$(find_sshd || true)"
if [[ -z "$SSHD" ]]; then
  printf 'Missing required command: sshd\n' >&2
  exit 1
fi
if ! sudo -n true >/dev/null 2>&1; then
  printf 'Passwordless sudo is required for TAP/netns e2e setup.\n' >&2
  exit 1
fi
if [[ ! -e /dev/net/tun ]]; then
  printf '/dev/net/tun is required.\n' >&2
  exit 1
fi
sudo -n mkdir -p /run/sshd

SUFFIX="$(printf '%04x' $$)"
NETNS="oksw${SUFFIX}"
VETH_ROOT="okwr${SUFFIX}"
VETH_NS="okwn${SUFFIX}"
ACCESS_IFACE="oksa${SUFFIX}"
HOST_IFACE="oksh${SUFFIX}"
NETWORK_ID="access-${SUFFIX}"
ACCESS_IP="10.77.0.1"
HOST_IP="10.77.0.20"
UNDERLAY_ROOT_IP="169.254.77.1"
UNDERLAY_NS_IP="169.254.77.2"
MDNS_NAME="okrun-access-e2e.local"
SSH_USER="${OKRUN_E2E_SSH_USER:-$(id -un)}"
TLS_PORT="$(free_port)"
STATUS_PORT="$(free_port)"
CA_DIR="$WORK_DIR/ca"
CERT_DIR="$WORK_DIR/certs"

printf '  -> Create network namespace underlay\n'
sudo -n ip netns add "$NETNS"
sudo -n ip link add "$VETH_ROOT" type veth peer name "$VETH_NS"
sudo -n ip link set "$VETH_NS" netns "$NETNS"
sudo -n ip addr add "${UNDERLAY_ROOT_IP}/30" dev "$VETH_ROOT"
sudo -n ip link set "$VETH_ROOT" up
sudo -n ip netns exec "$NETNS" ip addr add "${UNDERLAY_NS_IP}/30" dev "$VETH_NS"
sudo -n ip netns exec "$NETNS" ip link set lo up
sudo -n ip netns exec "$NETNS" ip link set "$VETH_NS" up
printf '  OK namespace %s\n' "$NETNS"

printf '  -> Create switch certificates\n'
"$NODE" "$ROOT/web-switch/bin/okrun-switch-ca.js" init --ca-dir "$CA_DIR" >"$WORK_DIR/ca-init.log"
"$NODE" "$ROOT/web-switch/bin/okrun-switch-ca.js" issue-server --ca-dir "$CA_DIR" --hostname localhost --output "$CERT_DIR/server" >"$WORK_DIR/server-cert.log"
"$NODE" "$ROOT/web-switch/bin/okrun-switch-ca.js" issue-host --ca-dir "$CA_DIR" --name tap-host --output "$CERT_DIR/tap-host" >"$WORK_DIR/host-cert.log"
printf '  OK certificates\n'

printf '  -> Create SSH test keys\n'
ssh-keygen -q -t ed25519 -N '' -f "$WORK_DIR/id_ed25519"
cp "$WORK_DIR/id_ed25519.pub" "$WORK_DIR/authorized_keys"
ssh-keygen -q -t ed25519 -N '' -f "$WORK_DIR/ssh_host_ed25519_key"
cat >"$WORK_DIR/sshd_config" <<EOF
Port 22
ListenAddress ${HOST_IP}
HostKey ${WORK_DIR}/ssh_host_ed25519_key
AuthorizedKeysFile ${WORK_DIR}/authorized_keys
PasswordAuthentication no
PubkeyAuthentication yes
KbdInteractiveAuthentication no
PermitRootLogin yes
UsePAM no
PidFile ${WORK_DIR}/sshd.pid
StrictModes no
LogLevel VERBOSE
EOF
cat >"$WORK_DIR/ssh_config" <<EOF
Host *
  User ${SSH_USER}
  IdentityFile ${WORK_DIR}/id_ed25519
  UserKnownHostsFile ${WORK_DIR}/known_hosts
  StrictHostKeyChecking no
  BatchMode yes
  ConnectTimeout 3
  ServerAliveInterval 2
  ServerAliveCountMax 2
EOF
printf '  OK SSH keys\n'

printf '  -> Start web-switch with TAP access port\n'
sudo -n env PATH="$PATH" OKRUN_SWITCH_DEBUG=1 "$NODE" "$ROOT/web-switch/src/index.js" \
  --host 0.0.0.0 \
  --tls-port "$TLS_PORT" \
  --status-port "$STATUS_PORT" \
  --server-bundle "$CERT_DIR/server/okrun-switch-server-bundle.json" \
  --crl "$CA_DIR/crl.txt" \
  --access-network "$NETWORK_ID" \
  --access-iface "$ACCESS_IFACE" \
  --access-ip "${ACCESS_IP}/24" \
  --keepalive-interval-ms 1000 \
  --keepalive-timeout-ms 5000 \
  --init-timeout-ms 10000 \
  >"$WORK_DIR/web-switch.log" 2>&1 &
SWITCH_PID="$!"
wait_for_http_ok "$STATUS_PORT"
wait_for_status_host_count 1 "$STATUS_PORT" 15
printf '  OK access port joined fabric\n'

printf '  -> Start private host TAP client in namespace\n'
sudo -n ip netns exec "$NETNS" env PATH="$PATH" OKRUN_SWITCH_DEBUG=1 "$NODE" "$ROOT/web-switch/tests/e2e/tap-client.js" \
  --host "$UNDERLAY_ROOT_IP" \
  --port "$TLS_PORT" \
  --servername localhost \
  --ca "$CA_DIR/ca-cert.pem" \
  --cert "$CERT_DIR/tap-host/client-cert.pem" \
  --key "$CERT_DIR/tap-host/client-key.pem" \
  --network "$NETWORK_ID" \
  --tap-iface "$HOST_IFACE" \
  --ip "${HOST_IP}/24" \
  >"$WORK_DIR/tap-client.log" 2>&1 &
TAP_CLIENT_PID="$!"
wait_for_log_marker "$WORK_DIR/tap-client.log" OKRUN_TAP_CLIENT_READY 15
wait_for_status_host_count 2 "$STATUS_PORT" 15
printf '  OK private host TAP client joined fabric\n'

printf '  -> Start sshd inside private namespace\n'
sudo -n ip netns exec "$NETNS" "$SSHD" -D -e -f "$WORK_DIR/sshd_config" >"$WORK_DIR/sshd.log" 2>&1 &
SSHD_PID="$!"
wait_for_ssh "$HOST_IP" 20
printf '  OK SSH by private IP works\n'

printf '  -> Verify mDNS multicast across access port\n'
write_mdns_tools
sudo -n ip netns exec "$NETNS" "$PYTHON" "$WORK_DIR/mdns_responder.py" "$MDNS_NAME" "$HOST_IP" "$HOST_IP" >"$WORK_DIR/mdns-responder.log" 2>&1 &
MDNS_PID="$!"
wait_for_log_marker "$WORK_DIR/mdns-responder.log" OKRUN_MDNS_RESPONDER_READY 5
"$PYTHON" "$WORK_DIR/mdns_query.py" "$MDNS_NAME" "$ACCESS_IP" "$HOST_IP" >"$WORK_DIR/mdns-query.log"
printf '  OK mDNS query reached private host\n'

if getent hosts "$MDNS_NAME" >"$WORK_DIR/getent-mdns.log" 2>&1; then
  wait_for_ssh "$MDNS_NAME" 10
  printf '  OK SSH by .local works via system resolver\n'
else
  printf '  SKIP SSH by .local: system resolver/NSS did not resolve %s; multicast path was verified.\n' "$MDNS_NAME"
fi

printf 'Web-switch access-port E2E passed: OKRUN_E2E_WEB_SWITCH_ACCESS_PASSED\n'
