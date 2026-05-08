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
/bin/busybox sleep 30
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

echo "$BOOT_IMAGE"
echo "$E2E_INITRAMFS"
echo "$E2E_SHARED_INITRAMFS"
echo "$E2E_SAVE_RESTORE_INITRAMFS"
echo "$E2E_PRIVATE_NETWORK_SERVER_INITRAMFS"
echo "$E2E_PRIVATE_NETWORK_CLIENT_INITRAMFS"
