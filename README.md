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

Run the critical GUI smoke suite without booting a VM:

```sh
./scripts/ui-test.sh
```

This builds the app, launches it with an isolated registry at
`.e2e/ui-add-delete`, drives the Add VM, validation, multi-VM selection,
private network config, settings, delete, and fake running shutdown flows with
macOS Accessibility automation, and saves screenshots under
`.e2e/ui-add-delete/screenshots`. If macOS blocks the script, allow the current
terminal or Codex app in System Settings > Privacy & Security > Accessibility
and rerun it.

## Projects

An Okrun project is a directory that owns one VM:

- `okrun-vm.json` is the project config.
- `vm/linux.raw` or `vm/linux.asif` is the sparse virtual disk.
- `vm/efi.variables` is the EFI variable store.
- `vm/machine.identifier` is the stable Virtualization.framework machine ID.

Keep the project on a local volume with plenty of free space. The virtual disk is
sparse, so the Mac may allocate much less than the guest-visible disk size at
first, but guest writes still need real host space later.

Known projects are stored in:

```text
~/.okrun
```

One app instance runs one VM at a time. Use the project selector to choose an
existing project, **New** to create a project, and **Delete** to remove the
selected project. Delete shows a destructive confirmation and removes the entire
project folder.

## Safe Shutdown

Use the Okrun **Shutdown** control or shut down from inside Linux. Okrun asks the
guest to power off and waits for the guest-stopped callback before closing after
Quit or window close.

Avoid force quitting Okrun or force-stopping the VM while Linux is writing to the
disk. Force stop is only for a stuck VM; it is equivalent to cutting power to a
machine and can leave the ext4 filesystem needing repair.

If Linux reports `EXT4-fs error` or `iget: checksum invalid`, stop the VM and run
`e2fsck` from a rescue environment or installer shell against the unmounted root
filesystem before booting it for normal use again.

## Config

```json
{
  "cpuCount": 4,
  "memoryGB": 4,
  "diskGB": 64,
  "diskFormat": "asif",
  "diskIO": {
    "caching": "cached",
    "synchronization": "full"
  },
  "installerISOPath": "/path/to/linux.iso",
  "privateNetwork": {
    "enabled": true
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

`diskFormat` accepts `raw` or `asif`. ASIF uses Apple Sparse Image Format and is
used by default for new projects on macOS 26 Tahoe or later. Older hosts and
legacy configs use `raw`. Existing disks are never converted automatically; if a
project already has `vm/linux.raw`, keep `diskFormat` as `raw`, and if it has
`vm/linux.asif`, keep `diskFormat` as `asif`.

Increasing `diskGB` expands the virtual disk. Existing disks are not shrunk
automatically.

`diskIO.caching` accepts `automatic`, `cached`, or `uncached`. Okrun defaults to
`cached` for the writable Linux disk, matching Tart's Linux disk default.
`diskIO.synchronization` accepts `full`, `fsync`, or `none`. Keep `full` for the
best durability; `fsync` and especially `none` can improve disk-heavy throwaway
workloads at the cost of weaker crash and power-loss safety.

## Imported VM Bootstrap

After importing an Ubuntu VM for the first time, use the interactive bootstrap
helper to turn the generic imported guest into a unique, SSH-ready VM:

```sh
./scripts/bootstrap-imported-vm.sh <hostname-or-ip>
```

The helper is intended for imported Ubuntu guests that are reachable over SSH
with the default `user` / `password` login. It asks for the new Linux username,
hostname, and SSH public key first, prints the full plan, and only then connects
to the VM.

On the guest, it runs `apt-get update` and `apt-get upgrade`, creates or updates
the selected login user, installs the selected SSH key, enables passwordless
sudo for that user, regenerates cloned machine identity, DHCP lease state, and
SSH host keys, changes the hostname, disables SSH password authentication, and
reboots the VM.

After the reboot, log in with the new user and hostname, then install the Okrun
guest tools if needed.

## Guest Tools

After installing Linux and enabling SSH inside any Okrun VM, install the generic
guest tools from the Mac:

```sh
./scripts/install-guest-tools.sh <hostname-or-ip>
```

Use `--user`, `--port`, or `--identity` for SSH options:

```sh
./scripts/install-guest-tools.sh --user arunoda --port 22 192.168.64.16
```

The installer copies scripts into the guest with `scp`, then uses `sudo` over
SSH to install:

- `okrun-guest-health.service`, which logs memory, disk, network, swap, mount,
  and recent kernel alert snapshots to a writable project-mounted share.
- `okrun-guest-diagnose`, a one-shot guest diagnostic command.
- `/mnt/okrun` VirtioFS mount support via `mnt-okrun.mount`.
- DHCP configuration for the Okrun private network interface when one is present.

Guest health logs are intentionally written to the Mac side instead of only the
guest disk. On every VM start, Okrun creates `vm/guest-logs` inside the project
if needed and exposes it as a writable `okrun-guest-logs` share under
`/mnt/okrun`. Any `sharedDirectories` entry with that name is ignored so the
host-managed log share always wins.

Fully stop and restart the VM before running the installer. If the writable
`/mnt/okrun/okrun-guest-logs` mount is missing, the guest installer exits with a
setup error that asks you to restart the VM with an updated Okrun build.

The health log rotates in place at 10 MB and keeps 5 old files by default:
`guest-health.log`, `guest-health.log.1`, and so on. Override this with
`OKRUN_LOG_MAX_BYTES` and `OKRUN_LOG_KEEP` in `/etc/okrun/guest-tools.env`.

The private network is enabled by default. When a VM has
`privateNetwork.enabled` in `okrun-vm.json`, the installer auto-detects the
private interface and configures it for IPv4 DHCP. The private NIC intentionally
does not install DNS or routes, so internet access keeps using the NAT
interface.

Okrun creates host DHCP config automatically the first time a VM starts with the
`okrun` private network. The generated default is written to
`~/.okrun/private-networks.json` like this:

```json
{
  "version": 1,
  "privateNetworks": {
    "okrun": {
      "dhcp": {
        "enabled": true,
        "mode": "range",
        "cidr": "10.77.0.0/24",
        "rangeStart": "10.77.0.20",
        "rangeEnd": "10.77.0.200",
        "leaseSeconds": 3600
      }
    }
  }
}
```

Okrun stores DHCP leases under `~/.okrun/state/private-networks/okrun/`.
`OKRUN_HOME` can point Okrun at a different state directory, and
`OKRUN_REGISTRY_PATH` still overrides only the project registry path.
Set `"enabled": false` for the DHCP config to opt out.

To prefer a no-TLS switch on a trusted LAN and fall back to Web Switch when that
local listener is unavailable, add a `localSwitch` entry beside the existing
Web Switch `switch` entry:

```json
{
  "version": 1,
  "privateNetworks": {
    "okrun": {
      "localSwitch": {
        "enabled": true,
        "server": "192.168.1.20:9444"
      }
    }
  }
}
```

When both are configured, Okrun routes private-network frames through Local
Switch while it is connected and automatically falls back to Web Switch until
the Local Switch connection returns.

DHCP is the default for the private-network interface. If a guest already has
an Okrun-managed static private-network file, the default installer run replaces
that file with DHCP. `--private-dhcp` is accepted when you want to be explicit:

```sh
./scripts/install-guest-tools.sh <hostname-or-ip>
./scripts/install-guest-tools.sh --private-dhcp <hostname-or-ip>
./scripts/install-guest-tools.sh --private-dhcp --private-iface enp0s2 <hostname-or-ip>
```

For advanced static setups, pass a CIDR address. Static config wins if both
`--private-ip` and `--private-dhcp` are supplied:

```sh
./scripts/install-guest-tools.sh --private-ip 10.77.0.3/24 <hostname-or-ip>
./scripts/install-guest-tools.sh --private-ip 10.77.0.3/24 --private-iface enp0s2 <hostname-or-ip>
```

To try growing the guest root filesystem after increasing `diskGB`, pass
`--resize-root`. This uses `growpart` when available and only works when free
space is adjacent to the root partition:

```sh
./scripts/install-guest-tools.sh --resize-root <hostname-or-ip>
```

Inside the guest, inspect logs and state with:

```sh
tail -f /mnt/okrun/okrun-guest-logs/guest-health.log
sudo okrun-guest-diagnose
systemctl status okrun-guest-health.service
```

## Private VM Network

`privateNetwork` adds a second virtual NIC backed by the `okrun` Ethernet bus.
Keep the regular NAT NIC for internet access, and use this private NIC for
VM-to-VM traffic. By default, the bus is local to one Mac. You can optionally
bridge it to other Macs on the same LAN through `~/.okrun/private-networks.json`.

### Enable the Network

The private network is enabled by default. To be explicit, set this in each VM's
`okrun-vm.json`:

```json
{
  "privateNetwork": {
    "enabled": true
  }
}
```

Set `"enabled": false` to remove the private NIC from a VM. Older configs with a
`privateNetwork.identifier` field are still accepted, but Okrun now uses the
single `okrun` network for normal VM config.

Fully stop and restart the VMs after changing the config.

### Bridge Multiple Hosts

To extend the `okrun` bus across Macs on the same LAN, add a `bridge` section to
the global config. `bind` is optional: use it on hosts that should accept
incoming peers, and use `peers` on hosts that should connect out. Once connected,
the bridge connection carries traffic both ways.

Host A, listening on `192.168.1.10:7777`:

```json
{
  "version": 1,
  "privateNetworks": {
    "okrun": {
      "dhcp": {
        "enabled": true,
        "mode": "range",
        "cidr": "10.77.0.0/24",
        "rangeStart": "10.77.0.20",
        "rangeEnd": "10.77.0.200",
        "leaseSeconds": 3600
      },
      "bridge": {
        "bind": {
          "host": "192.168.1.10",
          "port": 7777
        },
        "peers": [
          {
            "host": "192.168.1.11",
            "port": 7777
          }
        ]
      }
    }
  }
}
```

Host B can either bind on its own IP or omit `bind` and only list Host A in
`peers`. Local guest traffic still reaches guests on the same Mac directly.
Okrun forwards local guest frames to connected hosts and injects remote frames
into local guests, but it does not relay remote frames onward to other hosts.

For a client-only host, omit `bind`:

```json
{
  "version": 1,
  "privateNetworks": {
    "okrun": {
      "bridge": {
        "peers": [
          {
            "host": "192.168.1.10",
            "port": 7777
          }
        ]
      }
    }
  }
}
```

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
then shut down the VM. For RAW disks, shrink `vm/linux.raw` on macOS with
`truncate`. ASIF shrinking should be handled with `diskutil image resize` on
macOS 26 or later.

## Memory Allocation

`memoryGB` is the guest RAM size at VM startup. Linux sees a fixed amount of RAM.
Run fewer or smaller VMs when macOS shows sustained memory pressure or swap use;
guest performance can degrade sharply once the host starts compressing and
swapping VM memory.

## Diagnostics

Okrun writes host-side lifecycle, storage, and VM start/stop events to macOS
Unified Logging under the `local.okrun.vm` subsystem. The easiest way to tail
logs while reproducing an issue is:

```sh
./scripts/logs
```

By default this streams only the Web Switch logs, including connection attempts,
connection-refused waits, reconnect scheduling, server rejections, TLS ready
events, and successful INIT handshakes. When the server is unavailable, expect
retry logs to settle into this cadence:

```text
delayMs=500
delayMs=1000
delayMs=2000
delayMs=3000
delayMs=3000
```

Stream every Okrun category:

```sh
./scripts/logs all
```

Stream a specific category:

```sh
./scripts/logs virtual-machine
./scripts/logs lifecycle
./scripts/logs storage
```

The helper wraps `log stream`; the equivalent raw command for Web Switch logs is:

```sh
log stream --style compact --level debug --predicate '(subsystem == "local.okrun.vm" || subsystem == "com.okrun.vm") && category == "web-switch"'
```

Show recent Okrun logs after a VM hangs or stops:

```sh
log show --last 2h --style compact --predicate 'subsystem == "local.okrun.vm" || subsystem == "com.okrun.vm"'
```

These logs include the app bundle path, selected project, CPU/RAM/disk config,
disk image apparent and allocated sizes, disk expansion warnings, and VM
start/stop errors. Web Switch logs are in the `web-switch` category.

For a broader host-side snapshot, run:

```sh
./scripts/diagnose.sh
```

This prints Okrun processes, VM service CPU/memory, disk image ownership, host
memory pressure, GPT layouts, and recent Okrun logs.
