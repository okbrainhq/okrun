#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d "/tmp/okrun-sw.XXXXXX")"
SWITCH_PID=""
SERVER_HOST_PID=""
CLIENT_HOST_PID=""

cleanup() {
  local status="$?"
  if [[ -n "${CLIENT_HOST_PID:-}" ]] && kill -0 "$CLIENT_HOST_PID" 2>/dev/null; then
    kill "$CLIENT_HOST_PID" 2>/dev/null || true
    wait "$CLIENT_HOST_PID" 2>/dev/null || true
  fi
  if [[ -n "${SERVER_HOST_PID:-}" ]] && kill -0 "$SERVER_HOST_PID" 2>/dev/null; then
    kill "$SERVER_HOST_PID" 2>/dev/null || true
    wait "$SERVER_HOST_PID" 2>/dev/null || true
  fi
  if [[ -n "${SWITCH_PID:-}" ]] && kill -0 "$SWITCH_PID" 2>/dev/null; then
    kill "$SWITCH_PID" 2>/dev/null || true
    wait "$SWITCH_PID" 2>/dev/null || true
  fi
  if [[ "$status" -eq 0 && -z "${KEEP_OKRUN_SWITCH_E2E_LOGS:-}" ]]; then
    rm -rf "$WORK_DIR"
  else
    printf 'Logs kept in %s\n' "$WORK_DIR" >&2
  fi
}
trap cleanup EXIT

run_step() {
  local name="$1"
  shift
  local log_file="$WORK_DIR/${name//[^A-Za-z0-9_.-]/_}.log"
  local start="$SECONDS"

  printf '  -> %s\n' "$name"
  set +e
  "$@" >"$log_file" 2>&1
  local status="$?"
  set -e

  if [[ "$status" -eq 0 ]]; then
    printf '  OK %s (%ss)\n' "$name" "$((SECONDS - start))"
    return 0
  fi

  printf '  FAIL %s (%ss)\n' "$name" "$((SECONDS - start))" >&2
  printf '\n--- %s output ---\n' "$name" >&2
  sed -n '1,240p' "$log_file" >&2
  return "$status"
}

free_port() {
  node -e 'const net = require("node:net"); const s = net.createServer(); s.listen(0, "127.0.0.1", () => { console.log(s.address().port); s.close(); });'
}

wait_for_http_ok() {
  local port="$1"
  local deadline=$((SECONDS + 10))
  until curl -fsS "http://127.0.0.1:${port}/healthz" >/dev/null 2>&1; do
    if [[ "$SECONDS" -ge "$deadline" ]]; then
      printf 'Timed out waiting for web-switch health.\n' >&2
      sed -n '1,240p' "$WORK_DIR/web-switch.log" >&2 || true
      return 1
    fi
    sleep 0.1
  done
}

wait_for_log_marker() {
  local file="$1"
  local marker="$2"
  local timeout="$3"
  local deadline=$((SECONDS + timeout))
  until grep -Fq "$marker" "$file" 2>/dev/null; do
    if [[ -n "${SERVER_HOST_PID:-}" ]] && ! kill -0 "$SERVER_HOST_PID" 2>/dev/null; then
      printf 'Server host exited before %s.\n' "$marker" >&2
      sed -n '1,240p' "$file" >&2 || true
      return 1
    fi
    if [[ "$SECONDS" -ge "$deadline" ]]; then
      printf 'Timed out waiting for %s.\n' "$marker" >&2
      sed -n '1,240p' "$file" >&2 || true
      return 1
    fi
    sleep 0.2
  done
}

switch_host_count() {
  curl -fsS "http://127.0.0.1:${STATUS_PORT}/status" \
    | node -e 'let text = ""; process.stdin.on("data", c => text += c); process.stdin.on("end", () => console.log(JSON.parse(text).hostCount ?? 0));'
}

wait_for_switch_hosts() {
  local expected="$1"
  local timeout="$2"
  local deadline=$((SECONDS + timeout))
  local count="0"

  until [[ "$count" -ge "$expected" ]]; do
    count="$(switch_host_count 2>/dev/null || echo 0)"
    if [[ "$SECONDS" -ge "$deadline" ]]; then
      printf 'Timed out waiting for %s switch host(s); last count=%s.\n' "$expected" "$count" >&2
      sed -n '1,240p' "$WORK_DIR/web-switch.log" >&2 || true
      return 1
    fi
    sleep 0.2
  done
}

wait_for_switch_hosts_or_marker() {
  local expected="$1"
  local timeout="$2"
  local marker_file="$3"
  local marker="$4"
  local deadline=$((SECONDS + timeout))
  local count="0"

  while true; do
    if grep -Fq "$marker" "$marker_file" 2>/dev/null; then
      return 0
    fi

    count="$(switch_host_count 2>/dev/null || echo 0)"
    if [[ "$count" -ge "$expected" ]]; then
      return 0
    fi

    if [[ "$SECONDS" -ge "$deadline" ]]; then
      printf 'Timed out waiting for %s switch host(s) or %s; last count=%s.\n' "$expected" "$marker" "$count" >&2
      sed -n '1,240p' "$WORK_DIR/web-switch.log" >&2 || true
      return 1
    fi
    sleep 0.2
  done
}

write_host_config() {
  local home="$1"
  local cert_dir="$2"
  local network_id="$3"
  local tls_port="$4"

  mkdir -p "$home"
  cat >"$home/private-networks.json" <<EOF
{
  "version": 1,
  "privateNetworks": {
    "$network_id": {
      "dhcp": {
        "enabled": false,
        "mode": "range",
        "cidr": "10.77.0.0/24",
        "rangeStart": "10.77.0.20",
        "rangeEnd": "10.77.0.30",
        "leaseSeconds": 3600
      },
      "switch": {
        "enabled": true,
        "server": "localhost:$tls_port",
        "caCert": "$cert_dir/ca-cert.pem",
        "clientCert": "$cert_dir/client-cert.pem",
        "clientKey": "$cert_dir/client-key.pem"
      }
    }
  }
}
EOF
}

start_web_switch() {
  local name="$1"
  local mode="${2:-append}"

  printf '  -> %s\n' "$name"
  if [[ "$mode" == "truncate" ]]; then
    : >"$WORK_DIR/web-switch.log"
  fi

  OKRUN_SWITCH_DEBUG=1 node "$ROOT/web-switch/src/index.js" \
    --host 127.0.0.1 \
    --tls-port "$TLS_PORT" \
    --status-port "$STATUS_PORT" \
    --server-bundle "$CERT_DIR/server/okrun-switch-server-bundle.json" \
    --crl "$CA_DIR/crl.txt" \
    --keepalive-interval-ms 1000 \
    --keepalive-timeout-ms 5000 \
    --init-timeout-ms 10000 \
    >>"$WORK_DIR/web-switch.log" 2>&1 &
  SWITCH_PID="$!"
  wait_for_http_ok "$STATUS_PORT"
  printf '  OK %s\n' "$name"
}

stop_web_switch() {
  local name="$1"

  printf '  -> %s\n' "$name"
  if [[ -n "${SWITCH_PID:-}" ]] && kill -0 "$SWITCH_PID" 2>/dev/null; then
    kill "$SWITCH_PID" 2>/dev/null || true
    wait "$SWITCH_PID" 2>/dev/null || true
  fi
  SWITCH_PID=""
  printf '  OK %s\n' "$name"
}

dump_runtime_logs() {
  printf '\n--- server host output ---\n' >&2
  sed -n '1,260p' "$WORK_DIR/server-host.log" >&2 || true
  printf '\n--- client host output ---\n' >&2
  sed -n '1,260p' "$WORK_DIR/client-host.log" >&2 || true
  printf '\n--- web-switch output ---\n' >&2
  sed -n '1,320p' "$WORK_DIR/web-switch.log" >&2 || true
}

printf '  -> Prepare Alpine boot fixtures\n'
"$ROOT/scripts/prepare-e2e-linux.sh" >"$WORK_DIR/e2e-linux-paths.txt"
printf '  OK Prepare Alpine boot fixtures\n'

KERNEL="$(sed -n '1p' "$WORK_DIR/e2e-linux-paths.txt")"
PRIVATE_NETWORK_SERVER_INITRAMFS="$(sed -n '5p' "$WORK_DIR/e2e-linux-paths.txt")"
PRIVATE_NETWORK_RECONNECT_CLIENT_INITRAMFS="$(sed -n '10p' "$WORK_DIR/e2e-linux-paths.txt")"

run_step "Build production app" "$ROOT/scripts/build.sh"

TLS_PORT="$(free_port)"
STATUS_PORT="$(free_port)"
CA_DIR="$WORK_DIR/ca"
CERT_DIR="$WORK_DIR/certs"
NETWORK_ID="oksw-$$"
HOST_A_HOME="$WORK_DIR/host-a-home"
HOST_B_HOME="$WORK_DIR/host-b-home"
HOST_A_SOCKET_ROOT="$WORK_DIR/a-s"
HOST_B_SOCKET_ROOT="$WORK_DIR/b-s"

run_step "Create switch certificates" \
  node "$ROOT/web-switch/bin/okrun-switch-ca.js" init --ca-dir "$CA_DIR"
run_step "Create switch server certificate" \
  node "$ROOT/web-switch/bin/okrun-switch-ca.js" issue-server --ca-dir "$CA_DIR" --hostname localhost --output "$CERT_DIR/server"
run_step "Create host A certificate" \
  node "$ROOT/web-switch/bin/okrun-switch-ca.js" issue-host --ca-dir "$CA_DIR" --name headless-a --output "$CERT_DIR/host-a"
run_step "Create host B certificate" \
  node "$ROOT/web-switch/bin/okrun-switch-ca.js" issue-host --ca-dir "$CA_DIR" --name headless-b --output "$CERT_DIR/host-b"

write_host_config "$HOST_A_HOME" "$CERT_DIR/host-a" "$NETWORK_ID" "$TLS_PORT"
write_host_config "$HOST_B_HOME" "$CERT_DIR/host-b" "$NETWORK_ID" "$TLS_PORT"
mkdir -p "$HOST_A_SOCKET_ROOT" "$HOST_B_SOCKET_ROOT"

start_web_switch "Start web-switch" truncate

printf '  -> Start switch server host VM\n'
env OKRUN_HOME="$HOST_A_HOME" \
  OKRUN_PRIVATE_NETWORK_SOCKET_ROOT="$HOST_A_SOCKET_ROOT" \
  OKRUN_SWITCH_DEBUG=1 \
  "$ROOT/OkrunVM.app/Contents/MacOS/OkrunVM" \
  --headless-switch-host-test \
  --kernel "$KERNEL" \
  --initramfs "$PRIVATE_NETWORK_SERVER_INITRAMFS" \
  --private-network-id "$NETWORK_ID" \
  --expect-output OKRUN_E2E_PRIVATE_NETWORK_SERVER_READY \
  --mirror-serial-output \
  --linger-after-output 120 \
  --timeout 60 \
  >"$WORK_DIR/server-host.log" 2>&1 &
SERVER_HOST_PID="$!"
if ! wait_for_log_marker "$WORK_DIR/server-host.log" OKRUN_E2E_PRIVATE_NETWORK_SERVER_READY 60; then
  dump_runtime_logs
  exit 1
fi
if ! wait_for_switch_hosts 1 10; then
  dump_runtime_logs
  exit 1
fi
printf '  OK Start switch server host VM\n'

printf '  -> Start switch reconnect client VM\n'
env OKRUN_HOME="$HOST_B_HOME" \
  OKRUN_PRIVATE_NETWORK_SOCKET_ROOT="$HOST_B_SOCKET_ROOT" \
  OKRUN_SWITCH_DEBUG=1 \
  "$ROOT/OkrunVM.app/Contents/MacOS/OkrunVM" \
  --headless-switch-host-test \
  --kernel "$KERNEL" \
  --initramfs "$PRIVATE_NETWORK_RECONNECT_CLIENT_INITRAMFS" \
  --private-network-id "$NETWORK_ID" \
  --expect-output OKRUN_E2E_PRIVATE_NETWORK_RECONNECT_PASSED \
  --mirror-serial-output \
  --timeout 150 \
  >"$WORK_DIR/client-host.log" 2>&1 &
CLIENT_HOST_PID="$!"

if ! wait_for_log_marker "$WORK_DIR/client-host.log" OKRUN_E2E_PRIVATE_NETWORK_INITIAL_PASSED 75; then
  dump_runtime_logs
  exit 1
fi
if ! wait_for_switch_hosts 2 10; then
  dump_runtime_logs
  exit 1
fi
printf '  OK Initial ping across web-switch private network\n'

stop_web_switch "Stop web-switch for reconnect"
if ! wait_for_log_marker "$WORK_DIR/client-host.log" OKRUN_E2E_PRIVATE_NETWORK_DISCONNECTED 45; then
  dump_runtime_logs
  exit 1
fi

start_web_switch "Restart web-switch"
if ! wait_for_switch_hosts_or_marker 2 90 "$WORK_DIR/client-host.log" OKRUN_E2E_PRIVATE_NETWORK_RECONNECT_PASSED; then
  dump_runtime_logs
  exit 1
fi

if ! wait_for_log_marker "$WORK_DIR/client-host.log" OKRUN_E2E_PRIVATE_NETWORK_RECONNECT_PASSED 90; then
  dump_runtime_logs
  exit 1
fi

if ! wait "$CLIENT_HOST_PID"; then
  CLIENT_HOST_PID=""
  dump_runtime_logs
  exit 1
fi
CLIENT_HOST_PID=""

printf '  OK Web-switch reconnect preserved private network traffic\n'
printf 'Headless switch E2E passed: OKRUN_E2E_PRIVATE_NETWORK_RECONNECT_PASSED\n'
