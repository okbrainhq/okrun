#!/usr/bin/env bash
set -euo pipefail

PRIVATE_IP_CIDR=""
PRIVATE_IFACE="auto"
ENABLE_VIRTIOFS_MOUNT="1"
RESIZE_ROOT="0"
HEALTH_INTERVAL="60"
GUEST_ROOT="${OKRUN_GUEST_ROOT:-}"

guest_path() {
  printf '%s%s' "$GUEST_ROOT" "$1"
}

guest_glob() {
  local pattern="$1"
  if [[ -n "$GUEST_ROOT" ]]; then
    printf '%s%s' "$GUEST_ROOT" "$pattern"
  else
    printf '%s' "$pattern"
  fi
}

usage() {
  cat <<'EOF'
Usage: sudo install-okrun-guest-tools.sh [options]

Installs generic Okrun guest support inside a Linux VM.

Options:
  --private-ip CIDR        Persist a private-network address, for example 10.77.0.3/24.
  --private-iface IFACE    Interface for --private-ip. Defaults to auto-detect.
  --no-virtiofs-mount      Do not install the /mnt/okrun VirtioFS mount unit.
  --resize-root            Try to grow the root partition/filesystem if free disk space is adjacent.
  --health-interval SEC    Seconds between health log snapshots. Default: 60.
  -h, --help               Show this help.

Logs are written to /var/log/okrun/guest-health.log and journald.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --private-ip)
      PRIVATE_IP_CIDR="${2:-}"
      [[ -n "$PRIVATE_IP_CIDR" ]] || { echo "Missing --private-ip value" >&2; exit 64; }
      shift 2
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
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
done

if [[ "${EUID:-$(id -u)}" -ne 0 && -z "$GUEST_ROOT" ]]; then
  echo "Run this script as root, usually via sudo." >&2
  exit 77
fi

install -d -m 0755 "$(guest_path /usr/local/lib/okrun)" "$(guest_path /usr/local/sbin)" "$(guest_path /var/log/okrun)"
install -m 0755 "$(dirname "$0")/okrun-guest-health.sh" "$(guest_path /usr/local/lib/okrun/okrun-guest-health.sh)"

install -d -m 0755 "$(guest_path /etc/systemd/system)"
cat >"$(guest_path /etc/systemd/system/okrun-guest-health.service)" <<EOF
[Unit]
Description=Okrun guest health logger
After=local-fs.target network-online.target

[Service]
Type=simple
Environment=OKRUN_HEALTH_INTERVAL=$HEALTH_INTERVAL
ExecStart=/usr/local/lib/okrun/okrun-guest-health.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

cat >"$(guest_path /usr/local/sbin/okrun-guest-diagnose)" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

section() {
  printf '\n== %s ==\n' "$1"
}

section "Identity"
hostnamectl 2>/dev/null || hostname
uname -a

section "Memory"
free -h 2>/dev/null || cat /proc/meminfo

section "Disk"
lsblk -f 2>/dev/null || true
df -hT / /boot /boot/efi /mnt/okrun 2>/dev/null || true
findmnt -R / /mnt/okrun 2>/dev/null || true

section "Network"
ip -br addr 2>/dev/null || true
ip route 2>/dev/null || true

section "Swap"
swapon --show 2>/dev/null || true

section "Recent Okrun Health"
tail -200 /var/log/okrun/guest-health.log 2>/dev/null || true

section "Kernel Alerts"
journalctl -k --since '30 minutes ago' --no-pager 2>/dev/null |
  grep -Ei 'bug:|i/o error|blk_update_request|buffer i/o|ext4-fs error|oom|out of memory|hung task|soft lockup|hard lockup' || true
EOF
chmod 0755 "$(guest_path /usr/local/sbin/okrun-guest-diagnose)"

virtiofs_mount_exists() {
  if [[ -f "$(guest_path /etc/systemd/system/mnt-okrun.mount)" ]]; then
    return 0
  fi

  if grep -RqsE '(^What=okrun$|^Where=/mnt/okrun$|^Type=virtiofs$)' "$(guest_glob /etc/systemd/system)"/*.mount 2>/dev/null; then
    return 0
  fi

  if grep -qsE '^[^#]*[[:space:]]+/mnt/okrun[[:space:]]+virtiofs([[:space:]]|$)' "$(guest_path /etc/fstab)" 2>/dev/null; then
    return 0
  fi

  return 1
}

if [[ "$ENABLE_VIRTIOFS_MOUNT" == "1" ]]; then
  if virtiofs_mount_exists; then
    echo "Okrun VirtioFS mount config already exists; leaving it unchanged."
  else
    install -d -m 0755 "$(guest_path /mnt/okrun)"
    cat >"$(guest_path /etc/systemd/system/mnt-okrun.mount)" <<'EOF'
[Unit]
Description=Okrun shared directories

[Mount]
What=okrun
Where=/mnt/okrun
Type=virtiofs
Options=defaults

[Install]
WantedBy=multi-user.target
EOF
  fi
fi

detect_private_iface() {
  if [[ "$PRIVATE_IFACE" != "auto" ]]; then
    printf '%s\n' "$PRIVATE_IFACE"
    return
  fi

  local candidate
  candidate="$(
    ip -o link show 2>/dev/null |
      awk -F': ' '$2 != "lo" { print $2 }' |
      while IFS= read -r iface; do
        if ! ip -4 -o addr show dev "$iface" 2>/dev/null | grep -q 'inet '; then
          printf '%s\n' "$iface"
          break
        fi
      done
  )"

  if [[ -z "$candidate" ]]; then
    candidate="$(
      ip -o link show 2>/dev/null |
        awk -F': ' '$2 != "lo" { print $2; exit }'
    )"
  fi

  printf '%s\n' "$candidate"
}

private_network_config_exists() {
  local private_iface="$1"
  local private_ip_cidr="$2"

  if [[ -z "$GUEST_ROOT" ]] && ip -o addr show 2>/dev/null | grep -qE "[[:space:]]$private_ip_cidr([[:space:]]|$)"; then
    return 0
  fi

  if grep -RqsE "^Address=$private_ip_cidr$" "$(guest_glob /etc/systemd/network)"/*.network 2>/dev/null; then
    return 0
  fi

  if [[ -f "$(guest_path /etc/systemd/network/20-okrun-private.network)" ]]; then
    return 0
  fi

  if grep -RqsE "^Name=$private_iface$" "$(guest_glob /etc/systemd/network)"/*.network 2>/dev/null &&
     grep -RqsE '^Address=' "$(guest_glob /etc/systemd/network)"/*.network 2>/dev/null; then
    return 0
  fi

  return 1
}

installed_private_network_config="0"
if [[ -n "$PRIVATE_IP_CIDR" ]]; then
  private_iface="$(detect_private_iface)"
  if [[ -z "$private_iface" ]]; then
    echo "Could not detect a private network interface for $PRIVATE_IP_CIDR." >&2
    exit 70
  fi

  if private_network_config_exists "$private_iface" "$PRIVATE_IP_CIDR"; then
    echo "Okrun private network config already exists; leaving it unchanged."
  else
    install -d -m 0755 "$(guest_path /etc/systemd/network)"
    cat >"$(guest_path /etc/systemd/network/20-okrun-private.network)" <<EOF
[Match]
Name=$private_iface

[Network]
Address=$PRIVATE_IP_CIDR
EOF
    installed_private_network_config="1"
  fi
fi

resize_root_if_requested() {
  [[ "$RESIZE_ROOT" == "1" ]] || return 0
  if [[ -n "$GUEST_ROOT" ]]; then
    echo "Skipping root resize in test root: $GUEST_ROOT" >&2
    return 0
  fi

  local source fstype disk part partition_number
  source="$(findmnt -no SOURCE /)"
  fstype="$(findmnt -no FSTYPE /)"

  if [[ ! "$source" =~ ^/dev/ ]]; then
    echo "Skipping root resize: root source is not a block device: $source" >&2
    return 0
  fi

  if ! command -v growpart >/dev/null 2>&1; then
    echo "Skipping root resize: growpart is not installed. Install cloud-guest-utils first." >&2
    return 0
  fi

  if [[ "$source" =~ ^(/dev/[a-zA-Z]+)([0-9]+)$ ]]; then
    disk="${BASH_REMATCH[1]}"
    partition_number="${BASH_REMATCH[2]}"
  elif [[ "$source" =~ ^(/dev/[a-zA-Z0-9]+)p([0-9]+)$ ]]; then
    disk="${BASH_REMATCH[1]}"
    partition_number="${BASH_REMATCH[2]}"
  else
    echo "Skipping root resize: cannot parse root partition: $source" >&2
    return 0
  fi

  growpart "$disk" "$partition_number" || true

  case "$fstype" in
    ext2|ext3|ext4)
      resize2fs "$source"
      ;;
    xfs)
      xfs_growfs /
      ;;
    *)
      echo "Skipping filesystem resize: unsupported root filesystem: $fstype" >&2
      ;;
  esac
}

resize_root_if_requested

if [[ -n "$GUEST_ROOT" ]]; then
  echo "Installed files into test root: $GUEST_ROOT"
elif command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload
  systemctl enable --now okrun-guest-health.service

  if [[ "$ENABLE_VIRTIOFS_MOUNT" == "1" && -f /etc/systemd/system/mnt-okrun.mount ]]; then
    systemctl enable mnt-okrun.mount
    systemctl start mnt-okrun.mount || true
  fi

  if [[ "$installed_private_network_config" == "1" ]]; then
    systemctl enable systemd-networkd
    systemctl restart systemd-networkd
  fi
else
  echo "systemctl not found; installed files but did not enable services." >&2
fi

echo "Okrun guest tools installed."
echo "Run: sudo okrun-guest-diagnose"
