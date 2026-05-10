#!/usr/bin/env bash
set -euo pipefail

section() {
  printf '\n== %s ==\n' "$1"
}

section "Okrun processes"
pgrep -fl "OkrunVM|com.apple.Virtualization.VirtualMachine|com.apple.Virtualization.EventTap" || true

section "VM service resource use"
vm_pids="$(pgrep -f "com.apple.Virtualization.VirtualMachine" || true)"
if [[ -n "$vm_pids" ]]; then
  pid_list="$(printf '%s\n' "$vm_pids" | paste -sd, -)"
  ps -p "$pid_list" -o pid,ppid,etime,pcpu,pmem,rss,state,command || true
else
  printf 'No running Virtualization VM services found.\n'
fi

section "VM service disk mappings"
if [[ -n "$vm_pids" ]]; then
  for pid in $vm_pids; do
    printf '\nPID %s\n' "$pid"
    lsof -p "$pid" 2>/dev/null | awk '/\/vm\/.*(raw|variables)$/ { print }' || true
  done
fi

section "Host memory pressure"
memory_pressure || true

section "VM disk files"
if [[ -f "$HOME/.okrun" ]]; then
  awk -F'"' '/\\\/Users\\\// { for (i = 2; i <= NF; i += 2) if ($i ~ /^\\\/Users\\\//) print $i }' "$HOME/.okrun" |
    sed 's#\\/#/#g' |
    sort -u |
    while IFS= read -r project; do
      [[ -d "$project/vm" ]] || continue
      printf '\nProject %s\n' "$project"
      ls -lh "$project/vm"/*.raw 2>/dev/null || true
      for disk in "$project/vm"/*.raw; do
        [[ -e "$disk" ]] || continue
        stat -f '%N size=%z blocks=%b blockSize=%k mtime=%Sm' "$disk" || true
        gpt show "$disk" 2>/dev/null || true
      done
    done
else
  printf 'No ~/.okrun registry found.\n'
fi

section "Recent Okrun logs"
log show --last 30m --style compact --predicate 'subsystem == "local.okrun.vm"' || true
