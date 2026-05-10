#!/usr/bin/env bash
set -euo pipefail

LOG_DIR="${OKRUN_LOG_DIR:-/mnt/okrun/okrun-guest-logs}"
LOG_FILE="$LOG_DIR/guest-health.log"
LOG_MAX_BYTES="${OKRUN_LOG_MAX_BYTES:-10485760}"
LOG_KEEP="${OKRUN_LOG_KEEP:-5}"

mkdir -p "$LOG_DIR"

file_size() {
  local file="$1"

  if stat -c '%s' "$file" >/dev/null 2>&1; then
    stat -c '%s' "$file"
  else
    wc -c <"$file" | tr -d '[:space:]'
  fi
}

rotate_log_if_needed() {
  [[ "$LOG_MAX_BYTES" =~ ^[0-9]+$ && "$LOG_KEEP" =~ ^[0-9]+$ ]] || return 0
  [[ "$LOG_MAX_BYTES" -gt 0 && "$LOG_KEEP" -gt 0 ]] || return 0
  [[ -f "$LOG_FILE" ]] || return 0
  [[ "$(file_size "$LOG_FILE")" -ge "$LOG_MAX_BYTES" ]] || return 0

  local i previous next
  for ((i = LOG_KEEP - 1; i >= 1; i--)); do
    previous="$LOG_FILE.$i"
    next="$LOG_FILE.$((i + 1))"
    [[ -e "$previous" ]] && mv -f "$previous" "$next"
  done

  mv -f "$LOG_FILE" "$LOG_FILE.1"
}

emit() {
  local message="$1"
  rotate_log_if_needed
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
    { df -hT / /boot /boot/efi /mnt/okrun 2>/dev/null || true; } |
      sed 's/^/df /' |
      while IFS= read -r line; do emit "$line"; done
  fi

  if command -v findmnt >/dev/null 2>&1; then
    { findmnt -R / /mnt/okrun 2>/dev/null || true; } |
      sed 's/^/findmnt /' |
      while IFS= read -r line; do emit "$line"; done
  fi

  if command -v lsblk >/dev/null 2>&1; then
    { lsblk -f 2>/dev/null || true; } |
      sed 's/^/lsblk /' |
      while IFS= read -r line; do emit "$line"; done
  fi

  if command -v ip >/dev/null 2>&1; then
    { ip -br addr 2>/dev/null || true; } |
      sed 's/^/ip /' |
      while IFS= read -r line; do emit "$line"; done
  fi

  if command -v swapon >/dev/null 2>&1; then
    { swapon --show 2>/dev/null || true; } |
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
  [[ "${OKRUN_HEALTH_ONCE:-0}" == "1" ]] && exit 0
  sleep "${OKRUN_HEALTH_INTERVAL:-60}"
done
