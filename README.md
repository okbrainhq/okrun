# Okrun VM

Small native macOS Virtualization.framework app for running Debian projects.

## Build

```sh
./scripts/build.sh
```

## Run

```sh
./scripts/run.sh
```

## Projects

An Okrun project is a directory that owns one VM:

- `okrun-vm.json` is the project config.
- `vm/debian.raw` is the sparse virtual disk.
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
  "installerISOPath": "/path/to/debian.iso"
}
```

Increasing `diskGB` expands the raw disk file. Existing disks are not shrunk
automatically.

## Disk Resizing

After increasing `diskGB`, Debian still needs its partition/filesystem expanded.
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
then shut down the VM and shrink `vm/debian.raw` on macOS with `truncate`.

## Memory Allocation

`memoryGB` is the guest RAM size at VM startup. Debian sees a fixed amount of RAM.
The app exposes a virtio balloon device so macOS and Debian can cooperate on
memory reclaim under pressure, but idle memory does not instantly shrink.
