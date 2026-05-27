#!/usr/bin/env bash
set -euo pipefail

GUEST_OS="$(uname -s)"
DEFAULT_LOG_DIR="/mnt/okrun/okrun-guest-logs"
if [[ "$GUEST_OS" == "Darwin" ]]; then
  DEFAULT_LOG_DIR="/Volumes/okrun/okrun-guest-logs"
fi
LOG_DIR="${OKRUN_LOG_DIR:-$DEFAULT_LOG_DIR}"
LOG_FILE="$LOG_DIR/guest-health.log"
LOG_MAX_BYTES="${OKRUN_LOG_MAX_BYTES:-10485760}"
LOG_KEEP="${OKRUN_LOG_KEEP:-5}"
LOG_PROBE_TIMEOUT="${OKRUN_LOG_PROBE_TIMEOUT:-8}"
KERNEL_ALERT_PATTERN='bug:|oops:|kernel panic|i/o error|blk_update_request|buffer i/o|ext4-fs error|ext4.*error|oom|out of memory|hung task|blocked for more than|soft lockup|hard lockup|rcu:.*stall|rcu_sched.*stall|rcu_preempt.*stall|segfault|unable to handle|internal error|call trace|tainted'
KERNEL_FAULT_CONTEXT_PATTERN='bug:|oops|kernel panic|unable to handle|internal error|undefined instruction|fixing recursive fault|segfault|tainted'

mkdir -p "$LOG_DIR"

timestamp() {
  date -Is 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z'
}

guest_uptime() {
  if [[ -r /proc/uptime ]]; then
    cut -d' ' -f1 /proc/uptime
    return
  fi

  if [[ "$GUEST_OS" == "Darwin" ]] && command -v sysctl >/dev/null 2>&1 && command -v date >/dev/null 2>&1; then
    local boot_sec now
    boot_sec="$(sysctl -n kern.boottime 2>/dev/null | sed -n 's/.*sec = \([0-9][0-9]*\).*/\1/p')"
    now="$(date +%s 2>/dev/null || true)"
    if [[ -n "$boot_sec" && -n "$now" ]]; then
      printf '%s\n' "$((now - boot_sec))"
      return
    fi
  fi

  printf 'unknown\n'
}

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
  printf '%s %s\n' "$(timestamp)" "$message" | tee -a "$LOG_FILE"
}

emit_file_line() {
  local prefix="$1"
  local file="$2"

  [[ -r "$file" ]] || return 0
  while IFS= read -r line; do
    emit "$prefix $line"
  done <"$file"
}

run_probe() {
  local name="$1"
  shift

  local output status
  local -a timeout_cmd
  emit "probe-start name=$name timeout=${LOG_PROBE_TIMEOUT}s command=$*"

  set +e
  if [[ "$LOG_PROBE_TIMEOUT" =~ ^[0-9]+$ ]] && command -v timeout >/dev/null 2>&1; then
    timeout_cmd=(timeout --kill-after=2s "$LOG_PROBE_TIMEOUT")
    output="$("${timeout_cmd[@]}" "$@" 2>&1)"
    status=$?
  else
    output="$("$@" 2>&1)"
    status=$?
  fi
  set -e

  if [[ -n "$output" ]]; then
    while IFS= read -r line; do
      emit "$name $line"
    done <<<"$output"
  fi

  case "$status" in
    124|137)
      emit "probe-timeout name=$name status=$status"
      ;;
    0)
      ;;
    *)
      emit "probe-error name=$name status=$status"
      ;;
  esac

  emit "probe-end name=$name status=$status"
}

emit_proc_snapshot() {
  emit_file_line "proc-loadavg" /proc/loadavg
  emit_file_line "proc-tainted" /proc/sys/kernel/tainted
  emit_file_line "proc-cmdline" /proc/cmdline
  emit_file_line "proc-swaps" /proc/swaps
  emit_file_line "vm-swappiness" /proc/sys/vm/swappiness
  emit_file_line "vm-overcommit-memory" /proc/sys/vm/overcommit_memory
  emit_file_line "vm-overcommit-ratio" /proc/sys/vm/overcommit_ratio
  emit_file_line "vm-panic-on-oom" /proc/sys/vm/panic_on_oom
  emit_file_line "pressure-cpu" /proc/pressure/cpu
  emit_file_line "pressure-io" /proc/pressure/io
  emit_file_line "pressure-memory" /proc/pressure/memory
}

emit_kernel_alerts() {
  command -v journalctl >/dev/null 2>&1 || return 0
  run_probe "kernel-alert" bash -c \
    "journalctl -k --since '10 minutes ago' --no-pager 2>/dev/null | grep -Ei '$KERNEL_ALERT_PATTERN' | tail -80 || true"
}

emit_system_alerts() {
  command -v journalctl >/dev/null 2>&1 || return 0
  run_probe "system-alert" bash -c \
    "journalctl --since '10 minutes ago' --priority=warning..alert --no-pager 2>/dev/null | tail -80 || true"
}

emit_kernel_fault_context() {
  command -v journalctl >/dev/null 2>&1 || return 0
  run_probe "kernel-fault-context" bash -c \
    "if journalctl -k --since '10 minutes ago' --no-pager 2>/dev/null | grep -Eiq '$KERNEL_FAULT_CONTEXT_PATTERN'; then journalctl -k --since '10 minutes ago' --no-pager 2>/dev/null | tail -240; fi"
}

emit_sandbox_setup_snapshot() {
  if id brain-sandbox >/dev/null 2>&1; then
    run_probe "sandbox-user" bash -c \
      "id brain-sandbox; getent passwd brain-sandbox; stat -c '%A %U:%G %n' /home/brain-sandbox /home/brain-sandbox/apps /home/brain-sandbox/skills /var/www/brain-data 2>/dev/null || true"

    run_probe "setup-processes" bash -c \
      "ps -eo pid,ppid,stat,wchan:24,comm,args,%cpu,%mem 2>/dev/null | grep -Ei 'apt|dpkg|pip|npm|node|systemd-run|curl|setup-sandbox|brain-sandbox' | grep -v grep | head -80 || true"

    if command -v systemctl >/dev/null 2>&1; then
      run_probe "systemd-jobs" systemctl list-jobs --no-pager
      run_probe "systemd-run-units" bash -c \
        "systemctl list-units 'run-*.service' 'run-*.scope' --all --no-pager --plain 2>/dev/null | head -80 || true"
    fi

    if command -v iptables >/dev/null 2>&1; then
      run_probe "iptables-sandbox" bash -c \
        "iptables -S OUTPUT 2>/dev/null | grep SANDBOX_OUT || true; iptables -S SANDBOX_OUT 2>/dev/null || true"
    fi

    if command -v ip6tables >/dev/null 2>&1; then
      run_probe "ip6tables-output" bash -c \
        "ip6tables -S OUTPUT 2>/dev/null | head -80 || true"
    fi

    [[ -r /etc/sudoers.d/brain-shell-sandbox ]] &&
      run_probe "sandbox-sudoers" bash -c \
        "stat -c '%A %U:%G %n' /etc/sudoers.d/brain-shell-sandbox; sed -n '1,20p' /etc/sudoers.d/brain-shell-sandbox"

    run_probe "resolv-conf" bash -c \
      "ls -l /etc/resolv.conf /etc/resolv.conf.head /home/brain-sandbox/resolv.conf 2>/dev/null || true; sed -n '1,20p' /etc/resolv.conf 2>/dev/null || true; sed -n '1,20p' /home/brain-sandbox/resolv.conf 2>/dev/null || true"
  fi
}

emit_macos_snapshot() {
  if command -v sw_vers >/dev/null 2>&1; then
    run_probe "sw-vers" sw_vers
  fi

  if command -v sysctl >/dev/null 2>&1; then
    run_probe "sysctl" sysctl hw.memsize hw.ncpu kern.boottime kern.osrelease kern.osproductversion
  fi

  if command -v uptime >/dev/null 2>&1; then
    run_probe "uptime" uptime
  fi

  if command -v df >/dev/null 2>&1; then
    run_probe "df" df -h / /Volumes/okrun
  fi

  if command -v mount >/dev/null 2>&1; then
    run_probe "mount-okrun" bash -c "mount | grep ' on /Volumes/okrun ' || true"
  fi

  if command -v ifconfig >/dev/null 2>&1; then
    run_probe "ifconfig" ifconfig
  fi

  if command -v netstat >/dev/null 2>&1; then
    run_probe "routes" netstat -rn
  fi

  if command -v ps >/dev/null 2>&1; then
    run_probe "ps-top" bash -c "ps ax -o pid,ppid,state,comm,%cpu,%mem | head -30"
  fi
}

while true; do
  emit "health-start hostname=$(hostname) kernel=$(uname -r) uptime=$(guest_uptime)"

  if [[ "$GUEST_OS" == "Darwin" ]]; then
    emit_macos_snapshot
    emit "health-end"
    [[ "${OKRUN_HEALTH_ONCE:-0}" == "1" ]] && exit 0
    sleep "${OKRUN_HEALTH_INTERVAL:-60}"
    continue
  fi

  emit_proc_snapshot
  emit_kernel_alerts
  emit_system_alerts
  emit_kernel_fault_context
  emit_sandbox_setup_snapshot

  if command -v uptime >/dev/null 2>&1; then
    run_probe "uptime" uptime
  fi

  if [[ -r /proc/meminfo ]]; then
    awk '/^(MemTotal|MemAvailable|SwapTotal|SwapFree|Dirty|Writeback):/ { printf "%s=%s%s ", $1, $2, $3 } END { print "" }' /proc/meminfo |
      while IFS= read -r line; do emit "meminfo $line"; done
  fi

  if command -v df >/dev/null 2>&1; then
    run_probe "df" df -hT / /boot /boot/efi /mnt/okrun
  fi

  if command -v findmnt >/dev/null 2>&1; then
    run_probe "findmnt-root" findmnt -R /
    run_probe "findmnt-okrun" findmnt -R /mnt/okrun
  fi

  if command -v lsblk >/dev/null 2>&1; then
    run_probe "lsblk" lsblk -f
  fi

  if command -v ip >/dev/null 2>&1; then
    run_probe "ip-addr" ip -br addr
    run_probe "ip-route" ip route
  fi

  if command -v ps >/dev/null 2>&1; then
    run_probe "ps-top" bash -c \
      "ps -eo pid,ppid,stat,wchan:24,comm,%cpu,%mem --sort=-%cpu 2>/dev/null | head -30"
    run_probe "ps-blocked" bash -c \
      "ps -eo pid,ppid,stat,wchan:24,comm,args 2>/dev/null | awk '\$3 ~ /D/ { print }' | head -50"
  fi

  if command -v vmstat >/dev/null 2>&1; then
    run_probe "vmstat" vmstat 1 2
  fi

  if [[ -r /etc/fstab ]]; then
    run_probe "fstab-swap" bash -c "grep -E '^[^#].*[[:space:]]swap[[:space:]]' /etc/fstab || true"
  fi

  if [[ -r /proc/swaps ]]; then
    emit_file_line "proc-swaps" /proc/swaps
  fi

  if command -v swapon >/dev/null 2>&1; then
    run_probe "swapon" swapon --show
  fi

  if command -v systemctl >/dev/null 2>&1; then
    run_probe "systemd-failed" systemctl --failed --no-pager
  fi

  emit_kernel_alerts
  emit_system_alerts
  emit_kernel_fault_context

  emit "health-end"
  [[ "${OKRUN_HEALTH_ONCE:-0}" == "1" ]] && exit 0
  sleep "${OKRUN_HEALTH_INTERVAL:-60}"
done
