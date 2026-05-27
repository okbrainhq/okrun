# Okrun VM

Okrun VM is a small native macOS app for running Linux and macOS VMs with
Virtualization.framework. The app is organized around VM projects: each project
is a folder with its own config, disk, boot metadata, and machine identity.

## Clone & Build It

Install Xcode Command Line Tools first if Swift is not already available:

```sh
xcode-select --install
```

Then clone and build the app:

```sh
git clone https://github.com/okbrainhq/okrun.git
cd okrun
./scripts/build.sh
```

The build script creates `OkrunVM.app`, copies the app resources, and ad-hoc
signs the bundle with the virtualization entitlement needed for local use.

Okrun runs on macOS 13 or later. New ASIF disks and ASIF imports require macOS
26 Tahoe or later; older hosts use RAW disks.

## Run It

```sh
./scripts/run.sh
```

`run.sh` builds the app if needed and opens `OkrunVM.app`.

Okrun remembers known VM projects in `~/.okrun/registry.json`. The sidebar shows
one tab per VM project. Use the plus button for a new VM, the import button for
an ASIF import, and the network button for private network settings.

## Create a New VM

1. Click **New VM**.
2. Choose a VM folder. This folder becomes the Okrun project.
3. Choose the guest OS and installer image. Linux uses an ISO; macOS uses an IPSW restore image.
4. Pick CPU, memory, disk size, and disk format.
5. Click **Create**.
6. Click **Boot Installer** and install the guest OS to the virtual disk.
7. Shut the guest down cleanly.
8. Click **Start** for normal installed boots.

After installation, log in through the Okrun VM display. For Linux, you need the
VM's network name or IP address before you can SSH in or install guest tools.

The project folder will look like this:

```text
my-vm/
  okrun-vm.json
  vm/
    linux.asif        # or linux.raw
    efi.variables
    machine.identifier
```

macOS projects use `macos.raw` or `macos.asif` plus `macos.hardware-model`,
`macos.machine-identifier`, and `macos.auxiliary-storage`. Okrun creates those
files from the selected IPSW before the first macOS install.

`okrun-vm.json` is the file to edit for VM resources, startup behavior, shared
folders, and per-VM private networking:

```json
{
  "guestOS": "linux",
  "cpuCount": 4,
  "memoryGB": 4,
  "diskGB": 64,
  "diskFormat": "asif",
  "installerISOPath": "/path/to/linux.iso",
  "privateNetwork": {
    "enabled": true
  },
  "sharedDirectories": [],
  "diskIO": {
    "caching": "cached",
    "synchronization": "full"
  },
  "startup": {
    "startOnAppLaunch": false,
    "mode": "installed"
  }
}
```

Use `"guestOS": "macos"` with an IPSW path in `installerISOPath` for a macOS
guest. When macOS is selected in **Add VM**, Okrun can open or copy Apple's
latest restore-image download URL supported by the current Mac. macOS guests
require Apple silicon. Okrun configures both the Mac trackpad device and a USB
screen-coordinate pointing device, so mouse and trackpad input work across newer
and older guests.

Use **VM > Edit VM Config** to open the selected VM's config. Stop the VM before
changing config that affects devices, disks, or shared directories.

## Find the VM IP

Option 1: log in through the Okrun GUI and print the IP addresses:

```sh
ip -br addr
hostname -I
```

Look for the NAT address, usually `192.168.64.x`. Use that from your Mac:

```sh
ssh <linux-user>@192.168.64.x
```

Option 2: log in through the Okrun GUI and install Avahi for `.local` hostnames
on Debian/Ubuntu guests:

```sh
sudo apt update
sudo apt install -y avahi-daemon avahi-utils
sudo systemctl enable --now avahi-daemon
hostnamectl
```

Then use the VM hostname from your Mac:

```sh
ssh <linux-user>@<hostname>.local
```

## Install Guest Tools

After Linux is installed and SSH is enabled inside the VM, install the guest
tools from your Mac:

```sh
./scripts/install-guest-tools.sh --user <linux-user> <hostname-or-ip>
```

Examples:

```sh
./scripts/install-guest-tools.sh --user ubuntu 192.168.64.16
./scripts/install-guest-tools.sh --user arunoda --port 22 devbox.local
./scripts/install-guest-tools.sh --user ubuntu --identity ~/.ssh/id_ed25519 192.168.64.16
```

Fully stop and restart the VM once before running the installer so the managed
guest log share is present.

The installer copies scripts over SSH and installs:

- `okrun-guest-health.service` for periodic guest health logs.
- `okrun-guest-diagnose` for one-shot guest diagnostics.
- `/mnt/okrun` VirtioFS mount support.
- DHCP setup for the Okrun private network interface.

Guest health logs are written to the Mac side at `vm/guest-logs` and exposed to
Linux as `/mnt/okrun/okrun-guest-logs`. Check them inside the VM with:

```sh
tail -f /mnt/okrun/okrun-guest-logs/guest-health.log
sudo okrun-guest-diagnose
systemctl status okrun-guest-health.service
```

To grow the guest filesystem after increasing `diskGB`, run:

```sh
./scripts/install-guest-tools.sh --user <linux-user> --resize-root <hostname-or-ip>
```

## Shared Folders

Add shared folders to `okrun-vm.json`:

```json
{
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

Restart the VM after changing shared directories. Inside Linux, mount the Okrun
VirtioFS share:

```sh
sudo mkdir -p /mnt/okrun
sudo mount -t virtiofs okrun /mnt/okrun
ls /mnt/okrun
```

Each configured folder appears below `/mnt/okrun` by its `name`:

```text
/mnt/okrun/projects
/mnt/okrun/downloads
```

Guest tools install a systemd mount unit for `/mnt/okrun`. Without guest tools,
create one manually if you want the share mounted on boot.

## VM Networking

Every VM gets a regular NAT interface for internet access.

Okrun also enables a second private network interface by default:

```json
{
  "privateNetwork": {
    "enabled": true
  }
}
```

Set `"enabled": false` to remove the private NIC from that VM. Fully stop and
restart the VM after changing this setting.

The private network is named `okrun`. It is meant for VM-to-VM traffic and does
not install DNS or a default route, so internet access stays on the NAT
interface.

Host-side private network settings live in:

```text
~/.okrun/private-networks.json
```

Okrun creates the default DHCP range automatically the first time a private
network VM starts:

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

Inside Linux, guest tools configure the private NIC with DHCP. To inspect it:

```sh
ip -br link
ip -br addr
```

You should see one `192.168.64.x` NAT address and one private `10.77.0.x`
address when DHCP is working. Test VM-to-VM traffic with `ping` between private
addresses.

For static private addresses, pass a CIDR to the guest tools installer:

```sh
./scripts/install-guest-tools.sh --user <linux-user> --private-ip 10.77.0.3/24 <hostname-or-ip>
```

## Importing a VM

Okrun imports `.asif` Linux disks into new VM projects.

1. Click **Import VM**.
2. Choose the source `.asif` disk.
3. Choose a project name and destination folder.
4. Pick CPU and memory.
5. Click **Import**.
6. Start the imported VM.

The importer copies the ASIF disk, detects its virtual disk size, writes
`okrun-vm.json`, and creates fresh Okrun EFI and machine identifier files. The
imported project uses `diskFormat: "asif"` and has private networking enabled.

For Ubuntu VMs imported from a generic image or clone, run the bootstrap helper
after the first boot:

```sh
./scripts/bootstrap-imported-vm.sh <hostname-or-ip>
```

The bootstrap helper assumes the imported VM is reachable by SSH with the
default `user` / `password` login. It asks for the new Linux username, hostname,
and SSH public key, prints a full plan, and only runs remote commands after you
confirm.

On the guest it updates packages, creates or updates the chosen login user,
installs your SSH key, enables passwordless sudo, regenerates cloned machine
identity and SSH host keys, clears DHCP lease state, changes the hostname,
disables SSH password authentication, and reboots.

After the reboot, log in with the new user and install guest tools.

## Web Switch & Local Switch

The Okrun private network is local to one Mac by default. Web Switch and Local
Switch let the same layer-2 private network span multiple Macs.

**Web Switch** is the secure remote option. Hosts connect outbound to a switch
server with mTLS client certificates. Use it when Macs are not on the same
trusted LAN or when you want certificate-based host identity.

Quick Web Switch certificate flow:

```sh
cd web-switch
npm install
npm run cert:init
npm run cert:server -- switch.example.com
npm run cert:host -- my-mac switch.example.com:9443
```

Paste the printed host bundle JSON into Okrun's **Private Network > Web Switch >
Host Bundle JSON** field, enable Web Switch, and click **Apply & Connect**.

**Local Switch** is the trusted-LAN option. It uses the same switch protocol but
listens on plain TCP without TLS. Use it only on a trusted local network.

Start a local switch listener:

```sh
cd web-switch
npm install
npm run start -- \
  --host 127.0.0.1 \
  --tls-enabled false \
  --local-port 9444 \
  --status-port 8080
```

Then open Okrun's **Private Network > Local Switch**, enable it, set the server
to `127.0.0.1:9444` or another trusted LAN host, and click **Apply & Connect**.

When both Local Switch and Web Switch are configured, Okrun uses Local Switch
while it is connected and falls back to Web Switch if the local listener is not
available.

See [web-switch/README.md](web-switch/README.md) for full server deployment,
certificate, revocation, and LaunchAgent setup.

## Other Useful Stuff

Use Okrun's **Shutdown** control or shut down from inside the guest. Force stop is
for stuck VMs only; it is equivalent to cutting power and can leave the guest
filesystem needing repair.

Increasing `diskGB` expands the virtual disk image, but the guest may still need
its partition and filesystem expanded. Linux guest tools can try this with
`--resize-root`; otherwise use tools such as `growpart` and `resize2fs` inside
the guest.

`OKRUN_HOME` points Okrun at a different state directory. `OKRUN_REGISTRY_PATH`
overrides only the project registry path.

Useful diagnostics:

```sh
./scripts/logs all
./scripts/diagnose.sh
```

Useful tests:

```sh
swift test
./scripts/test.sh
./scripts/ui-test.sh
```

`./scripts/test.sh` runs Swift tests plus the guest tools, headless boot, and
headless switch E2E checks. `./scripts/ui-test.sh` drives the app UI without
booting a VM.
