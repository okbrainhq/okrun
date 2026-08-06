#!/usr/bin/env bash
set -euo pipefail

section() {
  printf '\n== %s ==\n' "$1"
}

section "Okrun processes"
pgrep -fl "OkrunVM|com.apple.Virtualization.VirtualMachine|com.apple.Virtualization.EventTap" || true

section "Private network peer sockets"
socket_root="${OKRUN_PRIVATE_NETWORK_SOCKET_ROOT:-/tmp/okrun-vnet}"
if [[ -d "$socket_root" ]]; then
  active_peer_paths="$(netstat -anv -f unix 2>/dev/null | awk -v root="$socket_root/" 'index($0, root) { print $NF }' || true)"
  total_peers=0
  active_peers=0
  stale_peers=0
  while IFS= read -r peer; do
    [[ -n "$peer" ]] || continue
    total_peers=$((total_peers + 1))
    if printf '%s\n' "$active_peer_paths" | grep -Fqx "$peer"; then
      active_peers=$((active_peers + 1))
      printf 'ACTIVE %s\n' "$peer"
    else
      stale_peers=$((stale_peers + 1))
      printf 'STALE  %s\n' "$peer"
    fi
  done < <(find "$socket_root" -type s -name '*.sock' -print 2>/dev/null | sort)
  printf 'Summary total=%s active=%s stale=%s\n' "$total_peers" "$active_peers" "$stale_peers"

  printf '\nActive socket counters:\n'
  netstat -anv -f unix 2>/dev/null | awk -v root="$socket_root/" 'index($0, root)' || true
else
  printf 'No private network socket directory at %s.\n' "$socket_root"
fi

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
      df -h "$project" || true
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
