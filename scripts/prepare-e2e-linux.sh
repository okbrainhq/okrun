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

echo "$BOOT_IMAGE"
echo "$E2E_INITRAMFS"
echo "$E2E_SHARED_INITRAMFS"
