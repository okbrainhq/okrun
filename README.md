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
  "privateNetwork": {
    "enabled": false,
    "identifier": "okrun"
  },
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

## Private VM Network

`privateNetwork` adds a second virtual NIC backed by an OkRUn-local Ethernet
bus. Keep the regular NAT NIC for internet access, and use this private NIC for
VM-to-VM traffic with static IPs configured inside Linux. This network is local
to OkRUn on the Mac; it does not depend on your Wi-Fi, router, or bridged
networking support.

### Enable the Network

Enable it in each VM's `okrun-vm.json`. VMs with the same `identifier` share one
private network:

```json
{
  "privateNetwork": {
    "enabled": true,
    "identifier": "okrun"
  }
}
```

Fully stop and restart the VMs after changing the config.

### Find the Private Interface

Inside each Linux VM, list the network interfaces:

```sh
ip -br link
ip -br addr
```

You should see the NAT interface with a `192.168.64.x` address and another
interface with no IP address. The interface with no IP address is usually the
OkRUn private network. For example:

```text
lo               UNKNOWN        00:00:00:00:00:00 <LOOPBACK,UP,LOWER_UP>
enp0s1           UP             5a:94:ef:12:34:56 <BROADCAST,MULTICAST,UP,LOWER_UP>
enp0s2           DOWN           5a:94:ef:65:43:21 <BROADCAST,MULTICAST>
```

And:

```text
lo               UNKNOWN        127.0.0.1/8 ::1/128
enp0s1           UP             192.168.64.16/24
enp0s2           DOWN
```

In this example, `<private-iface>` is `enp0s2`.

### Test with Temporary Static IPs

On `devbox`:

```sh
sudo ip link set <private-iface> up
sudo ip addr add 10.77.0.2/24 dev <private-iface>
```

On `devbox-sandbox`:

```sh
sudo ip link set <private-iface> up
sudo ip addr add 10.77.0.3/24 dev <private-iface>
```

Then test both directions:

```sh
ping -c 3 10.77.0.2
ping -c 3 10.77.0.3
```

Then add hostnames in `/etc/hosts` if desired:

```text
10.77.0.2 devbox.okrun devbox
10.77.0.3 devbox-sandbox.okrun devbox-sandbox
```

### Persist with systemd-networkd

The `ip addr add` commands are temporary. To keep the private IP after reboot,
configure the interface inside Linux. On a system using `systemd-networkd`,
create one `.network` file per VM.

On `devbox`, create `/etc/systemd/network/20-okrun-private.network`:

```ini
[Match]
Name=<private-iface>

[Network]
Address=10.77.0.2/24
```

On `devbox-sandbox`, use:

```ini
[Match]
Name=<private-iface>

[Network]
Address=10.77.0.3/24
```

Then enable and restart `systemd-networkd`:

```sh
sudo systemctl enable systemd-networkd
sudo systemctl restart systemd-networkd
```

Verify:

```sh
ip -br addr
ping -c 3 10.77.0.2
ping -c 3 10.77.0.3
```

Do not add a gateway for this private interface. Keep the default route on the
NAT interface so internet access continues to use OkRUn's regular NAT network.

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
Run fewer or smaller VMs when macOS shows sustained memory pressure or swap use;
guest performance can degrade sharply once the host starts compressing and
swapping VM memory.
