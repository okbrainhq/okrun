# Distributed Private Network Roadmap

## Goal

Build OkRUn private networking into a distributed Layer 2 network that can span multiple Macs while keeping the cloud service intentionally simple. The host app owns the VM private Ethernet bus today, so the core path is:

1. Tap raw private-NIC Ethernet frames in the host app.
2. Add host-side DHCP so guests no longer need static private IPs.
3. Add an mTLS cloud relay that groups hosts by network and forwards frames.
4. Connect host apps to that relay and enforce per-host IP pools.
5. Replace configured pools with distributed pool selection.

The cloud service should not allocate IPs, run DHCP, inspect guest payloads, or own network policy beyond authentication, network membership, and basic duplicate-pool rejection while that check is useful.

## Host Config Ownership

DHCP, cloud relay, certificate, and distributed pool settings are host-app policy, not guest/project policy. They should live under the user's OkRUn home, `~/.okrun`, and be keyed by private network identifier.

Today the app uses `~/.okrun` as a registry file. Before adding host-network config, migrate that storage to a directory:

```text
~/.okrun/
  registry.json
  private-networks.json
  certs/
  state/
    private-networks/
```

Compatibility requirements:

- If `~/.okrun` is the old registry file, migrate it to `~/.okrun/registry.json` atomically.
- Keep `OKRUN_REGISTRY_PATH` for existing tests and scripts.
- Add `OKRUN_HOME` for tests that need an isolated host app config directory.
- Keep `okrun-vm.json` limited to VM-local hardware intent, for example `privateNetwork.enabled` and `privateNetwork.identifier`.

## Current Codebase Facts

- Private networking is already host-owned through `VZFileHandleNetworkDeviceAttachment` in `NetworkDeviceFactory.makePrivateNetworkDevice`.
- `PrivateNetworkRuntime.readGuestFrames()` receives raw frames from one VM private NIC.
- `PrivateNetworkRuntime.readPeerFrames()` injects frames from another OkRUn local peer into that VM.
- Local VM-to-VM forwarding uses Unix datagram sockets under `/tmp/okrun-vnet/<identifier>`.
- NAT networking is separate and remains out of scope.
- Guest tools currently support static private IP installation through `--private-ip`.

## okproxy Ideas To Reuse

The public `okbrainhq/okproxy` repo is a good reference for the cloud transport shape:

- Node 20 with zero third-party dependencies.
- mTLS using `node:tls`, a local CA, client/server cert issuance, and certificate revocation.
- Small binary frame protocol with INIT, PING, PONG, DATA, and ERROR style frames.
- Explicit INIT handshake before data frames.
- Keepalive, reconnects, frame-size limits, and backpressure handling.
- E2E tests that generate temporary CA/cert material and run local server/client processes.

OkRUn should borrow those patterns, but the payload is Ethernet frames rather than HTTP tunnel streams.

## Milestones

| Phase | Design | Outcome |
|---|---|---|
| 1 | `01-host-dhcp-and-guest-tools.md` | Local host DHCP for private NICs, guest tools install DHCP config, README updated. |
| 2 | `02-cloud-mtls-switch.md` | A local/cloud mTLS relay that forwards raw Ethernet frames by network ID. |
| 3 | `03-host-cloud-link.md` | Host app connects private networks to the relay, with configured per-host DHCP pools and duplicate-pool rejection. |
| 4 | `04-distributed-dhcp.md` | Hosts choose pools deterministically, detect collisions, and operate without manually assigned pools. |

## Core Design Rules

- Keep Layer 2 as the base abstraction. IP parsing is allowed for DHCP, metrics, and optional filtering, but forwarding is Ethernet-frame based.
- Keep the NAT NIC untouched. The private NIC must not become the guest default route unless explicitly added later.
- Make the cloud relay scoped, not global. A frame from `networkId=team-a` must never reach `networkId=team-b`.
- Do not echo frames back to the sender.
- Prefer local-first behavior. If cloud is down, local VMs on the same host should still communicate.
- Make every phase independently testable on one development Mac.

## E2E Testing Strategy

Each phase needs both cheap deterministic tests and a full local E2E:

- Parser/protocol unit tests for DHCP, Ethernet frames, mTLS frames, pool selection, and validators.
- Host config migration tests for old-file `~/.okrun` to directory-backed config.
- Script tests for guest-tools output using the existing fake-root pattern in `scripts/e2e-guest-tools-installer.sh`.
- Headless VM tests using the existing Alpine initramfs flow in `scripts/prepare-e2e-linux.sh`.
- Multi-host simulation on one Mac by adding an `OKRUN_VNET_ROOT` override so two host processes do not share the same Unix socket bus unless the cloud link connects them.
- Local cloud tests that start the relay on `127.0.0.1`, generate temporary certs, run host clients, and assert packet delivery.

## Open Questions

- Should the cloud relay live in this repo under `cloud/relay`, or in a separate repo modeled on `okproxy`?
- Should private NIC MAC addresses be explicitly deterministic from the project machine identifier, or should DHCP leases tolerate Virtualization.framework-generated MACs?
- Do we want a packet viewer and PCAP export before cloud networking, or after the first relay E2E?
