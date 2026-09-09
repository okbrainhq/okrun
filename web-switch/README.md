# OkRun Web Switch

`web-switch` is the layer-2 switch used by OkRun private networks. Web Switch
hosts connect outbound with mTLS client certificates. Local Switch hosts can
connect to a plain TCP listener on a trusted local network without TLS
credentials. Both listeners use the same switch protocol and fabric.

## Certificate Scripts

Run these from the `web-switch` directory. Each script also has an `npm run` alias.

Create or reuse a local CA:

```bash
./init-ca.sh
# or
npm run cert:init
```

This writes:

- `.ca/ca-cert.pem`
- `.ca/ca-key.pem`
- `.ca/crl.txt`

Issue the server TLS bundle:

```bash
./issue-server.sh switch.example.com
# or
npm run cert:server -- switch.example.com
```

For local development:

```bash
npm run cert:server -- localhost
```

This writes:

- `.certs/server/okrun-switch-server-bundle.json`

The server bundle contains the CA public certificate, server certificate, and server private key. Keep it private.

Issue an OkRun host/client bundle and print a UI-ready bundle:

```bash
./issue-client.sh arun-mac switch.example.com:9443
# or
npm run cert:client -- arun-mac switch.example.com:9443
# alias
npm run cert:host -- arun-mac switch.example.com:9443
```

This writes:

- `.certs/hosts/arun-mac/okrun-switch-bundle.json`

Paste the printed JSON into OkRun's Private Network panel under Web Switch > Host Bundle JSON.

Use `--certs-dir` to keep multiple environments side by side. A cert root stores
`ca/`, `server/`, and `hosts/` under one directory:

```bash
npm run cert:init -- --certs-dir .certs/prod
npm run cert:server -- --certs-dir .certs/prod switch.example.com
npm run cert:host -- --certs-dir .certs/prod arun-mac switch.example.com:9443
```

For a two-host local setup:

```bash
./generate-local-certs.sh
# or
npm run cert:local

# custom root
npm run cert:local -- --certs-dir .certs/local
```

## Starting Locally

```bash
npm run start -- \
  --host 127.0.0.1 \
  --tls-port 9443 \
  --local-port 9444 \
  --status-port 8080 \
  --server-bundle .certs/server/okrun-switch-server-bundle.json \
  --crl .ca/crl.txt
```

For a Local Switch only listener, disable the TLS listener and provide a local
port:

```bash
npm run start -- \
  --host 127.0.0.1 \
  --tls-enabled false \
  --local-port 9444 \
  --status-port 8080
```

The equivalent environment variables are `OKRUN_SWITCH_TLS_ENABLED=false` and
`OKRUN_SWITCH_LOCAL_PORT=9444`.

Local Switch uses shorter keepalives by default so clients can fall back quickly
when a LAN peer disappears. Tune them with
`OKRUN_SWITCH_LOCAL_KEEPALIVE_INTERVAL_MS` and
`OKRUN_SWITCH_LOCAL_KEEPALIVE_TIMEOUT_MS`.

Health and status:

```bash
curl http://127.0.0.1:8080/healthz
curl http://127.0.0.1:8080/status
```

## Ubuntu Physical-Host Client

This attaches **the Ubuntu host itself** to the same virtual Ethernet network as
Okrun VMs. It creates one TAP (`okrun0`) connected to the host's own IP stack,
not another switch, VM, LAN bridge, NAT gateway, or DHCP server. VMs can access
services on this host as **`azero.local`** when its hostname is `azero`.

For credential storage, updates, backup/rotation, and verification commands, see
the [Ubuntu host operations runbook](docs/ubuntu-host-operations.md).

### Install this deployment (no manual IP)

Prerequisites: system-wide Node.js 20+ (`/usr/bin/node` or `/usr/local/bin/node`),
Python 3, `iproute2`, systemd, `/dev/net/tun`, and `avahi-daemon`. The installer
checks dependencies but does not download packages. `libnss-mdns` or an enabled
systemd-resolved mDNS resolver is needed for normal `.local` lookups on clients.

Run from the repository root:

```bash
# Existing installation: reuse the root-only bundle in /etc.
sudo bash web-switch/scripts/setup-ubuntu.sh

systemctl is-enabled okrun-network
systemctl is-active okrun-network
journalctl -u okrun-network -n 50 --no-pager
ip address show okrun0
ping -I okrun0 devbox2.local
```

Setup selects network `okrun`, local switch **172.16.0.10:9443**, and the cloud
endpoint/credentials from **`/etc/okrun-network/host.json`** by default. No IP
argument is needed. The existing VM subnet for this deployment is **10.77.0.0/24**.
For a new host or credential rotation, pass a private import file outside Git:

```bash
chmod 600 /path/to/private/host.json
sudo bash web-switch/scripts/setup-ubuntu.sh /path/to/private/host.json
```

The installer stores it as `root:root`, mode `0600`, inside a mode `0700`
directory. It safely stages/validates replacements, including when source and
destination are the same installed file. After verification, remove any redundant
import copy. Setup never falls back to the old bundle location in the checkout.

The canonical installer and unit template are in this directory:

- `scripts/install-network-client.sh` (the repository-level script forwards here)
- `scripts/setup-ubuntu.sh` (this deployment's defaults)
- `systemd/okrun-network.service.in`
- `src/host-client.js`, `src/host-address.js` (automatic host attachment)
- `bin/okrun-network.js`, `bin/okrun-switch-tap-helper.py` (transport and host TAP)

### How automatic attachment works

The virtual switch is layer 2; it does not hand out DHCP leases. Okrun's VM DHCP
responder only serves frames originating from its own guests (`HostDHCP.swift`).
A physical host therefore cannot obtain a VM lease merely by sending DHCP into
the switch. IPv4 link-local would not solve this either: guest tools disable
link-local addressing on the private NIC.

The client handles the host-side configuration without manual address selection:

1. Chooses a stable candidate on the configured VM subnet, preferring addresses
   above the usual VM pools. It excludes network, gateway (.1), and broadcast.
2. Reserves **only that one host address** using the switch's existing
   `INIT.dhcpRange` overlap admission check, on each connected transport. This is
   reservation metadata, not a DHCP pool/server; it does not lease addresses to VMs.
3. Sends three ARP probes before assigning the address. An active pool overlap or
   ARP collision causes selection of another address. It continues detecting ARP
   conflicts after assignment and relinquishes/retries if another owner appears.
4. Assigns the address to `okrun0`; Avahi advertises the machine's existing
   hostname on that interface. MAC identity and last successful address persist
   in `/var/lib/okrun-network/host-state.json` (root-only).

Probing follows the timing/packet conventions in RFC 5227.
[source](https://datatracker.ietf.org/doc/html/rfc5227)
Address reservations protect against *active advertised* pools; ARP detects
reachable owners, not powered-off hosts or unavailable transports. Do not place
manually reserved/offline addresses in a subnet used for automatic attachment
without coordinating them with your network administrator. The subnet is a
configuration default, **not discovered from the credential bundle**. For a
custom VM subnet use `--subnet` (canonical RFC1918 /16 through /30), or the sixth
installer argument. Avoid overlapping existing physical LAN/VPN routes.

Avahi must allow `okrun0` and address publishing. The installer starts/enables
Avahi but does not replace `/etc/avahi/avahi-daemon.conf` or rename the machine.
Custom `allow-interfaces`, `deny-interfaces`, `host-name`, or disabled publishing
settings can prevent the expected name; the live verifier below detects this.
The Avahi settings manual describes these options.
[source](https://linux.die.net/man/5/avahi-daemon.conf)

### Other configurations and security

```bash
# Cloud-only, automatic host addressing:
sudo bash web-switch/scripts/install-network-client.sh /etc/okrun-network/host.json

# Custom subnet/network and optional LAN switch:
sudo bash web-switch/scripts/install-network-client.sh \
  /etc/okrun-network/host.json auto mynetwork okrun0 192.168.1.10:9444 10.88.0.0/24

# Foreground (stop any service using okrun0 first):
sudo node web-switch/bin/okrun-network.js \
  --bundle /etc/okrun-network/host.json --local-server 172.16.0.10:9443

# Legacy explicitly configured address remains supported:
sudo node web-switch/bin/okrun-network.js \
  --bundle /etc/okrun-network/host.json --ip 10.77.0.2/24
```

Use a separate **host bundle** for each machine, issued by the existing CA. Never
copy the CA private key or server bundle. Keep the host credential out of Git
and checkouts; the old filename stays ignored only as a defensive guard. Only
client code goes into `/opt/okrun-network`; the canonical credential is
`/etc/okrun-network/host.json` (`root:root`, mode `0600`, parent directory `0700`).
Re-run the installer to update the code/settings. One service/network per host
is supported. Existing TAPs are not reused.

Both transports stay connected. Discovery uses both; learned local peers prefer
local and fall back to cloud if local disconnects. Cloud-only peers use cloud.
Transport retries preserve the TAP unless address admission conflicts. The
cloud-only service restarts on failure. The unit limits capabilities to
`CAP_NET_ADMIN`, restricts filesystem/device access, and restarts on crashes.
Stopping it removes the non-persistent TAP and its connected route.

**The local protocol is unauthenticated, unencrypted TCP**, even on port 9443;
use only on a trusted LAN. Cloud uses verified mTLS. Incoming Ethernet traffic
is never bridged between the two switches or onto physical NICs. Cross-path
duplicate suppression and bounded routing tables/queues remain in effect.

The installer excludes only the dedicated TAP from NetworkManager management.
It does not restart physical networking, enable IP forwarding, change firewall
rules, add a default route, or run DHCP/DNS servers. IPv6 is disabled only on
the auto-addressed TAP so router advertisements cannot alter host routing.
Services must listen on the TAP address or `0.0.0.0` (not just `127.0.0.1`);
allow only intended ports from the VM network in your host firewall. Discovery
is not a promise that every service is reachable or that peers enable mDNS.

### Verification

```bash
# Admission check only: no TAP/address/traffic. sudo reads the protected bundle.
sudo node web-switch/bin/check-network.js \
  --bundle /etc/okrun-network/host.json --local-server 172.16.0.10:9443

# With the host service running: actual peer -> azero.local -> host TCP/HTTP.
sudo node web-switch/bin/verify-host.js \
  --bundle /etc/okrun-network/host.json \
  --local-server 172.16.0.10:9443 --name azero.local

# Unprivileged automated tests (real test switches, simulated TAPs).
bash scripts/test-network-client.sh

# Opt-in real systemd/TAP tests; temporary services, not the production unit.
sudo node web-switch/tests/network-service.test.js
sudo node web-switch/tests/network-service.test.js --auto
```

`check-network.js` checks only protocol admission/certificate validation.
`verify-host.js` creates a temporary VM-like Linux network namespace with a TAP
but **no physical interface or default route**. It joins the real switch using
automatic addressing, queries mDNS on that virtual link, then checks a one-time
HTTP response from the physical host. It tests local-only and cloud-only paths
separately and removes its namespace, TAP, and temporary HTTP listener. It is
not a login to an existing VM. Avoid concurrent verifier runs on this host.

Systemd tests use generated certificates, an isolated network identifier,
`192.0.2.254/32` in static mode or `10.253.239.0/24` in auto mode, and unique units
under `/run/systemd/system`. They verify real ARP conflict recovery in auto mode,
address persistence, ARP exchange, crash restart, and cleanup. Do not run these test modes where their test subnet
is already in use. `systemctl is-active` alone does not prove network health;
check `local switch connected`, `cloud switch connected`, `Joined okrun`, and
peer discovery/reachability.

### Stop/remove

```bash
sudo systemctl disable --now okrun-network
sudo rm /etc/systemd/system/okrun-network.service
sudo systemctl daemon-reload
sudo rm -r /opt/okrun-network /etc/okrun-network /var/lib/okrun-network
sudo rm -f /etc/NetworkManager/conf.d/90-okrun-network.conf
# If NetworkManager is running:
sudo nmcli general reload conf
```

Avahi is shared with the rest of the host and is intentionally left running.

## Linux Access Port

On a Linux cloud switch host, `web-switch` can join one private network through a
real TAP interface. This lets a normal SSH login on the cloud host reach private
hosts by IP, and `.local` names when mDNS/NSS is configured on that Linux host.

```bash
sudo npm run start -- \
  --tls-port 9443 \
  --status-port 8080 \
  --server-bundle .certs/server/okrun-switch-server-bundle.json \
  --crl .ca/crl.txt \
  --access-network okrun \
  --access-iface oksw0 \
  --access-ip 10.77.0.1/24
```

Equivalent environment variables:

```bash
OKRUN_SWITCH_ACCESS_NETWORK=okrun
OKRUN_SWITCH_ACCESS_IFACE=oksw0
OKRUN_SWITCH_ACCESS_IP=10.77.0.1/24
```

`OKRUN_SWITCH_ACCESS_NETWORK` must match the exact `networkIdentifier` used by
the VM clients. For the current deployment that network is `okrun`; if the access
port joins `okrun-prod` while clients join `okrun`, the TAP interface will be
alone and ARP/ping/SSH to private hosts will fail.

The access port requires Linux `/dev/net/tun`, `iproute2`, and root or
`CAP_NET_ADMIN`. It is disabled by default. Treat the cloud host as a full L2
member of the selected private network while this is enabled.

Safety limits are enabled by default and can be tuned per deployment:

```bash
OKRUN_SWITCH_RATE_LIMIT_FRAMES_PER_SECOND=20000
OKRUN_SWITCH_RATE_LIMIT_BYTES_PER_SECOND=134217728
OKRUN_SWITCH_RATE_LIMIT_BROADCAST_FRAMES_PER_SECOND=2000
OKRUN_SWITCH_RATE_LIMIT_MULTICAST_FRAMES_PER_SECOND=5000
OKRUN_SWITCH_RATE_LIMIT_UNKNOWN_UNICAST_FRAMES_PER_SECOND=5000
OKRUN_SWITCH_MAX_PENDING_WRITES=256
OKRUN_SWITCH_MAX_PENDING_BYTES=4194304
```

Set a rate limit to `0` to disable that specific limiter. Dropped frames and
drop reasons are included in `/status` per host.

## Deploying To A Linux VM

Create the deploy config:

```bash
cp .deploy.switch.example .deploy.switch
```

Edit `.deploy.switch` with the VM SSH target, switch hostname, and repo URL.
To expose a private network from the cloud host, also set the optional TAP access
variables:

```bash
SWITCH_ACCESS_NETWORK=okrun
SWITCH_ACCESS_IFACE=oksw0
SWITCH_ACCESS_IP=10.77.0.1/24
SWITCH_ACCESS_MTU=1500
```

`SWITCH_ACCESS_NETWORK` is not an environment label; it is the switch fabric
network name. It must match the VM clients' `networkIdentifier` shown in
`/status`.

Then create the server certificate locally and deploy it:

```bash
npm run cert:init -- --certs-dir .certs/prod
npm run cert:server -- --certs-dir .certs/prod switch.example.com
./scripts/deploy/setup-server.sh deploy@switch.example.com --upload-certs .certs/prod
```

`--upload-certs` does not auto-detect local certs. Pass the cert root explicitly,
or set `CERTS_DIR=.certs/prod` in `.deploy.switch`. If you keep CA and server
certs in separate directories, use `--server-cert-dir <dir> --ca-dir <dir>`.

Later code updates can reuse the remote certificates:

```bash
./scripts/deploy/setup-server.sh deploy@switch.example.com
```

The setup installs Node.js, Python 3, iproute2, avahi-daemon, and libnss-mdns,
clones/updates the repo under
`/opt/okrun-switch/source`, runs `okrun-switch` with systemd, and configures UFW
to allow only SSH plus the switch mTLS port. If `SWITCH_ACCESS_NETWORK` is set,
the systemd unit grants `CAP_NET_ADMIN` so the TAP helper can create the access
interface. The status HTTP port is for local health checks and SSH access; it is
not opened in the firewall.

## Deploying a Local Switch to a Mac

For a trusted local network, deploy a non-TLS `okrun-switch` as a macOS
LaunchAgent. Create the deploy config:

```bash
cp .deploy.local.example .deploy.local
```

Edit `.deploy.local` with the Mac SSH target, repo URL, and listener ports:

```
REPO_URL=https://github.com/okbrainhq/okrun.git
DEPLOY_HOST=arun@macbook.local
LOCAL_PORT=9444
STATUS_PORT=8080
HOST=127.0.0.1
```

Deploy:

```bash
./scripts/deploy/setup-local.sh
```

Or pass the host on the command line:

```bash
./scripts/deploy/setup-local.sh arun@macbook.local
```

The setup installs Node.js to `~/.local`, clones/updates the repo under
`~/okrun-switch`, and runs the local switch as a LaunchAgent. It listens on a
plain TCP port (no mTLS), so it should only be used on a trusted LAN.

Later code updates can be redeployed the same way:

```bash
./scripts/deploy/setup-local.sh
```

## Revoking A Host

```bash
./revoke-host.sh <certificate-serial>
# or
npm run cert:revoke -- <certificate-serial>

# custom root
npm run cert:revoke -- --certs-dir .certs/prod <certificate-serial>
```

The switch reads the CA directory's `crl.txt`; restart or redeploy the switch
after updating the CRL.

## Tests

```bash
npm test
```

Linux TAP access-port E2E runs on a Linux host with passwordless sudo:

```bash
../scripts/e2e-web-switch-access-linux.sh
# or from macOS, after SSH auth is available:
../scripts/e2e-web-switch-access-remote.sh arunoda@devbox-sandbox.local
```
