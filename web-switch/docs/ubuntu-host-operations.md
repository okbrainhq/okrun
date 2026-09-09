# Ubuntu host network: operations and credential storage

This deployment attaches the physical Ubuntu host `azero` to the existing `okrun`
VM Ethernet network through `okrun0`. It uses the LAN switch `172.16.0.10:9443`
and the cloud endpoint in the host bundle. No VM, extra switch, LAN bridge, DHCP
server, or manually chosen host IP is needed. See the
[README](../README.md#ubuntu-physical-host-client) for architecture and limitations.

All commands below run from the repository/workspace root unless stated otherwise.

## Canonical on-host files

| Path | Purpose | Ownership / mode |
| --- | --- | --- |
| `/etc/okrun-network/host.json` | Cloud endpoint, client certificate/private key and CA certificate | `root:root`, `0600` |
| `/etc/okrun-network/` | Private configuration directory | `root:root`, `0700` |
| `/var/lib/okrun-network/host-state.json` | Persistent MAC seed and last automatic host address | `root:root`, `0600` |
| `/var/lib/okrun-network/` | Runtime state directory managed by systemd | `root:root`, `0700` |
| `/opt/okrun-network/` | Installed client code, independent of the checkout | Directories `0755`, code `0644` |
| `/etc/systemd/system/okrun-network.service` | Boot/start/restart unit | `0644` |
| `/etc/NetworkManager/conf.d/90-okrun-network.conf` | Excludes only the dedicated TAP from NetworkManager | Written by installer when NetworkManager is active |

`/etc` is for host-specific configuration; `/var/lib` is for persistent state
that programs modify while running. [source](https://refspecs.linuxfoundation.org/FHS_3.0/fhs-3.0.txt)

The credential is **not stored in the checkout or worktree**. The matching
`web-switch/okrun-switch-bundle.json` copies from both were removed after checking
that their contents matched the protected installed file. Its filename remains
Git-ignored as a guard against accidental reintroduction, not as a storage policy.
No credential contents belong in documentation, project tricks, logs, or commits.

These permissions restrict local access; they do not encrypt the file at rest.
Only root needs to read the bundle. Do not loosen permissions just to run a probe
without sudo. A read-only check can inspect metadata without exposing contents:

```bash
sudo stat -c '%a %U:%G %n' /etc/okrun-network /etc/okrun-network/host.json
```

## Install or update

On this already configured host, use the protected installed bundle by default:

```bash
sudo bash web-switch/scripts/setup-ubuntu.sh
```

The wrapper never falls back to a credential in the checkout. It keeps network
`okrun`, interface `okrun0`, and the local switch above. The existing VM subnet is
`10.77.0.0/24`; automatic configuration chooses/reserves one host address and
probes for conflicts. Do not hard-code the current address or delete the state
file during a routine update.

For first installation, a reissued credential, or a restore, supply a **private
regular file outside the checkout** explicitly:

```bash
chmod 600 /path/to/private/host.json
sudo bash web-switch/scripts/setup-ubuntu.sh /path/to/private/host.json
```

The installer checks the source, stages a root-owned private copy in
`/etc/okrun-network`, validates that staged copy, and atomically renames it into
place. Reinstalling from `/etc/okrun-network/host.json` works without a same-file
copy error. Invalid input is rejected before the network service is stopped;
source/destination symlinks are refused. Temporary staged credentials are removed
on ordinary exit/failure. Installation briefly restarts the network service.

The installer does **not** delete a user-supplied import file. After the checks
below pass, remove only the redundant import (never the canonical `/etc` file).
No automatic plaintext backup of old credentials is created.

## Verify after changes

```bash
systemctl is-enabled okrun-network
systemctl is-active okrun-network
journalctl -u okrun-network -n 30 --no-pager -o cat
ip -brief address show dev okrun0

# Protocol admission: no TAP or host address created. sudo reads the private file.
sudo node web-switch/bin/check-network.js \
  --bundle /etc/okrun-network/host.json --local-server 172.16.0.10:9443

# Peer -> azero.local -> physical-host HTTP, separately via local and cloud.
sudo node web-switch/bin/verify-host.js \
  --bundle /etc/okrun-network/host.json \
  --local-server 172.16.0.10:9443 --name azero.local

# Reach a real VM using the virtual interface.
ping -I okrun0 -c 5 -W 2 devbox2.local
```

Expect `local switch connected`, `cloud switch connected`, and `Joined okrun`.
`active` alone proves only that the process is running. The live verifier uses
isolated VM-like network namespaces with no physical NIC or default route,
queries mDNS, and validates a temporary HTTP response from the physical host.
It removes its temporary namespaces/TAPs/listener. Do not run simultaneous
verifiers. It is not a login to `devbox2` or a test of every host service.

The host's Avahi service must publish `azero.local` on `okrun0`; firewall rules
and service bind addresses still control access. Local TCP is unencrypted and
unauthenticated; use it only on the trusted LAN. Cloud transport uses mTLS.
Never put a CA private key or switch-server credential on this client.

## Automated regression tests

```bash
bash scripts/test-network-client.sh
sudo node web-switch/tests/network-service.test.js
sudo node web-switch/tests/network-service.test.js --auto
```

The unprivileged suite includes setup path/argument tests, automatic addressing,
client/router tests, and switch E2E checks. The privileged tests create temporary
units and test TAP traffic, address persistence/conflict recovery, crash restart,
and cleanup without replacing the production unit. Their isolated test addresses
and other constraints are documented in the README.

## Backup, restore, and credential rotation

- Keep any backup in an encrypted, access-controlled secret store outside Git;
  back up the protected bundle and, if identity continuity is required, host
  state. Backups are not created or exported automatically by this workflow.
- For the same host, restore the bundle using the explicit-path installer above.
  If restoring state, stop `okrun-network` first, restore its private directory
  and file permissions from the table, then start the service and reverify.
- A different machine needs its **own** host credential and fresh host state;
  do not clone another machine's identity/address.
- If a bundle might have leaked, have the issuing administrator reissue/revoke
  credentials. Deleting a file is not secure erasure of disk snapshots/backups
  and does not revoke a certificate. Rotate only with a working replacement
  and a coordinated revocation plan.
- The original checkout copy was group/world-readable (`0664`) before this
  cleanup. It was not Git-tracked at cleanup time. If untrusted local users or
  backups could have read it, treat it as potentially exposed and rotate it.
  No certificate revocation or history rewriting was performed here.
