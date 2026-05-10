#!/usr/bin/env bash
set -euo pipefail

LOG_DIR="/var/log/okrun"
LOG_FILE="$LOG_DIR/guest-health.log"

mkdir -p "$LOG_DIR"

emit() {
  local message="$1"
  printf '%s %s\n' "$(date -Is)" "$message" | tee -a "$LOG_FILE"
}

while true; do
  emit "health-start hostname=$(hostname) kernel=$(uname -r) uptime=$(cut -d' ' -f1 /proc/uptime)"

  if command -v uptime >/dev/null 2>&1; then
    emit "uptime $(uptime)"
  fi

  if [[ -r /proc/meminfo ]]; then
    awk '/^(MemTotal|MemAvailable|SwapTotal|SwapFree|Dirty|Writeback):/ { printf "%s=%s%s ", $1, $2, $3 } END { print "" }' /proc/meminfo |
      while IFS= read -r line; do emit "meminfo $line"; done
  fi

  if command -v df >/dev/null 2>&1; then
    df -hT / /boot /boot/efi /mnt/okrun 2>/dev/null |
      sed 's/^/df /' |
      while IFS= read -r line; do emit "$line"; done
  fi

  if command -v findmnt >/dev/null 2>&1; then
    findmnt -R / /mnt/okrun 2>/dev/null |
      sed 's/^/findmnt /' |
      while IFS= read -r line; do emit "$line"; done
  fi

  if command -v lsblk >/dev/null 2>&1; then
    lsblk -f 2>/dev/null |
      sed 's/^/lsblk /' |
      while IFS= read -r line; do emit "$line"; done
  fi

  if command -v ip >/dev/null 2>&1; then
    ip -br addr 2>/dev/null |
      sed 's/^/ip /' |
      while IFS= read -r line; do emit "$line"; done
  fi

  if command -v swapon >/dev/null 2>&1; then
    swapon --show 2>/dev/null |
      sed 's/^/swapon /' |
      while IFS= read -r line; do emit "$line"; done
  fi

  if command -v journalctl >/dev/null 2>&1; then
    journalctl -k --since '2 minutes ago' --no-pager 2>/dev/null |
      grep -Ei 'bug:|i/o error|blk_update_request|buffer i/o|ext4-fs error|oom|out of memory|hung task|soft lockup|hard lockup' |
      tail -50 |
      sed 's/^/kernel-alert /' |
      while IFS= read -r line; do emit "$line"; done || true
  fi

  emit "health-end"
  sleep "${OKRUN_HEALTH_INTERVAL:-60}"
done
