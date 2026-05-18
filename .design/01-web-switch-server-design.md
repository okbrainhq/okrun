# web-switch Server Design

## Summary

`web-switch` is a cloud layer-2 relay for OkRun private networks. It accepts outbound mTLS connections from hosts and switches raw Ethernet frames between hosts in the same named network.

The server should be implemented under `web-switch` and tested independently before Swift integration.

## Directory shape

```text
web-switch/
  package.json
  src/
    index.js
    protocol.js
    tls-server.js
    switch-fabric.js
    host-session.js
    ca.js
  bin/
    okrun-switch-ca.js
  scripts/
    certs/
      generate-local.sh
      issue-host.sh
      revoke-host.sh
    deploy/
      setup-server.sh
      setup-server-remote.sh
  tests/
    e2e/
      setup.js
      test-mtls.js
      test-init.js
      test-switching.js
      test-multipath.js
      test-dhcp.js
      run.js
```

`ca.js` can be adapted from okproxy for local test certs and revocation support. Production deployments can point at an externally managed CA directory.

## Operator commands

The server should be easy to operate from `web-switch`:

```bash
npm run ca -- init
npm run ca -- issue-server --hostname switch.example.com --output ./.certs/server
npm run ca -- issue-host --name arun-mac --output ./.certs/hosts/arun-mac
npm run ca -- list
npm run ca -- revoke --serial 42
npm run ca -- print-host-bundle --input ./.certs/hosts/arun-mac
npm run dev
npm test
```

Deploy:

```bash
cp .deploy.switch.example .deploy.switch
./scripts/deploy/setup-server.sh deploy@switch.example.com --upload-certs
```

`.deploy.switch` should mirror okproxy's `.deploy.server` style:

```bash
HOSTNAME=switch.example.com
REPO_URL=https://github.com/okbrainhq/okrun.git
SWITCH_TLS_PORT=9443
SWITCH_STATUS_PORT=8080
DEPLOY_HOST=deploy@switch.example.com
```

## TLS and auth

The TLS listener follows okproxy's server posture:

- `requestCert: true`
- `rejectUnauthorized: true`
- `minVersion: "TLSv1.2"` or TLS 1.3 when available
- configured server key/cert
- configured CA cert
- CRL check by client certificate serial

MVP identity:

- `clientSerial = socket.getPeerCertificate().serialNumber`
- `clientFingerprint = socket.getPeerCertificate().fingerprint256`
- `hostID = INIT.nodeID`

Admission rule for MVP:

- Any non-revoked client certificate signed by the configured CA may connect.
- The server logs `clientSerial`, `hostID`, and `networkIdentifier`.

Stronger follow-up:

- Optional allowlist file mapping certificate serial/fingerprint to allowed networks.
- Optional display name for status only.

## Certificate CLI

`bin/okrun-switch-ca.js` should be an okproxy-style CA helper backed by OpenSSL for local/dev and simple team deployments.

Commands:

```text
init [--ca-dir <dir>]
issue-server --hostname <host> [--output <dir>] [--ca-dir <dir>]
issue-host --name <name> [--output <dir>] [--ca-dir <dir>]
print-host-bundle --input <dir>
revoke --serial <serial> [--ca-dir <dir>]
list [--ca-dir <dir>]
```

Generated files:

```text
.ca/
  ca-key.pem
  ca-cert.pem
  issued.txt
  crl.txt
  serial-counter.txt
.certs/server/
  server-key.pem
  server-cert.pem
.certs/hosts/<name>/
  ca-cert.pem
  client-cert.pem
  client-key.pem
  okrun-switch-bundle.json
```

`print-host-bundle` should print a copy/paste-safe JSON block:

```json
{
  "server": "switch.example.com:9443",
  "caCertPem": "-----BEGIN CERTIFICATE-----\n...\n-----END CERTIFICATE-----\n",
  "clientCertPem": "-----BEGIN CERTIFICATE-----\n...\n-----END CERTIFICATE-----\n",
  "clientKeyPem": "-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----\n"
}
```

The private key must be generated with file mode `0600`; scripts should avoid printing server private keys.

## Deployment scripts

`scripts/deploy/setup-server.sh` responsibilities:

- Read `.deploy.switch`.
- Validate `HOSTNAME` and `REPO_URL`.
- Accept optional `DEPLOY_HOST` and `SSH_PORT`.
- Copy `setup-server-remote.sh` to the remote host.
- With `--upload-certs`, upload server cert/key, CA cert, and CRL to `/opt/okrun-switch/certs`.
- Run the remote setup script with escaped arguments.

`scripts/deploy/setup-server-remote.sh` responsibilities:

- Install Node.js 20+ when missing.
- Create `/opt/okrun-switch`.
- Clone or update the repo.
- Run `npm install` or `npm ci` inside `web-switch`.
- Write `/etc/systemd/system/okrun-switch.service`.
- Configure environment variables for TLS and status ports.
- Start and enable the service.
- Print `systemctl status okrun-switch` and log hints.

Default remote paths:

```text
/opt/okrun-switch/app
/opt/okrun-switch/certs/server-cert.pem
/opt/okrun-switch/certs/server-key.pem
/opt/okrun-switch/certs/ca-cert.pem
/opt/okrun-switch/certs/crl.txt
```

## Protocol

Use the okproxy 13-byte frame header so the multipath virtual socket can be reused.

```text
offset  size  field
0       4     streamId, UInt32 BE
4       1     type
5       4     seqNo, UInt32 BE
9       4     payloadLength, UInt32 BE
13      N     payload
```

Frame types:

```text
0x02 DATA       raw Ethernet frame payload
0x04 ERROR      UTF-8 or JSON error payload
0x05 INIT       JSON handshake and ACK
0x06 PING       keepalive
0x07 PONG       keepalive response
0x09 RESET_SEQ  JSON sequence-window reset
```

Rules:

- Control frames use `streamId = 0` and `seqNo = 0`.
- Ethernet DATA frames use `streamId = 1`.
- The sender assigns monotonically increasing sequence numbers to DATA frames.
- The receiver deduplicates DATA by source host and stream using a 128-bit sliding window.
- Max Ethernet payload accepted by the switch should be `70_000` bytes initially, matching OkRun's current bridge safety limit.

INIT payload:

```json
{
  "protocol": "okrun-switch/1",
  "nodeID": "uuid-string",
  "networkIdentifier": "okrun",
  "interface": "default",
  "maxFrameSize": 70000,
  "dhcpRange": {
    "cidr": "10.77.0.0/24",
    "rangeStart": "10.77.0.20",
    "rangeEnd": "10.77.0.200"
  },
  "capabilities": ["ethernet-frame", "multipath-v1"]
}
```

INIT ACK payload:

```json
{
  "protocol": "okrun-switch/1",
  "maxFrameSize": 70000,
  "keepaliveIntervalMs": 10000,
  "keepaliveTimeoutMs": 25000,
  "networkMemberCount": 2
}
```

## Host sessions

`HostSession` represents one authenticated OkRun host inside one private network.

Fields:

- `networkKey`
- `nodeID`
- `clientSerial`
- `dhcpRange`
- `connections: Map<interfaceName, TLSSocket>`
- `incomingDedupWindow`
- `outgoingSeqCounter`
- `lastSeenAt`

Connection behavior:

- A second connection with the same `clientSerial`, `nodeID`, `networkIdentifier`, and `interface` replaces the old connection.
- A connection with the same `nodeID` but different certificate identity is rejected.
- When the last connection closes, the host leaves the network and its MAC entries are removed.

## Switch fabric

`SwitchFabric` owns all active networks.

Per network:

- `hosts: Map<nodeID, HostSession>`
- `macTable: Map<macAddress, { nodeID, updatedAt }>`
- `dhcpRanges: Map<nodeID, range>`

On incoming DATA:

1. Parse Ethernet destination and source MAC if frame length is at least 14 bytes.
2. Learn `sourceMAC -> sourceHost`.
3. If destination is broadcast or multicast, forward to every other host.
4. If destination is known unicast and not on the source host, forward only to that host.
5. If destination is unknown unicast, flood to every other host.
6. If destination is known on the source host, drop it.

The server is a relay, not a router:

- It never forwards frames across different `networkIdentifier` values.
- It never rewrites Ethernet frames.
- It never runs DHCP itself in MVP.

## DHCP overlap guard

The current direct bridge rejects peers with overlapping DHCP ranges. The cloud switch should keep the same safety check.

On INIT:

- If `dhcpRange` is absent, allow the host but mark DHCP status unknown.
- If present, compare with every active host in the same network.
- Reject the new host when ranges overlap.
- Include a clear ERROR frame before closing where possible.

This protects the existing per-host DHCP model until a centralized allocator is designed.

## Keepalive and cleanup

Use okproxy's timing as the baseline:

- Server PING every 10s.
- Close connection when no PONG for 25s.
- INIT must arrive within 10s.
- MAC table entries expire after 5 minutes without source refresh.

When a host leaves:

- Remove all MAC entries owned by that host.
- Remove its DHCP range from the active network state.
- If the network has no hosts, remove the network object.

## Observability

MVP status is enough for E2E and operators:

- startup log with bind host/port and cert paths
- connect/disconnect log with serial, nodeID, interface, network
- reject logs for auth, protocol, DHCP overlap, oversized frame, bad INIT
- periodic or endpoint status with network count, host count, connection count

Optional endpoint:

```text
GET /healthz -> 200 ok
GET /status  -> JSON without secrets
```

The TLS switch port and HTTP status port can be separate to avoid mixing protocols.

## Server-only E2E contract

Tests should use synthetic host clients that speak the frame protocol directly.

Core helpers:

- Generate temp CA, server cert, two client certs, and one untrusted client cert.
- Start `web-switch` on unused ports.
- Connect clients over TLS with cert/key/CA.
- Send INIT and wait for ACK.
- Send raw Ethernet frames and assert received payloads.

The server is considered ready for Swift work when all server-only tests pass reliably with `npm test` from `web-switch`.
