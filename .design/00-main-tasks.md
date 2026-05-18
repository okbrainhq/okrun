# okrun-switch Main Tasks

## Goal

Build `okrun-switch` as a cloud-hosted switch for OkRun private networks. Hosts connect outbound to the cloud VM over mTLS, join a named private network, and exchange raw Ethernet frames through the server so VMs on different hosts can communicate over the internet.

This is not an HTTP tunnel like okproxy. The useful pieces from okproxy are:

- mTLS server authentication and client certificate authentication.
- Certificate serial and revocation checks.
- A small binary frame protocol with INIT, PING, PONG, DATA, ERROR, and RESET_SEQ frames.
- A virtual socket that can sit on top of multiple real TLS sockets, duplicate outbound traffic, and deduplicate inbound traffic by sequence number.
- E2E-first development against a standalone server before wiring it into a larger app.

The useful pieces from OkRun are:

- `PrivateNetworkRuntime`, which exposes a VZ file-handle network attachment and emits raw Ethernet frames.
- `PrivateNetworkBridgeMessage`, which already encodes hello and frame messages for direct host-to-host bridging.
- `PrivateNetworkBridge`, which already learns local MACs, rejects self connections and overlapping DHCP ranges, and injects remote frames into local guests.
- `HostNetworkConfigStore`, `PrivateNetworkRuntimeRegistry`, and the existing private network config path at `~/.okrun/private-networks.json`.

## Task 1: Standalone web-switch server

Create a new `web-switch` directory containing a Node.js server with zero or minimal runtime dependencies, matching okproxy's deployment style.

Responsibilities:

- Listen on a TLS port, require client certificates, and trust only the configured CA.
- Reject revoked client certificate serials via a CRL file.
- Require an INIT frame before accepting DATA frames.
- Group authenticated hosts by network identifier, certificate identity, and host node ID.
- Allow multiple real TLS sockets per host identity, one per interface or connection name.
- Present one logical host socket to the switch fabric.
- Learn Ethernet source MAC addresses and forward frames as a layer-2 switch.
- Flood broadcast, multicast, and unknown unicast frames to all other hosts in the same network.
- Forward known unicast frames only to the host that owns the destination MAC.
- Reject hosts with overlapping DHCP ranges inside the same private network.
- Expose simple health and status endpoints or stdout status for E2E and deployment checks.

Implementation notes:

- Reuse okproxy's 13-byte frame header shape for the switch protocol.
- Keep OkRun Ethernet frames as opaque payloads.
- Keep stream semantics simple: all private-network Ethernet traffic can use `streamId = 1`; control frames use `streamId = 0`.
- Keep direct LAN bridge protocol compatibility separate. The cloud switch adapter can translate between OkRun runtime frames and switch DATA frames; it does not need to preserve direct TCP bridge framing over the internet.

## Task 2: Server-only E2E tests

Before changing Swift, prove the server with black-box Node tests.

Required test coverage:

- Valid mTLS client can INIT and join.
- Missing client certificate is rejected.
- Client certificate signed by another CA is rejected.
- Revoked client certificate is rejected.
- DATA before INIT closes the connection.
- Oversized frames close the connection.
- Two hosts on the same network exchange broadcast frames.
- Learned unicast goes only to the target host.
- Unknown unicast floods to peers except the sender.
- Hosts on different networks are isolated.
- Duplicate DATA frames from multipath sockets are delivered once.
- Same host/interface reconnect replaces the stale socket.
- Overlapping DHCP range is rejected.
- Keepalive timeout removes dead hosts and cleans MAC table entries.

The server E2E suite should run from `web-switch` without launching OkRun or a VM.

## Task 3: Swift protocol and virtual socket

Implement the switch protocol in Swift after the server is stable.

Core Swift types:

- `SwitchFrameProtocol`: encode/decode the 13-byte frame header and partial reads.
- `SwitchFrameType`: INIT, DATA, ERROR, PING, PONG, RESET_SEQ.
- `SwitchDedupWindow`: Swift port of okproxy's 128-bit sliding dedup window.
- `RealSwitchSocket`: one TLS connection to the server, using client identity and CA trust.
- `VirtualSwitchSocket`: one logical socket over one or more `RealSwitchSocket` instances.
- `PrivateNetworkSwitchClient`: sends INIT, keeps connection status, and emits raw Ethernet frames.

Start with a single default real socket, then keep the API shaped for multipath so additional interface-bound sockets can be added without changing OkRun integration.

## Task 4: OkRun integration

Wire the Swift client into OkRun's existing private-network runtime.

Integration points:

- Add `switch` config under each `HostPrivateNetworkConfig` in `~/.okrun/private-networks.json`.
- Extend `PrivateNetworkRuntimeRegistry` to retain a switch bridge alongside, or instead of, the existing direct LAN bridge.
- Prefer one remote transport mode for MVP to avoid accidental L2 loops: direct `bridge` or cloud `switch`.
- Add status reporting that mirrors the current bridge status pattern.
- Keep the guest-facing VM config unchanged: VMs still see the same private NIC.

Expected user config shape:

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
      "switch": {
        "enabled": true,
        "server": "switch.example.com:9443",
        "caCert": "/Users/me/.okrun/switch/ca-cert.pem",
        "clientCert": "/Users/me/.okrun/switch/client-cert.pem",
        "clientKey": "/Users/me/.okrun/switch/client-key.pem",
        "multipath": false
      }
    }
  }
}
```

## Task 5: Integrated E2E

After server-only E2E and Swift unit tests pass, add integration coverage.

Suggested sequence:

- Swift protocol unit tests for frame encoding, partial decoding, and dedup windows.
- Swift config tests for loading and validating `switch`.
- Loopback switch integration test using `PrivateNetworkRuntime` instances, not full VMs.
- Optional full VM E2E once the runtime bridge is stable.

## Task 6: Deployment and certificate scripts

Add deployment scripts under `web-switch/scripts` so a cloud VM can be prepared and updated with a few commands, following the okproxy style.

Required scripts:

- `web-switch/bin/okrun-switch-ca.js`: CA CLI for init, issue server cert, issue host/client cert, list certs, revoke certs, and print/paste bundles.
- `web-switch/scripts/deploy/setup-server.sh`: local orchestration script that reads `.deploy.switch`, copies the remote setup script, optionally uploads certs, and starts or updates the service.
- `web-switch/scripts/deploy/setup-server-remote.sh`: remote Debian/Ubuntu setup script that installs Node.js if needed, clones or updates the repo, writes a systemd service, opens firewall ports when available, and starts `okrun-switch`.
- `web-switch/scripts/certs/generate-local.sh`: one-command local dev CA + server + two host certs for E2E.
- `web-switch/scripts/certs/issue-host.sh`: issue a new OkRun host certificate bundle for copy/paste into the app.
- `web-switch/scripts/certs/revoke-host.sh`: revoke a host cert and refresh the server CRL.

Expected operator flow:

```bash
cd web-switch
npm run ca -- init
npm run ca -- issue-server --hostname switch.example.com --output ./.certs/server
npm run ca -- issue-host --name arun-mac --output ./.certs/hosts/arun-mac
./scripts/deploy/setup-server.sh deploy@switch.example.com --upload-certs
```

Expected host cert flow:

```bash
cd web-switch
npm run ca -- issue-host --name arun-mac --output ./.certs/hosts/arun-mac
npm run ca -- print-host-bundle --input ./.certs/hosts/arun-mac
```

The printed bundle should be friendly for the OkRun config UI paste section.

## Task 7: OkRun config UI certificate paste section

Update the OkRun Private Network config panel with a cloud switch section.

MVP UX:

- Enable Cloud Switch.
- Server field, for example `switch.example.com:9443`.
- Certificate mode segmented control: Paste or Files.
- Paste mode text areas for CA certificate, client certificate, and client private key.
- Save writes pasted PEM blocks into `~/.okrun/switch/<network-id>/` with restricted permissions and stores paths in `private-networks.json`.
- Files mode keeps the path-based config for power users and deployments.
- Status area shows certificate presence, expiry when parseable, and connection state.

This keeps the JSON config from becoming huge while still letting users copy/paste certs from a deployment console.

## Open decisions

- Certificate identity: use client cert serial for MVP, then optionally support certificate fingerprint or SAN/CN mappings.
- Network authorization: trust-CA-all-networks for MVP, or add server allowlist from day one.
- Certificate file format in Swift: the UI can accept pasted PEM and store it as files, but Network.framework TLS client identity may still need keychain import or PKCS#12 internally.
- Multipath on macOS: keep single-socket first unless interface binding is needed immediately.
- Server language: Node.js matches okproxy and keeps the test/deploy story simple.
