#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PAYLOAD_DIR="$ROOT/scripts/guest-tools"
REMOTE_DIR="/tmp/okrun-guest-tools.$$"
SSH_USER="${OKRUN_GUEST_USER:-}"
SSH_PORT="${OKRUN_GUEST_PORT:-22}"
SSH_IDENTITY="${OKRUN_GUEST_IDENTITY:-}"
PRIVATE_IP_CIDR=""
PRIVATE_IFACE="auto"
PRIVATE_DHCP_EXPLICIT="0"
ENABLE_VIRTIOFS_MOUNT="1"
RESIZE_ROOT="0"
HEALTH_INTERVAL="60"
LOG_SHARE_NAME="okrun-guest-logs"

usage() {
  cat <<'EOF'
Usage: scripts/install-guest-tools.sh [options] <hostname-or-ip>

Copies and installs generic Okrun guest support over SSH/SCP.

Options:
  --user USER              SSH user. Defaults to current local user or OKRUN_GUEST_USER.
  --port PORT              SSH port. Defaults to 22 or OKRUN_GUEST_PORT.
  --identity PATH          SSH identity file. Defaults to OKRUN_GUEST_IDENTITY.
  --private-dhcp           Configure the private-network interface with DHCP. This is
                           the default when --private-ip is not supplied.
  --private-ip CIDR        Persist a private-network address, for example 10.77.0.3/24.
  --private-iface IFACE    Interface for private networking. Defaults to auto-detect in the guest.
  --no-virtiofs-mount      Do not install the /mnt/okrun VirtioFS mount unit.
  --log-share NAME         Required writable share below /mnt/okrun. Default: okrun-guest-logs.
  --resize-root            Try to grow the guest root partition/filesystem.
  --health-interval SEC    Seconds between health log snapshots. Default: 60.
  -h, --help               Show this help.

Examples:
  scripts/install-guest-tools.sh 192.168.64.16
  scripts/install-guest-tools.sh --user arunoda devbox-sandbox.local
  scripts/install-guest-tools.sh --user arunoda --private-ip 10.77.0.3/24 devbox-sandbox.local
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)
      SSH_USER="${2:-}"
      [[ -n "$SSH_USER" ]] || { echo "Missing --user value" >&2; exit 64; }
      shift 2
      ;;
    --port)
      SSH_PORT="${2:-}"
      [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || { echo "--port must be numeric" >&2; exit 64; }
      shift 2
      ;;
    --identity)
      SSH_IDENTITY="${2:-}"
      [[ -n "$SSH_IDENTITY" ]] || { echo "Missing --identity value" >&2; exit 64; }
      shift 2
      ;;
    --private-ip)
      PRIVATE_IP_CIDR="${2:-}"
      [[ -n "$PRIVATE_IP_CIDR" ]] || { echo "Missing --private-ip value" >&2; exit 64; }
      shift 2
      ;;
    --private-dhcp)
      PRIVATE_DHCP_EXPLICIT="1"
      shift
      ;;
    --private-iface)
      PRIVATE_IFACE="${2:-}"
      [[ -n "$PRIVATE_IFACE" ]] || { echo "Missing --private-iface value" >&2; exit 64; }
      shift 2
      ;;
    --no-virtiofs-mount)
      ENABLE_VIRTIOFS_MOUNT="0"
      shift
      ;;
    --log-share)
      LOG_SHARE_NAME="${2:-}"
      [[ -n "$LOG_SHARE_NAME" ]] || { echo "Missing --log-share value" >&2; exit 64; }
      if [[ "$LOG_SHARE_NAME" == */* || "$LOG_SHARE_NAME" == *:* ]]; then
        echo "--log-share must be a VirtioFS share name, not a path." >&2
        exit 64
      fi
      shift 2
      ;;
    --resize-root)
      RESIZE_ROOT="1"
      shift
      ;;
    --health-interval)
      HEALTH_INTERVAL="${2:-}"
      [[ "$HEALTH_INTERVAL" =~ ^[0-9]+$ ]] || { echo "--health-interval must be seconds" >&2; exit 64; }
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 64
      ;;
    *)
      break
      ;;
  esac
done

TARGET_HOST="${1:-}"
if [[ -z "$TARGET_HOST" || $# -gt 1 ]]; then
  usage >&2
  exit 64
fi

if [[ -z "$SSH_USER" ]]; then
  SSH_USER="$(id -un)"
fi

SSH_TARGET="$SSH_USER@$TARGET_HOST"
SSH_ARGS=(-p "$SSH_PORT" -o BatchMode=no -o StrictHostKeyChecking=accept-new)
SCP_ARGS=(-P "$SSH_PORT" -o BatchMode=no -o StrictHostKeyChecking=accept-new)
if [[ -n "$SSH_IDENTITY" ]]; then
  SSH_ARGS+=(-i "$SSH_IDENTITY")
  SCP_ARGS+=(-i "$SSH_IDENTITY")
fi

INSTALL_ARGS=(--health-interval "$HEALTH_INTERVAL" --log-share "$LOG_SHARE_NAME")
if [[ "$ENABLE_VIRTIOFS_MOUNT" == "0" ]]; then
  INSTALL_ARGS+=(--no-virtiofs-mount)
fi
if [[ "$RESIZE_ROOT" == "1" ]]; then
  INSTALL_ARGS+=(--resize-root)
fi
if [[ -z "$PRIVATE_IP_CIDR" || "$PRIVATE_DHCP_EXPLICIT" == "1" ]]; then
  INSTALL_ARGS+=(--private-dhcp)
fi
if [[ -n "$PRIVATE_IP_CIDR" ]]; then
  INSTALL_ARGS+=(--private-ip "$PRIVATE_IP_CIDR" --private-iface "$PRIVATE_IFACE")
elif [[ "$PRIVATE_IFACE" != "auto" ]]; then
  INSTALL_ARGS+=(--private-iface "$PRIVATE_IFACE")
fi

echo "Installing Okrun guest tools on $SSH_TARGET..."
ssh "${SSH_ARGS[@]}" "$SSH_TARGET" "rm -rf '$REMOTE_DIR' && mkdir -p '$REMOTE_DIR'"
scp "${SCP_ARGS[@]}" "$PAYLOAD_DIR"/*.sh "$SSH_TARGET:$REMOTE_DIR/"

remote_install_cmd="chmod +x '$REMOTE_DIR'/*.sh && sudo '$REMOTE_DIR/install-okrun-guest-tools.sh'"
for arg in "${INSTALL_ARGS[@]}"; do
  printf -v quoted_arg ' %q' "$arg"
  remote_install_cmd+="$quoted_arg"
done

ssh -t "${SSH_ARGS[@]}" "$SSH_TARGET" "$remote_install_cmd"
ssh "${SSH_ARGS[@]}" "$SSH_TARGET" "rm -rf '$REMOTE_DIR'"

echo "Installed Okrun guest tools on $SSH_TARGET."
echo "Guest diagnostics: ssh ${SSH_ARGS[*]} $SSH_TARGET 'sudo okrun-guest-diagnose'"
