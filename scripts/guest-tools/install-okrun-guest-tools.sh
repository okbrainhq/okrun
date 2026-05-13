#!/usr/bin/env bash
set -euo pipefail

PRIVATE_IP_CIDR=""
PRIVATE_IFACE="auto"
PRIVATE_DHCP_EXPLICIT="0"
ENABLE_VIRTIOFS_MOUNT="1"
RESIZE_ROOT="0"
HEALTH_INTERVAL="60"
GUEST_ROOT="${OKRUN_GUEST_ROOT:-}"
managed_virtiofs_mount_config="0"
LOG_SHARE_NAME="okrun-guest-logs"

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
  --private-dhcp           Configure the private-network interface with DHCP, replacing
                           an existing Okrun-managed static private config.
  --private-ip CIDR        Persist a private-network address, for example 10.77.0.3/24.
  --private-iface IFACE    Interface for private networking. Defaults to auto-detect.
  --no-virtiofs-mount      Do not install the /mnt/okrun VirtioFS mount unit.
  --log-share NAME         Required writable share below /mnt/okrun. Default: okrun-guest-logs.
  --resize-root            Try to grow the root partition/filesystem if free disk space is adjacent.
  --health-interval SEC    Seconds between health log snapshots. Default: 60.
  -h, --help               Show this help.

Logs are written to /mnt/okrun/<log-share>/guest-health.log and journald.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
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

if [[ "$LOG_SHARE_NAME" == */* || "$LOG_SHARE_NAME" == *:* ]]; then
  echo "--log-share must be a VirtioFS share name, not a path." >&2
  exit 64
fi

LOG_DIR="/mnt/okrun/$LOG_SHARE_NAME"

install -d -m 0755 "$(guest_path /usr/local/lib/okrun)" "$(guest_path /usr/local/sbin)" "$(guest_path /var/log/okrun)" "$(guest_path /etc/okrun)"
install -m 0755 "$(dirname "$0")/okrun-guest-health.sh" "$(guest_path /usr/local/lib/okrun/okrun-guest-health.sh)"
cat >"$(guest_path /etc/okrun/guest-tools.env)" <<EOF
OKRUN_LOG_DIR=$LOG_DIR
OKRUN_LOG_PROBE_TIMEOUT=8
EOF

install -d -m 0755 "$(guest_path /etc/systemd/system)"
cat >"$(guest_path /etc/systemd/system/okrun-guest-health.service)" <<EOF
[Unit]
Description=Okrun guest health logger
After=local-fs.target network-online.target

[Service]
Type=simple
Environment=OKRUN_HEALTH_INTERVAL=$HEALTH_INTERVAL
EnvironmentFile=/etc/okrun/guest-tools.env
ExecStart=/usr/local/lib/okrun/okrun-guest-health.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

cat >"$(guest_path /usr/local/sbin/okrun-guest-diagnose)" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ -r /etc/okrun/guest-tools.env ]]; then
  # shellcheck disable=SC1091
  source /etc/okrun/guest-tools.env
fi
OKRUN_LOG_DIR="${OKRUN_LOG_DIR:-/mnt/okrun/okrun-guest-logs}"
OKRUN_LOG_PROBE_TIMEOUT="${OKRUN_LOG_PROBE_TIMEOUT:-8}"
KERNEL_ALERT_PATTERN='bug:|oops:|kernel panic|i/o error|blk_update_request|buffer i/o|ext4-fs error|ext4.*error|oom|out of memory|hung task|blocked for more than|soft lockup|hard lockup|rcu:.*stall|rcu_sched.*stall|rcu_preempt.*stall|segfault|unable to handle|internal error|call trace|tainted'
KERNEL_FAULT_CONTEXT_PATTERN='bug:|oops|kernel panic|unable to handle|internal error|undefined instruction|fixing recursive fault|segfault|tainted'

section() {
  printf '\n== %s ==\n' "$1"
}

run_probe() {
  local name="$1"
  shift

  printf '\n-- %s --\n' "$name"
  if [[ "$OKRUN_LOG_PROBE_TIMEOUT" =~ ^[0-9]+$ ]] && command -v timeout >/dev/null 2>&1; then
    timeout --kill-after=2s "$OKRUN_LOG_PROBE_TIMEOUT" "$@" 2>&1 || true
  else
    "$@" 2>&1 || true
  fi
}

section "Identity"
run_probe hostname hostname
run_probe hostnamectl hostnamectl
run_probe uname uname -a
[[ -r /proc/cmdline ]] && run_probe proc-cmdline cat /proc/cmdline
[[ -r /proc/sys/kernel/tainted ]] && run_probe kernel-tainted cat /proc/sys/kernel/tainted

section "Memory"
run_probe free free -h
[[ -r /proc/meminfo ]] && run_probe meminfo cat /proc/meminfo
[[ -r /proc/sys/vm/swappiness ]] && run_probe vm-swappiness cat /proc/sys/vm/swappiness
[[ -r /proc/sys/vm/overcommit_memory ]] && run_probe vm-overcommit-memory cat /proc/sys/vm/overcommit_memory
[[ -r /proc/sys/vm/overcommit_ratio ]] && run_probe vm-overcommit-ratio cat /proc/sys/vm/overcommit_ratio
[[ -r /proc/sys/vm/panic_on_oom ]] && run_probe vm-panic-on-oom cat /proc/sys/vm/panic_on_oom
[[ -r /proc/pressure/cpu ]] && run_probe pressure-cpu cat /proc/pressure/cpu
[[ -r /proc/pressure/io ]] && run_probe pressure-io cat /proc/pressure/io
[[ -r /proc/pressure/memory ]] && run_probe pressure-memory cat /proc/pressure/memory

section "Disk"
run_probe lsblk lsblk -f
run_probe df df -hT / /boot /boot/efi /mnt/okrun
run_probe findmnt-root findmnt -R /
run_probe findmnt-okrun findmnt -R /mnt/okrun
[[ -r /proc/mounts ]] && run_probe proc-mounts cat /proc/mounts
[[ -r /proc/partitions ]] && run_probe proc-partitions cat /proc/partitions

section "Network"
run_probe ip-addr ip -br addr
run_probe ip-route ip route

section "Sandbox Setup"
run_probe sandbox-user bash -c "id brain-sandbox; getent passwd brain-sandbox; stat -c '%A %U:%G %n' /home/brain-sandbox /home/brain-sandbox/apps /home/brain-sandbox/upload_images /home/brain-sandbox/skills /home/brain-sandbox/.local /var/www/brain-data 2>/dev/null || true"
run_probe setup-processes bash -c "ps -eo pid,ppid,stat,wchan:24,comm,args,%cpu,%mem 2>/dev/null | grep -Ei 'apt|dpkg|pip|npm|node|systemd-run|curl|setup-sandbox|brain-sandbox' | grep -v grep | head -100 || true"
run_probe package-versions bash -c "for command in node npm python3 pip3 curl git ffmpeg jq; do if command -v \"\$command\" >/dev/null 2>&1; then printf '%s: ' \"\$command\"; \"\$command\" --version 2>&1 | head -1; else printf '%s: missing\n' \"\$command\"; fi; done"
run_probe resolv-conf bash -c "ls -l /etc/resolv.conf /etc/resolv.conf.head /home/brain-sandbox/resolv.conf 2>/dev/null || true; sed -n '1,40p' /etc/resolv.conf 2>/dev/null || true; sed -n '1,40p' /home/brain-sandbox/resolv.conf 2>/dev/null || true"
[[ -r /etc/sudoers.d/brain-shell-sandbox ]] && run_probe sandbox-sudoers bash -c "stat -c '%A %U:%G %n' /etc/sudoers.d/brain-shell-sandbox; sed -n '1,30p' /etc/sudoers.d/brain-shell-sandbox"
if command -v systemctl >/dev/null 2>&1; then
  run_probe systemd-jobs systemctl list-jobs --no-pager
  run_probe systemd-run-units bash -c "systemctl list-units 'run-*.service' 'run-*.scope' --all --no-pager --plain 2>/dev/null | head -120 || true"
fi
if command -v iptables >/dev/null 2>&1; then
  run_probe iptables-sandbox bash -c "iptables -S OUTPUT 2>/dev/null | grep SANDBOX_OUT || true; iptables -S SANDBOX_OUT 2>/dev/null || true"
fi
if command -v ip6tables >/dev/null 2>&1; then
  run_probe ip6tables-output bash -c "ip6tables -S OUTPUT 2>/dev/null | head -120 || true"
fi
[[ -r /etc/cron.hourly/brain-sandbox-cleanup ]] && run_probe sandbox-cron-cleanup bash -c "stat -c '%A %U:%G %n' /etc/cron.hourly/brain-sandbox-cleanup; sed -n '1,120p' /etc/cron.hourly/brain-sandbox-cleanup"
[[ -r /var/log/apt/history.log ]] && run_probe apt-history-tail tail -120 /var/log/apt/history.log
[[ -r /var/log/dpkg.log ]] && run_probe dpkg-tail tail -120 /var/log/dpkg.log

section "Swap"
[[ -r /proc/swaps ]] && run_probe proc-swaps cat /proc/swaps
[[ -r /etc/fstab ]] && run_probe fstab-swap bash -c "grep -E '^[^#].*[[:space:]]swap[[:space:]]' /etc/fstab || true"
run_probe swapon swapon --show
run_probe vmstat vmstat 1 2

section "Processes"
run_probe ps-top bash -c 'ps -eo pid,ppid,stat,wchan:24,comm,%cpu,%mem --sort=-%cpu 2>/dev/null | head -40'
run_probe ps-blocked bash -c "ps -eo pid,ppid,stat,wchan:24,comm,args 2>/dev/null | awk '\$3 ~ /D/ { print }' | head -80"

section "Systemd"
run_probe systemd-failed systemctl --failed --no-pager

section "Recent Okrun Health"
run_probe guest-health tail -300 "$OKRUN_LOG_DIR/guest-health.log"

section "Kernel Alerts"
run_probe kernel-alert bash -c "journalctl -k --since '60 minutes ago' --no-pager 2>/dev/null | grep -Ei '$KERNEL_ALERT_PATTERN' | tail -200 || true"
run_probe kernel-fault-context bash -c "if journalctl -k --since '60 minutes ago' --no-pager 2>/dev/null | grep -Eiq '$KERNEL_FAULT_CONTEXT_PATTERN'; then journalctl -k --since '60 minutes ago' --no-pager 2>/dev/null | tail -300; fi"

section "System Alerts"
run_probe system-alert bash -c "journalctl --since '60 minutes ago' --priority=warning..alert --no-pager 2>/dev/null | tail -200 || true"
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

okrun_virtiofs_device_available() {
  if [[ -n "$GUEST_ROOT" ]]; then
    return 0
  fi

  if command -v modprobe >/dev/null 2>&1; then
    modprobe virtiofs >/dev/null 2>&1 || true
  fi

  if find /sys/bus/virtio/drivers/virtio_fs -type f -name tag -exec grep -qx okrun {} \; -print -quit 2>/dev/null | grep -q .; then
    return 0
  fi

  if grep -Rqs '^okrun$' /sys/bus/virtio/drivers/virtio_fs 2>/dev/null; then
    return 0
  fi

  return 1
}

print_missing_log_share_instructions() {
  cat >&2 <<EOF
Missing writable Okrun guest log share: $LOG_DIR

Okrun now creates and mounts this share automatically when the VM starts. On the
Mac, use an updated Okrun build, fully stop the VM, and start it again. The host
will create this project directory if needed:

  <project>/vm/guest-logs

After the VM restarts, rerun:

  ./scripts/install-guest-tools.sh <hostname-or-ip>

EOF
}

require_log_share() {
  local guest_log_dir
  guest_log_dir="$(guest_path "$LOG_DIR")"

  if [[ -z "$GUEST_ROOT" ]]; then
    if command -v findmnt >/dev/null 2>&1; then
      if [[ "$(findmnt -no FSTYPE /mnt/okrun 2>/dev/null || true)" != "virtiofs" ]]; then
        print_missing_log_share_instructions
        exit 78
      fi
    elif ! awk '$2 == "/mnt/okrun" && $3 == "virtiofs" { found = 1 } END { exit found ? 0 : 1 }' /proc/mounts 2>/dev/null; then
      print_missing_log_share_instructions
      exit 78
    fi
  fi

  if [[ -d "$guest_log_dir" && -w "$guest_log_dir" ]]; then
    return 0
  fi

  print_missing_log_share_instructions
  exit 78
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
    managed_virtiofs_mount_config="1"
  fi
fi

detect_private_iface() {
  if [[ "$PRIVATE_IFACE" != "auto" ]]; then
    if [[ -n "$GUEST_ROOT" ]] || ip link show dev "$PRIVATE_IFACE" >/dev/null 2>&1; then
      printf '%s\n' "$PRIVATE_IFACE"
    fi
    return
  fi

  local managed_config
  managed_config="$(guest_path /etc/systemd/network/20-okrun-private.network)"
  if [[ -f "$managed_config" ]]; then
    local managed_iface
    managed_iface="$(awk -F= '$1 == "Name" && $2 != "" { print $2; exit }' "$managed_config")"
    if [[ -n "$managed_iface" ]]; then
      printf '%s\n' "$managed_iface"
      return
    fi
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

  return 1
}

private_managed_network_config() {
  guest_path /etc/systemd/network/20-okrun-private.network
}

private_managed_network_config_exists() {
  local config_file
  config_file="$(private_managed_network_config)"
  [[ -f "$config_file" ]] && grep -qs '^# Managed by Okrun guest tools\.$' "$config_file"
}

private_managed_network_config_is_dhcp() {
  local config_file
  config_file="$(private_managed_network_config)"
  [[ -f "$config_file" ]] && grep -qs '^DHCP=ipv4$' "$config_file"
}

install_private_network_dhcp_config() {
  local private_iface="$1"
  install -d -m 0755 "$(guest_path /etc/systemd/network)"
  cat >"$(private_managed_network_config)" <<EOF
# Managed by Okrun guest tools.
[Match]
Name=$private_iface

[Network]
DHCP=ipv4
LinkLocalAddressing=no
IPv6AcceptRA=no

[DHCPv4]
UseDNS=false
UseRoutes=false
EOF
}

installed_private_network_config="0"
if [[ -n "$PRIVATE_IP_CIDR" ]]; then
  if [[ "$PRIVATE_DHCP_EXPLICIT" == "1" ]]; then
    echo "--private-ip was supplied; skipping DHCP private network config."
  fi
  private_iface="$(detect_private_iface)"
  if [[ -z "$private_iface" ]]; then
    echo "No Okrun private network interface detected; leaving network config unchanged. Enable privateNetwork for this VM, reboot it, then rerun with --private-ip."
  elif private_network_config_exists "$private_iface" "$PRIVATE_IP_CIDR"; then
    echo "Okrun private network config already exists; leaving it unchanged."
  else
    install -d -m 0755 "$(guest_path /etc/systemd/network)"
    cat >"$(guest_path /etc/systemd/network/20-okrun-private.network)" <<EOF
# Managed by Okrun guest tools.
[Match]
Name=$private_iface

[Network]
Address=$PRIVATE_IP_CIDR
EOF
    installed_private_network_config="1"
    echo "Okrun private network config set to $PRIVATE_IP_CIDR on $private_iface."
  fi
else
  private_iface="$(detect_private_iface)"
  if [[ -z "$private_iface" ]]; then
    echo "No Okrun private network interface detected; leaving network config unchanged. Enable privateNetwork for this VM, reboot it, then rerun this installer."
  elif private_managed_network_config_is_dhcp; then
    echo "Okrun DHCP private network config already exists; leaving it unchanged."
  elif private_managed_network_config_exists && [[ "$PRIVATE_DHCP_EXPLICIT" != "1" ]]; then
    echo "Okrun static private network config already exists; leaving it unchanged. Rerun with --private-dhcp to replace it with DHCP."
  else
    install_private_network_dhcp_config "$private_iface"
    installed_private_network_config="1"
    echo "Okrun private network DHCP config installed on $private_iface."
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
  require_log_share
  echo "Installed files into test root: $GUEST_ROOT"
elif command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload

  if [[ "$ENABLE_VIRTIOFS_MOUNT" == "1" && -f /etc/systemd/system/mnt-okrun.mount ]]; then
    systemctl enable mnt-okrun.mount
    if okrun_virtiofs_device_available; then
      if ! systemctl start mnt-okrun.mount; then
        echo "Warning: could not start /mnt/okrun mount. Run 'journalctl -xeu mnt-okrun.mount' inside the guest for details." >&2
      fi
    elif systemctl start mnt-okrun.mount; then
      :
    elif [[ "$managed_virtiofs_mount_config" == "1" ]]; then
      systemctl disable mnt-okrun.mount >/dev/null 2>&1 || true
      echo "Okrun VirtioFS device is not present; installed mnt-okrun.mount but left it disabled. Start this VM with an updated Okrun build, then rerun this installer."
    else
      echo "Okrun VirtioFS device is not present; leaving existing mount config unchanged."
    fi
  fi

  require_log_share
  systemctl enable okrun-guest-health.service
  systemctl restart okrun-guest-health.service

  if [[ "$installed_private_network_config" == "1" ]]; then
    systemctl enable systemd-networkd
    systemctl restart systemd-networkd
  fi
else
  require_log_share
  echo "systemctl not found; installed files but did not enable services." >&2
fi

echo "Okrun guest tools installed."
echo "Run: sudo okrun-guest-diagnose"
