#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE_DIR="$ROOT/.e2e/alpine-aarch64"
BASE_URL="https://dl-cdn.alpinelinux.org/alpine/v3.18/releases/aarch64/netboot"
KERNEL="$FIXTURE_DIR/v3.18-vmlinuz-virt"
INITRAMFS="$FIXTURE_DIR/v3.18-initramfs-virt"
BOOT_IMAGE="$FIXTURE_DIR/v3.18-Image"
E2E_INITRAMFS="$FIXTURE_DIR/initramfs-okrun-e2e"
E2E_SHARED_INITRAMFS="$FIXTURE_DIR/initramfs-okrun-e2e-shared"
E2E_SAVE_RESTORE_INITRAMFS="$FIXTURE_DIR/initramfs-okrun-e2e-save-restore"
E2E_PRIVATE_NETWORK_SERVER_INITRAMFS="$FIXTURE_DIR/initramfs-okrun-e2e-private-network-server"
E2E_PRIVATE_NETWORK_CLIENT_INITRAMFS="$FIXTURE_DIR/initramfs-okrun-e2e-private-network-client"
E2E_PRIVATE_NETWORK_RECONNECT_CLIENT_INITRAMFS="$FIXTURE_DIR/initramfs-okrun-e2e-private-network-reconnect-client"
E2E_PRIVATE_NETWORK_DHCP_INITRAMFS="$FIXTURE_DIR/initramfs-okrun-e2e-private-network-dhcp"
E2E_PRIVATE_NETWORK_DHCP_SERVER_INITRAMFS="$FIXTURE_DIR/initramfs-okrun-e2e-private-network-dhcp-server"
E2E_PRIVATE_NETWORK_DHCP_CLIENT_INITRAMFS="$FIXTURE_DIR/initramfs-okrun-e2e-private-network-dhcp-client"

mkdir -p "$FIXTURE_DIR"

if [[ ! -f "$KERNEL" ]]; then
  curl -L --fail --output "$KERNEL" "$BASE_URL/vmlinuz-virt"
fi

if [[ ! -f "$INITRAMFS" ]]; then
  curl -L --fail --output "$INITRAMFS" "$BASE_URL/initramfs-virt"
fi

gzip -dc "$KERNEL" > "$BOOT_IMAGE"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/okrun-e2e-initramfs.XXXXXX")"
cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

gzip -dc "$INITRAMFS" | (cd "$WORK_DIR" && cpio -id --quiet)

cat > "$WORK_DIR/init" <<'EOF'
#!/bin/sh
/bin/busybox mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
/bin/busybox mount -t proc proc /proc 2>/dev/null || true
/bin/busybox mount -t sysfs sysfs /sys 2>/dev/null || true
echo OKRUN_E2E_BOOTED >/dev/console
echo OKRUN_E2E_BOOTED >/dev/hvc0 2>/dev/null || true
/bin/busybox poweroff -f 2>/dev/null || /bin/busybox reboot -f 2>/dev/null || true
while true; do :; done
EOF
chmod 0755 "$WORK_DIR/init"

(cd "$WORK_DIR" && find . | cpio -o -H newc --quiet | gzip -9 > "$E2E_INITRAMFS")

cat > "$WORK_DIR/init" <<'EOF'
#!/bin/sh
/bin/busybox mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
/bin/busybox mount -t proc proc /proc 2>/dev/null || true
/bin/busybox mount -t sysfs sysfs /sys 2>/dev/null || true
/bin/busybox mkdir -p /mnt/okrun
/sbin/modprobe virtiofs 2>/dev/null || true

if /bin/busybox mount -t virtiofs okrun /mnt/okrun 2>/dev/console; then
  if [ -d /mnt/okrun/okrun-guest-logs ]; then
    echo OKRUN_E2E_GUEST_LOGS_SHARE_PASSED >/dev/console
    echo OKRUN_E2E_GUEST_LOGS_SHARE_PASSED >/dev/hvc0 2>/dev/null || true
  fi

  if [ "$(/bin/busybox cat /mnt/okrun/e2e/host-to-guest.txt 2>/dev/null)" = "hello-from-host" ]; then
    echo hello-from-guest >/mnt/okrun/e2e/guest-to-host.txt
    echo OKRUN_E2E_SHARED_DIRS_PASSED >/dev/console
    echo OKRUN_E2E_SHARED_DIRS_PASSED >/dev/hvc0 2>/dev/null || true
  else
    echo OKRUN_E2E_SHARED_DIRS_FAILED_SENTINEL >/dev/console
    echo OKRUN_E2E_SHARED_DIRS_FAILED_SENTINEL >/dev/hvc0 2>/dev/null || true
  fi
else
  echo OKRUN_E2E_SHARED_DIRS_FAILED_MOUNT >/dev/console
  echo OKRUN_E2E_SHARED_DIRS_FAILED_MOUNT >/dev/hvc0 2>/dev/null || true
fi

/bin/busybox poweroff -f 2>/dev/null || /bin/busybox reboot -f 2>/dev/null || true
while true; do :; done
EOF
chmod 0755 "$WORK_DIR/init"

(cd "$WORK_DIR" && find . | cpio -o -H newc --quiet | gzip -9 > "$E2E_SHARED_INITRAMFS")

cat > "$WORK_DIR/init" <<'EOF'
#!/bin/sh
/bin/busybox mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
/bin/busybox mount -t proc proc /proc 2>/dev/null || true
/bin/busybox mount -t sysfs sysfs /sys 2>/dev/null || true
echo OKRUN_E2E_SAVE_RESTORE_BOOTED >/dev/console
echo OKRUN_E2E_SAVE_RESTORE_BOOTED >/dev/hvc0 2>/dev/null || true
/bin/busybox sleep 3
echo OKRUN_E2E_SAVE_RESTORE_RESUMED >/dev/console
echo OKRUN_E2E_SAVE_RESTORE_RESUMED >/dev/hvc0 2>/dev/null || true
/bin/busybox poweroff -f 2>/dev/null || /bin/busybox reboot -f 2>/dev/null || true
while true; do :; done
EOF
chmod 0755 "$WORK_DIR/init"

(cd "$WORK_DIR" && find . | cpio -o -H newc --quiet | gzip -9 > "$E2E_SAVE_RESTORE_INITRAMFS")

cat > "$WORK_DIR/init" <<'EOF'
#!/bin/sh
/bin/busybox mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
/bin/busybox mount -t proc proc /proc 2>/dev/null || true
/bin/busybox mount -t sysfs sysfs /sys 2>/dev/null || true
/sbin/modprobe virtio_net 2>/dev/null || true

PRIVATE_IFACE=""
for attempt in 1 2 3 4 5; do
  for path in /sys/class/net/*; do
    iface="${path##*/}"
    [ "$iface" = "lo" ] && continue
    PRIVATE_IFACE="$iface"
  done
  [ -n "$PRIVATE_IFACE" ] && break
  /bin/busybox sleep 1
done

echo "OKRUN_E2E_PRIVATE_NETWORK_SERVER_IFACE=${PRIVATE_IFACE}" >/dev/console
echo "OKRUN_E2E_PRIVATE_NETWORK_SERVER_IFACE=${PRIVATE_IFACE}" >/dev/hvc0 2>/dev/null || true

if [ -z "$PRIVATE_IFACE" ]; then
  echo OKRUN_E2E_PRIVATE_NETWORK_SERVER_FAILED_NO_IFACE >/dev/console
  echo OKRUN_E2E_PRIVATE_NETWORK_SERVER_FAILED_NO_IFACE >/dev/hvc0 2>/dev/null || true
  /bin/busybox poweroff -f 2>/dev/null || /bin/busybox reboot -f 2>/dev/null || true
  while true; do :; done
fi

/bin/busybox ip link set "$PRIVATE_IFACE" up
/bin/busybox ip addr add 10.77.0.2/24 dev "$PRIVATE_IFACE"
echo OKRUN_E2E_PRIVATE_NETWORK_SERVER_READY >/dev/console
echo OKRUN_E2E_PRIVATE_NETWORK_SERVER_READY >/dev/hvc0 2>/dev/null || true
/bin/busybox sleep 120
/bin/busybox poweroff -f 2>/dev/null || /bin/busybox reboot -f 2>/dev/null || true
while true; do :; done
EOF
chmod 0755 "$WORK_DIR/init"

(cd "$WORK_DIR" && find . | cpio -o -H newc --quiet | gzip -9 > "$E2E_PRIVATE_NETWORK_SERVER_INITRAMFS")

cat > "$WORK_DIR/init" <<'EOF'
#!/bin/sh
/bin/busybox mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
/bin/busybox mount -t proc proc /proc 2>/dev/null || true
/bin/busybox mount -t sysfs sysfs /sys 2>/dev/null || true
/sbin/modprobe virtio_net 2>/dev/null || true

PRIVATE_IFACE=""
for attempt in 1 2 3 4 5; do
  for path in /sys/class/net/*; do
    iface="${path##*/}"
    [ "$iface" = "lo" ] && continue
    PRIVATE_IFACE="$iface"
  done
  [ -n "$PRIVATE_IFACE" ] && break
  /bin/busybox sleep 1
done

echo "OKRUN_E2E_PRIVATE_NETWORK_CLIENT_IFACE=${PRIVATE_IFACE}" >/dev/console
echo "OKRUN_E2E_PRIVATE_NETWORK_CLIENT_IFACE=${PRIVATE_IFACE}" >/dev/hvc0 2>/dev/null || true

if [ -z "$PRIVATE_IFACE" ]; then
  echo OKRUN_E2E_PRIVATE_NETWORK_CLIENT_FAILED_NO_IFACE >/dev/console
  echo OKRUN_E2E_PRIVATE_NETWORK_CLIENT_FAILED_NO_IFACE >/dev/hvc0 2>/dev/null || true
  /bin/busybox poweroff -f 2>/dev/null || /bin/busybox reboot -f 2>/dev/null || true
  while true; do :; done
fi

/bin/busybox ip link set "$PRIVATE_IFACE" up
/bin/busybox ip addr add 10.77.0.3/24 dev "$PRIVATE_IFACE"

for attempt in 1 2 3 4 5 6 7 8 9 10; do
  if /bin/busybox ping -c 1 -W 1 10.77.0.2 >/dev/console 2>&1; then
    echo OKRUN_E2E_PRIVATE_NETWORK_PASSED >/dev/console
    echo OKRUN_E2E_PRIVATE_NETWORK_PASSED >/dev/hvc0 2>/dev/null || true
    /bin/busybox poweroff -f 2>/dev/null || /bin/busybox reboot -f 2>/dev/null || true
    while true; do :; done
  fi
  /bin/busybox sleep 1
done

echo OKRUN_E2E_PRIVATE_NETWORK_FAILED >/dev/console
echo OKRUN_E2E_PRIVATE_NETWORK_FAILED >/dev/hvc0 2>/dev/null || true
/bin/busybox poweroff -f 2>/dev/null || /bin/busybox reboot -f 2>/dev/null || true
while true; do :; done
EOF
chmod 0755 "$WORK_DIR/init"

(cd "$WORK_DIR" && find . | cpio -o -H newc --quiet | gzip -9 > "$E2E_PRIVATE_NETWORK_CLIENT_INITRAMFS")

cat > "$WORK_DIR/init" <<'EOF'
#!/bin/sh
/bin/busybox mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
/bin/busybox mount -t proc proc /proc 2>/dev/null || true
/bin/busybox mount -t sysfs sysfs /sys 2>/dev/null || true
/sbin/modprobe virtio_net 2>/dev/null || true

emit_marker() {
  echo "$1" >/dev/console
  echo "$1" >/dev/hvc0 2>/dev/null || true
}

ping_server() {
  /bin/busybox ping -c 1 -W 1 10.77.0.2 >/dev/console 2>&1
}

PRIVATE_IFACE=""
for attempt in 1 2 3 4 5; do
  for path in /sys/class/net/*; do
    iface="${path##*/}"
    [ "$iface" = "lo" ] && continue
    PRIVATE_IFACE="$iface"
  done
  [ -n "$PRIVATE_IFACE" ] && break
  /bin/busybox sleep 1
done

echo "OKRUN_E2E_PRIVATE_NETWORK_RECONNECT_CLIENT_IFACE=${PRIVATE_IFACE}" >/dev/console
echo "OKRUN_E2E_PRIVATE_NETWORK_RECONNECT_CLIENT_IFACE=${PRIVATE_IFACE}" >/dev/hvc0 2>/dev/null || true

if [ -z "$PRIVATE_IFACE" ]; then
  emit_marker OKRUN_E2E_PRIVATE_NETWORK_RECONNECT_FAILED_NO_IFACE
  /bin/busybox poweroff -f 2>/dev/null || /bin/busybox reboot -f 2>/dev/null || true
  while true; do :; done
fi

/bin/busybox ip link set "$PRIVATE_IFACE" up
/bin/busybox ip addr add 10.77.0.3/24 dev "$PRIVATE_IFACE"

initial_ok=0
for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  if ping_server; then
    initial_ok=1
    emit_marker OKRUN_E2E_PRIVATE_NETWORK_INITIAL_PASSED
    break
  fi
  /bin/busybox sleep 1
done

if [ "$initial_ok" != "1" ]; then
  emit_marker OKRUN_E2E_PRIVATE_NETWORK_RECONNECT_FAILED_INITIAL
  /bin/busybox poweroff -f 2>/dev/null || /bin/busybox reboot -f 2>/dev/null || true
  while true; do :; done
fi

disconnected=0
for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
  if ! ping_server; then
    disconnected=1
    emit_marker OKRUN_E2E_PRIVATE_NETWORK_DISCONNECTED
    break
  fi
  /bin/busybox sleep 1
done

if [ "$disconnected" != "1" ]; then
  emit_marker OKRUN_E2E_PRIVATE_NETWORK_RECONNECT_FAILED_NO_DISCONNECT
  /bin/busybox poweroff -f 2>/dev/null || /bin/busybox reboot -f 2>/dev/null || true
  while true; do :; done
fi

for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 45; do
  if ping_server; then
    emit_marker OKRUN_E2E_PRIVATE_NETWORK_RECONNECT_PASSED
    /bin/busybox poweroff -f 2>/dev/null || /bin/busybox reboot -f 2>/dev/null || true
    while true; do :; done
  fi
  /bin/busybox sleep 1
done

emit_marker OKRUN_E2E_PRIVATE_NETWORK_RECONNECT_FAILED_FINAL
/bin/busybox poweroff -f 2>/dev/null || /bin/busybox reboot -f 2>/dev/null || true
while true; do :; done
EOF
chmod 0755 "$WORK_DIR/init"

(cd "$WORK_DIR" && find . | cpio -o -H newc --quiet | gzip -9 > "$E2E_PRIVATE_NETWORK_RECONNECT_CLIENT_INITRAMFS")

cat > "$WORK_DIR/init" <<'EOF'
#!/bin/sh
/bin/busybox mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
/bin/busybox mount -t proc proc /proc 2>/dev/null || true
/bin/busybox mount -t sysfs sysfs /sys 2>/dev/null || true
/sbin/modprobe virtio_net 2>/dev/null || true

PRIVATE_IFACE=""
for attempt in 1 2 3 4 5; do
  for path in /sys/class/net/*; do
    iface="${path##*/}"
    [ "$iface" = "lo" ] && continue
    PRIVATE_IFACE="$iface"
  done
  [ -n "$PRIVATE_IFACE" ] && break
  /bin/busybox sleep 1
done

echo "OKRUN_E2E_PRIVATE_NETWORK_DHCP_IFACE=${PRIVATE_IFACE}" >/dev/console
echo "OKRUN_E2E_PRIVATE_NETWORK_DHCP_IFACE=${PRIVATE_IFACE}" >/dev/hvc0 2>/dev/null || true

if [ -z "$PRIVATE_IFACE" ]; then
  echo OKRUN_E2E_PRIVATE_NETWORK_DHCP_FAILED_NO_IFACE >/dev/console
  echo OKRUN_E2E_PRIVATE_NETWORK_DHCP_FAILED_NO_IFACE >/dev/hvc0 2>/dev/null || true
  /bin/busybox poweroff -f 2>/dev/null || /bin/busybox reboot -f 2>/dev/null || true
  while true; do :; done
fi

/bin/busybox ip link set "$PRIVATE_IFACE" up
/bin/busybox cat >/udhcpc-okrun.script <<'SCRIPT'
#!/bin/sh
case "$1" in
  bound|renew)
    /bin/busybox ip addr flush dev "$interface" 2>/dev/null || true
    /bin/busybox ip addr add "$ip/24" dev "$interface"
    ;;
esac
SCRIPT
/bin/busybox chmod 0755 /udhcpc-okrun.script
if ! /bin/busybox udhcpc -i "$PRIVATE_IFACE" -n -q -s /udhcpc-okrun.script >/dev/console 2>&1; then
  echo OKRUN_E2E_PRIVATE_NETWORK_DHCP_FAILED_UDHCPC >/dev/console
  echo OKRUN_E2E_PRIVATE_NETWORK_DHCP_FAILED_UDHCPC >/dev/hvc0 2>/dev/null || true
  /bin/busybox poweroff -f 2>/dev/null || /bin/busybox reboot -f 2>/dev/null || true
  while true; do :; done
fi

PRIVATE_IP="$(/bin/busybox ip -4 -o addr show dev "$PRIVATE_IFACE" | /bin/busybox awk '{ print $4 }' | /bin/busybox cut -d/ -f1 | /bin/busybox head -1)"
echo "OKRUN_E2E_PRIVATE_NETWORK_DHCP_IP=${PRIVATE_IP}" >/dev/console
echo "OKRUN_E2E_PRIVATE_NETWORK_DHCP_IP=${PRIVATE_IP}" >/dev/hvc0 2>/dev/null || true

case "$PRIVATE_IP" in
  10.77.0.*)
    ;;
  *)
    echo OKRUN_E2E_PRIVATE_NETWORK_DHCP_FAILED_IP >/dev/console
    echo OKRUN_E2E_PRIVATE_NETWORK_DHCP_FAILED_IP >/dev/hvc0 2>/dev/null || true
    /bin/busybox poweroff -f 2>/dev/null || /bin/busybox reboot -f 2>/dev/null || true
    while true; do :; done
    ;;
esac

if /bin/busybox ip route | /bin/busybox grep -q "default.*$PRIVATE_IFACE"; then
  echo OKRUN_E2E_PRIVATE_NETWORK_DHCP_FAILED_DEFAULT_ROUTE >/dev/console
  echo OKRUN_E2E_PRIVATE_NETWORK_DHCP_FAILED_DEFAULT_ROUTE >/dev/hvc0 2>/dev/null || true
  /bin/busybox poweroff -f 2>/dev/null || /bin/busybox reboot -f 2>/dev/null || true
  while true; do :; done
fi

echo OKRUN_E2E_PRIVATE_NETWORK_DHCP_PASSED >/dev/console
echo OKRUN_E2E_PRIVATE_NETWORK_DHCP_PASSED >/dev/hvc0 2>/dev/null || true
/bin/busybox poweroff -f 2>/dev/null || /bin/busybox reboot -f 2>/dev/null || true
while true; do :; done
EOF
chmod 0755 "$WORK_DIR/init"

(cd "$WORK_DIR" && find . | cpio -o -H newc --quiet | gzip -9 > "$E2E_PRIVATE_NETWORK_DHCP_INITRAMFS")

cat > "$WORK_DIR/init" <<'EOF'
#!/bin/sh
/bin/busybox mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
/bin/busybox mount -t proc proc /proc 2>/dev/null || true
/bin/busybox mount -t sysfs sysfs /sys 2>/dev/null || true
/sbin/modprobe virtio_net 2>/dev/null || true

PRIVATE_IFACE=""
for attempt in 1 2 3 4 5; do
  for path in /sys/class/net/*; do
    iface="${path##*/}"
    [ "$iface" = "lo" ] && continue
    PRIVATE_IFACE="$iface"
  done
  [ -n "$PRIVATE_IFACE" ] && break
  /bin/busybox sleep 1
done

echo "OKRUN_E2E_PRIVATE_NETWORK_DHCP_SERVER_IFACE=${PRIVATE_IFACE}" >/dev/console
echo "OKRUN_E2E_PRIVATE_NETWORK_DHCP_SERVER_IFACE=${PRIVATE_IFACE}" >/dev/hvc0 2>/dev/null || true

if [ -z "$PRIVATE_IFACE" ]; then
  echo OKRUN_E2E_PRIVATE_NETWORK_DHCP_SERVER_FAILED_NO_IFACE >/dev/console
  echo OKRUN_E2E_PRIVATE_NETWORK_DHCP_SERVER_FAILED_NO_IFACE >/dev/hvc0 2>/dev/null || true
  /bin/busybox poweroff -f 2>/dev/null || /bin/busybox reboot -f 2>/dev/null || true
  while true; do :; done
fi

/bin/busybox ip link set "$PRIVATE_IFACE" up
/bin/busybox cat >/udhcpc-okrun.script <<'SCRIPT'
#!/bin/sh
case "$1" in
  bound|renew)
    /bin/busybox ip addr flush dev "$interface" 2>/dev/null || true
    /bin/busybox ip addr add "$ip/24" dev "$interface"
    ;;
esac
SCRIPT
/bin/busybox chmod 0755 /udhcpc-okrun.script
if ! /bin/busybox udhcpc -i "$PRIVATE_IFACE" -n -q -s /udhcpc-okrun.script >/dev/console 2>&1; then
  echo OKRUN_E2E_PRIVATE_NETWORK_DHCP_SERVER_FAILED_UDHCPC >/dev/console
  echo OKRUN_E2E_PRIVATE_NETWORK_DHCP_SERVER_FAILED_UDHCPC >/dev/hvc0 2>/dev/null || true
  /bin/busybox poweroff -f 2>/dev/null || /bin/busybox reboot -f 2>/dev/null || true
  while true; do :; done
fi

PRIVATE_IP="$(/bin/busybox ip -4 -o addr show dev "$PRIVATE_IFACE" | /bin/busybox awk '{ print $4 }' | /bin/busybox cut -d/ -f1 | /bin/busybox head -1)"
echo "OKRUN_E2E_PRIVATE_NETWORK_DHCP_SERVER_IP=${PRIVATE_IP}" >/dev/console
echo "OKRUN_E2E_PRIVATE_NETWORK_DHCP_SERVER_IP=${PRIVATE_IP}" >/dev/hvc0 2>/dev/null || true

if [ "$PRIVATE_IP" != "10.77.0.20" ]; then
  echo OKRUN_E2E_PRIVATE_NETWORK_DHCP_SERVER_FAILED_IP >/dev/console
  echo OKRUN_E2E_PRIVATE_NETWORK_DHCP_SERVER_FAILED_IP >/dev/hvc0 2>/dev/null || true
  /bin/busybox poweroff -f 2>/dev/null || /bin/busybox reboot -f 2>/dev/null || true
  while true; do :; done
fi

if /bin/busybox ip route | /bin/busybox grep -q "default.*$PRIVATE_IFACE"; then
  echo OKRUN_E2E_PRIVATE_NETWORK_DHCP_SERVER_FAILED_DEFAULT_ROUTE >/dev/console
  echo OKRUN_E2E_PRIVATE_NETWORK_DHCP_SERVER_FAILED_DEFAULT_ROUTE >/dev/hvc0 2>/dev/null || true
  /bin/busybox poweroff -f 2>/dev/null || /bin/busybox reboot -f 2>/dev/null || true
  while true; do :; done
fi

echo OKRUN_E2E_PRIVATE_NETWORK_SERVER_READY >/dev/console
echo OKRUN_E2E_PRIVATE_NETWORK_SERVER_READY >/dev/hvc0 2>/dev/null || true
/bin/busybox sleep 30
/bin/busybox poweroff -f 2>/dev/null || /bin/busybox reboot -f 2>/dev/null || true
while true; do :; done
EOF
chmod 0755 "$WORK_DIR/init"

(cd "$WORK_DIR" && find . | cpio -o -H newc --quiet | gzip -9 > "$E2E_PRIVATE_NETWORK_DHCP_SERVER_INITRAMFS")

cat > "$WORK_DIR/init" <<'EOF'
#!/bin/sh
/bin/busybox mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
/bin/busybox mount -t proc proc /proc 2>/dev/null || true
/bin/busybox mount -t sysfs sysfs /sys 2>/dev/null || true
/sbin/modprobe virtio_net 2>/dev/null || true

PRIVATE_IFACE=""
for attempt in 1 2 3 4 5; do
  for path in /sys/class/net/*; do
    iface="${path##*/}"
    [ "$iface" = "lo" ] && continue
    PRIVATE_IFACE="$iface"
  done
  [ -n "$PRIVATE_IFACE" ] && break
  /bin/busybox sleep 1
done

echo "OKRUN_E2E_PRIVATE_NETWORK_DHCP_CLIENT_IFACE=${PRIVATE_IFACE}" >/dev/console
echo "OKRUN_E2E_PRIVATE_NETWORK_DHCP_CLIENT_IFACE=${PRIVATE_IFACE}" >/dev/hvc0 2>/dev/null || true

if [ -z "$PRIVATE_IFACE" ]; then
  echo OKRUN_E2E_PRIVATE_NETWORK_DHCP_CLIENT_FAILED_NO_IFACE >/dev/console
  echo OKRUN_E2E_PRIVATE_NETWORK_DHCP_CLIENT_FAILED_NO_IFACE >/dev/hvc0 2>/dev/null || true
  /bin/busybox poweroff -f 2>/dev/null || /bin/busybox reboot -f 2>/dev/null || true
  while true; do :; done
fi

/bin/busybox ip link set "$PRIVATE_IFACE" up
/bin/busybox cat >/udhcpc-okrun.script <<'SCRIPT'
#!/bin/sh
case "$1" in
  bound|renew)
    /bin/busybox ip addr flush dev "$interface" 2>/dev/null || true
    /bin/busybox ip addr add "$ip/24" dev "$interface"
    ;;
esac
SCRIPT
/bin/busybox chmod 0755 /udhcpc-okrun.script
if ! /bin/busybox udhcpc -i "$PRIVATE_IFACE" -n -q -s /udhcpc-okrun.script >/dev/console 2>&1; then
  echo OKRUN_E2E_PRIVATE_NETWORK_DHCP_CLIENT_FAILED_UDHCPC >/dev/console
  echo OKRUN_E2E_PRIVATE_NETWORK_DHCP_CLIENT_FAILED_UDHCPC >/dev/hvc0 2>/dev/null || true
  /bin/busybox poweroff -f 2>/dev/null || /bin/busybox reboot -f 2>/dev/null || true
  while true; do :; done
fi

PRIVATE_IP="$(/bin/busybox ip -4 -o addr show dev "$PRIVATE_IFACE" | /bin/busybox awk '{ print $4 }' | /bin/busybox cut -d/ -f1 | /bin/busybox head -1)"
echo "OKRUN_E2E_PRIVATE_NETWORK_DHCP_CLIENT_IP=${PRIVATE_IP}" >/dev/console
echo "OKRUN_E2E_PRIVATE_NETWORK_DHCP_CLIENT_IP=${PRIVATE_IP}" >/dev/hvc0 2>/dev/null || true

if [ "$PRIVATE_IP" != "10.77.0.21" ]; then
  echo OKRUN_E2E_PRIVATE_NETWORK_DHCP_CLIENT_FAILED_IP >/dev/console
  echo OKRUN_E2E_PRIVATE_NETWORK_DHCP_CLIENT_FAILED_IP >/dev/hvc0 2>/dev/null || true
  /bin/busybox poweroff -f 2>/dev/null || /bin/busybox reboot -f 2>/dev/null || true
  while true; do :; done
fi

if /bin/busybox ip route | /bin/busybox grep -q "default.*$PRIVATE_IFACE"; then
  echo OKRUN_E2E_PRIVATE_NETWORK_DHCP_CLIENT_FAILED_DEFAULT_ROUTE >/dev/console
  echo OKRUN_E2E_PRIVATE_NETWORK_DHCP_CLIENT_FAILED_DEFAULT_ROUTE >/dev/hvc0 2>/dev/null || true
  /bin/busybox poweroff -f 2>/dev/null || /bin/busybox reboot -f 2>/dev/null || true
  while true; do :; done
fi

for attempt in 1 2 3 4 5 6 7 8 9 10; do
  if /bin/busybox ping -c 1 -W 1 10.77.0.20 >/dev/console 2>&1; then
    echo OKRUN_E2E_PRIVATE_NETWORK_PASSED >/dev/console
    echo OKRUN_E2E_PRIVATE_NETWORK_PASSED >/dev/hvc0 2>/dev/null || true
    /bin/busybox poweroff -f 2>/dev/null || /bin/busybox reboot -f 2>/dev/null || true
    while true; do :; done
  fi
  /bin/busybox sleep 1
done

echo OKRUN_E2E_PRIVATE_NETWORK_DHCP_CLIENT_FAILED_PING >/dev/console
echo OKRUN_E2E_PRIVATE_NETWORK_DHCP_CLIENT_FAILED_PING >/dev/hvc0 2>/dev/null || true
/bin/busybox poweroff -f 2>/dev/null || /bin/busybox reboot -f 2>/dev/null || true
while true; do :; done
EOF
chmod 0755 "$WORK_DIR/init"

(cd "$WORK_DIR" && find . | cpio -o -H newc --quiet | gzip -9 > "$E2E_PRIVATE_NETWORK_DHCP_CLIENT_INITRAMFS")

echo "$BOOT_IMAGE"
echo "$E2E_INITRAMFS"
echo "$E2E_SHARED_INITRAMFS"
echo "$E2E_SAVE_RESTORE_INITRAMFS"
echo "$E2E_PRIVATE_NETWORK_SERVER_INITRAMFS"
echo "$E2E_PRIVATE_NETWORK_CLIENT_INITRAMFS"
echo "$E2E_PRIVATE_NETWORK_DHCP_INITRAMFS"
echo "$E2E_PRIVATE_NETWORK_DHCP_SERVER_INITRAMFS"
echo "$E2E_PRIVATE_NETWORK_DHCP_CLIENT_INITRAMFS"
echo "$E2E_PRIVATE_NETWORK_RECONNECT_CLIENT_INITRAMFS"
