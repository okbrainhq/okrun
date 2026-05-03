# Okrun VM

Small native macOS Virtualization.framework app for running Linux projects.

## Build

```sh
./scripts/build.sh
```

## Run

```sh
./scripts/run.sh
```

## Test

Run fast unit and integration-style tests:

```sh
swift test
```

Run the real headless VM boot E2E:

```sh
./scripts/e2e-headless-boot.sh
```

The E2E script downloads Alpine Linux aarch64 netboot artifacts into `.e2e/`,
builds a tiny initramfs that prints `OKRUN_E2E_BOOTED`, builds the signed app,
and boots that Linux image with Virtualization.framework headlessly.

## Projects

An Okrun project is a directory that owns one VM:

- `okrun-vm.json` is the project config.
- `vm/linux.raw` is the sparse virtual disk.
- `vm/efi.variables` is the EFI variable store.
- `vm/machine.identifier` is the stable Virtualization.framework machine ID.

Known projects are stored in:

```text
~/.okrun
```

One app instance runs one VM at a time. Use the project selector to choose an
existing project, **New** to create a project, and **Delete** to remove the
selected project. Delete shows a destructive confirmation and removes the entire
project folder.

## Config

```json
{
  "cpuCount": 4,
  "memoryGB": 4,
  "diskGB": 64,
  "installerISOPath": "/path/to/linux.iso",
  "sharedDirectories": [
    {
      "name": "projects",
      "hostPath": "/Users/me/Projects",
      "readOnly": false
    },
    {
      "name": "downloads",
      "hostPath": "/Users/me/Downloads",
      "readOnly": true
    }
  ]
}
```

Increasing `diskGB` expands the raw disk file. Existing disks are not shrunk
automatically.

## Shared Directories

`sharedDirectories` exposes Mac directories to the Linux VM with VirtioFS. Each
entry needs a unique `name`, a Mac `hostPath`, and a `readOnly` flag.

Start the VM, then mount the Okrun share inside Linux:

```sh
sudo mkdir -p /mnt/okrun
sudo mount -t virtiofs okrun /mnt/okrun
```

Each configured directory appears below the mount point by name:

```text
/mnt/okrun/projects
/mnt/okrun/downloads
```

Linux must have VirtioFS support available. Shared directories are mounted
manually by default.

### Mount on Boot with systemd

To mount the Okrun share automatically on boot, create a systemd mount unit
inside the Linux VM.

1. Create the mount point:

```sh
sudo mkdir -p /mnt/okrun
```

2. Create `/etc/systemd/system/mnt-okrun.mount`:

```sh
sudo tee /etc/systemd/system/mnt-okrun.mount >/dev/null <<'EOF'
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
```

The unit filename must match the mount path: `/mnt/okrun` becomes
`mnt-okrun.mount`.

3. Reload systemd and start the mount:

```sh
sudo systemctl daemon-reload
sudo systemctl enable --now mnt-okrun.mount
```

4. Confirm the shared directories are visible:

```sh
findmnt /mnt/okrun
ls /mnt/okrun
```

To stop mounting it automatically:

```sh
sudo systemctl disable --now mnt-okrun.mount
```

## Disk Resizing

After increasing `diskGB`, Linux still needs its partition/filesystem expanded.
Check devices with:

```sh
lsblk -f
df -h
```

For a simple ext4 install:

```sh
sudo growpart /dev/vda 2
sudo resize2fs /dev/vda2
```

Shrinking must be done manually: shrink the guest filesystem and partition first,
then shut down the VM and shrink `vm/linux.raw` on macOS with `truncate`.

## Memory Allocation

`memoryGB` is the guest RAM size at VM startup. Linux sees a fixed amount of RAM.
The app exposes a virtio balloon device so macOS and Linux can cooperate on
memory reclaim under pressure, but idle memory does not instantly shrink.
