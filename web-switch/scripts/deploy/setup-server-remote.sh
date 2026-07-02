#!/usr/bin/env bash

# setup-server-remote.sh
# Purpose: Installs dependencies and deploys okrun-switch on a Debian/Ubuntu VM.
# Usage: ./setup-server-remote.sh [--restart-only] <HOSTNAME> <REPO_URL> [TLS_PORT] [STATUS_PORT] [SSH_PORT] [ACCESS_NETWORK] [ACCESS_IFACE] [ACCESS_IP] [ACCESS_MTU]

set -euo pipefail

SERVICE_NAME="okrun-switch"
SERVICE_USER="okrun-switch"
BASE_DIR="/opt/okrun-switch"
APP_DIR="$BASE_DIR/source"
WEB_SWITCH_DIR="$APP_DIR/web-switch"
CERT_DIR="$BASE_DIR/certs"
NODE_PATH="${OKRUN_SWITCH_NODE_PATH:-}"

usage() {
  cat <<'EOF'
Usage: ./setup-server-remote.sh [--restart-only] <HOSTNAME> <REPO_URL> [TLS_PORT] [STATUS_PORT] [SSH_PORT] [ACCESS_NETWORK] [ACCESS_IFACE] [ACCESS_IP] [ACCESS_MTU]

Options:
  --restart-only   Restart the existing okrun-switch systemd service and run health checks.
  --help           Show this help text.

Access port positional args are optional. Leave ACCESS_NETWORK empty to disable
Linux TAP access. ACCESS_NETWORK must match the clients' networkIdentifier shown
in /status, e.g. okrun. When enabled, ACCESS_IP must be a CIDR such as
10.77.0.1/24.
EOF
}

RESTART_ONLY=false
POSITIONAL=()
for arg in "$@"; do
  case "$arg" in
    --restart-only)
      RESTART_ONLY=true
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --*)
      echo "Error: Unknown option: $arg"
      usage
      exit 1
      ;;
    *)
      POSITIONAL+=("$arg")
      ;;
  esac
done

if [[ "${#POSITIONAL[@]}" -lt 2 ]]; then
  echo "Error: Hostname and repository URL are required."
  usage
  exit 1
fi

HOSTNAME="${POSITIONAL[0]}"
REPO_URL="${POSITIONAL[1]}"
SWITCH_TLS_PORT="${POSITIONAL[2]:-9443}"
SWITCH_STATUS_PORT="${POSITIONAL[3]:-8080}"
SSH_PORT="${POSITIONAL[4]:-22}"
SWITCH_ACCESS_NETWORK="${POSITIONAL[5]:-${OKRUN_SWITCH_ACCESS_NETWORK:-}}"
SWITCH_ACCESS_IFACE="${POSITIONAL[6]:-${OKRUN_SWITCH_ACCESS_IFACE:-oksw0}}"
SWITCH_ACCESS_IP="${POSITIONAL[7]:-${OKRUN_SWITCH_ACCESS_IP:-}}"
SWITCH_ACCESS_MTU="${POSITIONAL[8]:-${OKRUN_SWITCH_ACCESS_MTU:-1500}}"

is_port() {
  local value="$1"
  [[ "$value" =~ ^[0-9]+$ ]] && (( 10#$value >= 1 && 10#$value <= 65535 ))
}

for port_name in SWITCH_TLS_PORT SWITCH_STATUS_PORT SSH_PORT; do
  if ! is_port "${!port_name}"; then
    echo "Error: $port_name must be a TCP port number, got: ${!port_name}"
    exit 1
  fi
done

if [[ -n "$SWITCH_ACCESS_NETWORK" ]]; then
  if [[ -z "$SWITCH_ACCESS_IP" ]]; then
    echo "Error: ACCESS_IP is required when ACCESS_NETWORK is set."
    exit 1
  fi
  if [[ ! "$SWITCH_ACCESS_MTU" =~ ^[0-9]+$ ]] || (( 10#$SWITCH_ACCESS_MTU < 576 || 10#$SWITCH_ACCESS_MTU > 9000 )); then
    echo "Error: ACCESS_MTU must be a number from 576 to 9000, got: $SWITCH_ACCESS_MTU"
    exit 1
  fi
  if [[ "$SWITCH_ACCESS_NETWORK" =~ [[:space:]] || "$SWITCH_ACCESS_IFACE" =~ [[:space:]] || "$SWITCH_ACCESS_IP" =~ [[:space:]] ]]; then
    echo "Error: ACCESS_* values must not contain whitespace."
    exit 1
  fi
fi

if [[ "$(id -u)" -eq 0 ]]; then
  REAL_USER="${SUDO_USER:-root}"
else
  REAL_USER="${USER:-$(id -un)}"
fi
REAL_GROUP="$(id -gn "$REAL_USER" 2>/dev/null || echo "$REAL_USER")"

run_sudo() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

run_as_real_user() {
  if [[ "$(id -u)" -eq 0 && "$REAL_USER" != "root" ]]; then
    sudo -H -u "$REAL_USER" "$@"
  else
    "$@"
  fi
}

require_sudo() {
  if [[ "$(id -u)" -eq 0 ]]; then
    return 0
  fi

  if ! sudo -n true 2>/dev/null; then
    echo "ERROR: This setup requires sudo access without interactive password prompts."
    echo "Ensure this user has sudo privileges, then re-run setup."
    exit 1
  fi
}

create_service_user() {
  if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
    echo "Creating dedicated $SERVICE_USER system user..."
    run_sudo useradd --system --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"
  else
    echo "$SERVICE_USER user already exists."
  fi
}

require_existing_service_user() {
  if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
    echo "Error: $SERVICE_USER user does not exist. Run full setup before --restart-only."
    exit 1
  fi
}

validate_cert_files() {
  local missing=false
  for file in \
    "$CERT_DIR/server-cert.pem" \
    "$CERT_DIR/server-key.pem" \
    "$CERT_DIR/ca-cert.pem" \
    "$CERT_DIR/crl.txt"; do
    if [[ ! -f "$file" ]]; then
      echo "Missing required certificate file: $file"
      missing=true
    fi
  done

  if [[ "$missing" == true ]]; then
    cat <<EOF

Upload switch certificates before starting the service:
  cd web-switch
  npm run cert:init
  npm run cert:server -- $HOSTNAME
  ./scripts/deploy/setup-server.sh --upload-certs
EOF
    exit 1
  fi
}

fix_cert_permissions() {
  validate_cert_files
  run_sudo chown -R "$SERVICE_USER:$SERVICE_USER" "$CERT_DIR"
  run_sudo chmod 700 "$CERT_DIR"
  run_sudo chmod 600 "$CERT_DIR/server-key.pem"
  run_sudo chmod 644 "$CERT_DIR/server-cert.pem" "$CERT_DIR/ca-cert.pem" "$CERT_DIR/crl.txt"
}

install_basic_tools() {
  echo "Updating apt..."
  run_sudo apt update

  echo "Installing basic tools..."
  run_sudo apt install -y ca-certificates curl git unzip openssl iproute2 python3 avahi-daemon libnss-mdns
}

install_node() {
  echo "Checking Node.js status..."

  if [[ -n "$NODE_PATH" ]]; then
    if [[ ! -x "$NODE_PATH" ]]; then
      echo "Error: OKRUN_SWITCH_NODE_PATH is set but executable not found: $NODE_PATH"
      exit 1
    fi
    echo "Using custom Node.js path from OKRUN_SWITCH_NODE_PATH: $NODE_PATH"
  else
    local arch node_arch lts_data target_version target_major target_node_version
    arch="$(uname -m)"
    case "$arch" in
      x86_64)
        node_arch="linux-x64"
        ;;
      aarch64|arm64)
        node_arch="linux-arm64"
        ;;
      *)
        echo "Error: Unsupported architecture: $arch"
        exit 1
        ;;
    esac

    lts_data="$(curl -fsSL https://nodejs.org/dist/index.json 2>/dev/null | head -c 10000 || true)"
    if [[ -n "$lts_data" ]]; then
      target_version="$(echo "$lts_data" | grep -oE '\{"version":"v[0-9]+\.[^}]*"lts":"[^"]+"[^}]*\}' | head -1 | grep -oE '"version":"v[0-9]+' | grep -oE 'v[0-9]+' || true)"
      target_major="$(echo "$target_version" | grep -oE '[0-9]+' || true)"
    else
      target_major=""
    fi

    if [[ -n "${target_major:-}" ]]; then
      target_node_version="v${target_major}"
      echo "Latest LTS detected: Node.js ${target_node_version}.x"
    else
      target_node_version="v22"
      target_major="22"
      echo "Could not detect latest LTS. Using fallback: Node.js ${target_node_version}"
    fi

    local install_node=false
    if [[ -x "/usr/local/bin/node" ]]; then
      local current_node_version
      current_node_version="$(/usr/local/bin/node -v)"
      echo "Found custom Node.js installation: $current_node_version"
      if [[ "$current_node_version" == "$target_node_version"* ]]; then
        echo "Node.js is already at target LTS version $target_node_version."
      else
        echo "Node.js version mismatch. Target: $target_node_version, current: $current_node_version"
        install_node=true
      fi
    else
      echo "Custom Node.js not found at /usr/local/bin/node."
      install_node=true
    fi

    if [[ "$install_node" == true ]]; then
      local node_version_full node_tarball node_url shasums_url temp_dir expected_hash actual_hash
      echo "Installing Node.js ${target_node_version}.x from official Node.js distribution..."
      node_version_full="$(curl -fsSL "https://nodejs.org/dist/latest-${target_node_version}.x/" 2>/dev/null | grep -oE "node-${target_node_version}\.[0-9]+\.[0-9]+-${node_arch}\.tar\.gz" | head -1 | sed "s/node-//;s/-${node_arch}\.tar\.gz//" || true)"
      if [[ -z "$node_version_full" ]]; then
        node_version_full="${target_node_version}.15.0"
        echo "Could not detect latest ${target_node_version}.x version. Using fallback: $node_version_full"
      else
        echo "Installing Node.js $node_version_full..."
      fi

      node_tarball="node-${node_version_full}-${node_arch}.tar.gz"
      node_url="https://nodejs.org/dist/${node_version_full}/${node_tarball}"
      shasums_url="https://nodejs.org/dist/${node_version_full}/SHASUMS256.txt"
      temp_dir="$(mktemp -d)"

      echo "Downloading Node.js $node_version_full for $arch..."
      curl -fsSL "$node_url" -o "$temp_dir/$node_tarball"
      curl -fsSL "$shasums_url" -o "$temp_dir/SHASUMS256.txt"

      echo "Verifying SHA256 checksum..."
      expected_hash="$(grep "$node_tarball" "$temp_dir/SHASUMS256.txt" | awk '{print $1}')"
      actual_hash="$(sha256sum "$temp_dir/$node_tarball" | awk '{print $1}')"
      if [[ -z "$expected_hash" || "$expected_hash" != "$actual_hash" ]]; then
        echo "Error: SHA256 checksum verification failed for $node_tarball"
        echo "Expected: $expected_hash"
        echo "Actual:   $actual_hash"
        exit 1
      fi

      echo "Extracting Node.js to /usr/local..."
      run_sudo tar --no-same-owner -xz -C /usr/local --strip-components=1 -f "$temp_dir/$node_tarball"
      rm -rf "$temp_dir"
    fi

    NODE_PATH="/usr/local/bin/node"
  fi

  if [[ ! -x "$NODE_PATH" ]]; then
    echo "Error: Node.js executable not found at $NODE_PATH"
    exit 1
  fi

  local node_major
  node_major="$("$NODE_PATH" -p 'process.versions.node.split(".")[0]')"
  if (( 10#$node_major < 20 )); then
    echo "Error: okrun-switch requires Node.js 20 or newer, found $("$NODE_PATH" -v)"
    exit 1
  fi

  echo "Using Node.js at: $NODE_PATH ($("$NODE_PATH" -v))"
}

clone_or_update_repo() {
  echo "Preparing application directory..."
  run_sudo mkdir -p "$BASE_DIR"
  run_sudo chown "$REAL_USER:$REAL_GROUP" "$BASE_DIR"

  if [[ -d "$APP_DIR" ]]; then
    run_sudo chown -R "$REAL_USER:$REAL_GROUP" "$APP_DIR"
  fi

  if [[ -d "$APP_DIR/.git" ]]; then
    echo "App directory exists. Updating repository..."
    (
      cd "$APP_DIR"
      run_as_real_user git fetch origin
      run_as_real_user git reset --hard origin/main
    )
    echo "Repository updated."
  else
    echo "App directory does not exist. Cloning repository..."
    if [[ -d "$APP_DIR" ]]; then
      run_sudo rm -rf "$APP_DIR"
    fi
    run_as_real_user git clone "$REPO_URL" "$APP_DIR"
    echo "Repository cloned."
  fi

  if [[ ! -d "$WEB_SWITCH_DIR" ]]; then
    echo "Error: web-switch directory not found at $WEB_SWITCH_DIR"
    exit 1
  fi
}

install_web_switch_dependencies() {
  local npm_path node_bin_dir
  node_bin_dir="$(dirname "$NODE_PATH")"
  npm_path="$node_bin_dir/npm"

  if [[ ! -x "$npm_path" ]]; then
    npm_path="$(command -v npm || true)"
  fi

  if [[ -z "$npm_path" || ! -x "$npm_path" ]]; then
    echo "Error: npm not found next to Node.js."
    exit 1
  fi

  echo "Installing web-switch npm dependencies..."
  (
    cd "$WEB_SWITCH_DIR"
    run_as_real_user env PATH="$node_bin_dir:$PATH" "$npm_path" install --omit=dev --no-audit --no-fund --package-lock=false
  )
}

write_systemd_unit() {
  echo "Writing systemd unit..."

  local access_env access_security
  access_env=""
  access_security="RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX"
  if [[ -n "$SWITCH_ACCESS_NETWORK" ]]; then
    access_env="Environment=OKRUN_SWITCH_ACCESS_NETWORK=$SWITCH_ACCESS_NETWORK
Environment=OKRUN_SWITCH_ACCESS_IFACE=$SWITCH_ACCESS_IFACE
Environment=OKRUN_SWITCH_ACCESS_IP=$SWITCH_ACCESS_IP
Environment=OKRUN_SWITCH_ACCESS_MTU=$SWITCH_ACCESS_MTU
Environment=OKRUN_SWITCH_ACCESS_PYTHON=/usr/bin/python3"
    access_security="# TAP access port needs CAP_NET_ADMIN and AF_NETLINK for iproute2.
CapabilityBoundingSet=CAP_NET_ADMIN
AmbientCapabilities=CAP_NET_ADMIN
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK"
  fi

  run_sudo tee "/etc/systemd/system/$SERVICE_NAME.service" >/dev/null <<EOF
[Unit]
Description=OkRun Web Switch
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_USER
WorkingDirectory=$WEB_SWITCH_DIR
ExecStart=$NODE_PATH src/index.js
Restart=always
RestartSec=10
Environment=NODE_ENV=production
Environment=OKRUN_SWITCH_HOST=0.0.0.0
Environment=OKRUN_SWITCH_TLS_PORT=$SWITCH_TLS_PORT
Environment=OKRUN_SWITCH_STATUS_PORT=$SWITCH_STATUS_PORT
Environment=OKRUN_SWITCH_SERVER_KEY=$CERT_DIR/server-key.pem
Environment=OKRUN_SWITCH_SERVER_CERT=$CERT_DIR/server-cert.pem
Environment=OKRUN_SWITCH_CA_CERT=$CERT_DIR/ca-cert.pem
Environment=OKRUN_SWITCH_CRL=$CERT_DIR/crl.txt
$access_env
UMask=0077

# Security hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectClock=true
ProtectControlGroups=true
ProtectHostname=true
RestrictRealtime=true
RestrictNamespaces=true
RestrictSUIDSGID=true
$access_security
LockPersonality=true
RemoveIPC=true

[Install]
WantedBy=multi-user.target
EOF

  run_sudo systemctl daemon-reload
  run_sudo systemctl enable "$SERVICE_NAME"
}

set_sshd_option() {
  local key="$1"
  local value="$2"
  local file="/etc/ssh/sshd_config"

  if grep -Eq "^[#[:space:]]*$key[[:space:]]+" "$file"; then
    run_sudo sed -i "s/^[#[:space:]]*$key[[:space:]].*/$key $value/" "$file"
  else
    echo "$key $value" | run_sudo tee -a "$file" >/dev/null
  fi
}

restart_ssh_service() {
  if run_sudo systemctl restart ssh 2>/dev/null; then
    return 0
  fi
  run_sudo systemctl restart sshd
}

configure_ssh_hardening() {
  echo "Hardening SSH security..."
  if [[ ! -f /etc/ssh/sshd_config ]]; then
    echo "sshd_config not found; skipping SSH hardening."
    return 0
  fi

  run_sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.okrun-switch.bak
  set_sshd_option PasswordAuthentication no
  set_sshd_option ChallengeResponseAuthentication no
  set_sshd_option PermitRootLogin no

  echo "Validating SSH config..."
  if run_sudo sshd -t; then
    restart_ssh_service
  else
    echo "ERROR: SSH config is invalid. Restoring backup..."
    run_sudo cp /etc/ssh/sshd_config.okrun-switch.bak /etc/ssh/sshd_config
    run_sudo sshd -t
    restart_ssh_service
  fi
}

configure_fail2ban() {
  echo "Installing and configuring Fail2Ban..."
  run_sudo apt install -y fail2ban
  run_sudo tee /etc/fail2ban/jail.local >/dev/null <<'EOF'
[DEFAULT]
bantime  = 24h
findtime = 10m
maxretry = 3

[sshd]
enabled = true
backend = systemd
EOF
  run_sudo systemctl restart fail2ban
}

configure_unattended_upgrades() {
  echo "Configuring unattended upgrades..."
  run_sudo apt install -y unattended-upgrades
  echo "unattended-upgrades unattended-upgrades/enable_auto_updates boolean true" | run_sudo debconf-set-selections
  run_sudo dpkg-reconfigure -f noninteractive unattended-upgrades
}

configure_firewall() {
  echo "Configuring firewall..."
  run_sudo apt install -y ufw
  run_sudo ufw default deny incoming
  run_sudo ufw default allow outgoing
  run_sudo ufw allow "$SSH_PORT/tcp" comment "SSH"
  run_sudo ufw allow "$SWITCH_TLS_PORT/tcp" comment "okrun-switch mTLS"
  run_sudo ufw --force enable
}

configure_journal_limits() {
  echo "Configuring journal size limits..."
  run_sudo mkdir -p /etc/systemd/journald.conf.d
  run_sudo tee /etc/systemd/journald.conf.d/99-okrun-switch-size-limits.conf >/dev/null <<'EOF'
[Journal]
SystemMaxUse=500M
MaxFileSec=1week
EOF
  run_sudo systemctl restart systemd-journald
}

configure_host_security() {
  configure_ssh_hardening
  configure_fail2ban
  configure_unattended_upgrades
  configure_firewall
  configure_journal_limits
}

restart_service() {
  echo "Restarting $SERVICE_NAME..."
  run_sudo systemctl restart "$SERVICE_NAME"
}

health_check() {
  echo ""
  echo "Running health checks..."

  if run_sudo systemctl is-active --quiet "$SERVICE_NAME"; then
    echo "okrun-switch service is active."
  else
    echo "okrun-switch service is NOT active."
    run_sudo journalctl -u "$SERVICE_NAME" -n 40 --no-pager || true
    exit 1
  fi

  local status_ok=false
  for _ in 1 2 3 4 5; do
    if curl -fsS --connect-timeout 2 --max-time 5 "http://127.0.0.1:$SWITCH_STATUS_PORT/healthz" >/dev/null 2>&1; then
      status_ok=true
      break
    fi
    sleep 1
  done

  if [[ "$status_ok" == true ]]; then
    echo "Local status endpoint is responding."
  else
    echo "Local status endpoint is NOT responding."
    run_sudo journalctl -u "$SERVICE_NAME" -n 40 --no-pager || true
    exit 1
  fi

  if ss -tln | grep -Eq "[:.]$SWITCH_TLS_PORT[[:space:]]"; then
    echo "TLS port $SWITCH_TLS_PORT is listening."
  else
    echo "TLS port $SWITCH_TLS_PORT is NOT listening."
    exit 1
  fi

  if [[ -n "$SWITCH_ACCESS_NETWORK" ]]; then
    if ip link show "$SWITCH_ACCESS_IFACE" >/dev/null 2>&1; then
      echo "Access TAP interface $SWITCH_ACCESS_IFACE exists."
    else
      echo "Access TAP interface $SWITCH_ACCESS_IFACE was not created."
      run_sudo journalctl -u "$SERVICE_NAME" -n 60 --no-pager || true
      exit 1
    fi

    if ip -o addr show dev "$SWITCH_ACCESS_IFACE" | grep -Fq "$SWITCH_ACCESS_IP"; then
      echo "Access TAP interface has $SWITCH_ACCESS_IP."
    else
      echo "Access TAP interface does not have expected IP $SWITCH_ACCESS_IP."
      ip -o addr show dev "$SWITCH_ACCESS_IFACE" || true
      exit 1
    fi
  fi

  echo "Firewall exposes SSH ($SSH_PORT/tcp) and okrun-switch mTLS ($SWITCH_TLS_PORT/tcp); HTTP/HTTPS/status ports are not opened."
}

echo "Starting okrun-switch setup..."
echo "Target directory: $BASE_DIR"
echo "Repository: $REPO_URL"
echo "Hostname: $HOSTNAME"
echo "TLS port: $SWITCH_TLS_PORT"
echo "Status port: $SWITCH_STATUS_PORT"
if [[ -n "$SWITCH_ACCESS_NETWORK" ]]; then
  echo "Access port: enabled network=$SWITCH_ACCESS_NETWORK iface=$SWITCH_ACCESS_IFACE ip=$SWITCH_ACCESS_IP mtu=$SWITCH_ACCESS_MTU"
else
  echo "Access port: disabled"
fi
echo "Configuring for user: $REAL_USER ($REAL_GROUP)"

require_sudo

if [[ "$RESTART_ONLY" == true ]]; then
  echo "Restart-only mode enabled."
  require_existing_service_user
  fix_cert_permissions
  restart_service
  health_check
  echo ""
  echo "Restart completed successfully."
  exit 0
fi

install_basic_tools
install_node
clone_or_update_repo
install_web_switch_dependencies
create_service_user
fix_cert_permissions
configure_host_security
write_systemd_unit
restart_service
health_check

echo ""
echo "okrun-switch deployment complete!"
echo "Service status: systemctl status $SERVICE_NAME"
echo "View logs: journalctl -u $SERVICE_NAME -f"
