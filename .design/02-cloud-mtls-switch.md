# Cloud mTLS Switch

## Objective

Build a small cloud relay that accepts authenticated host connections and forwards raw Ethernet frames among hosts in the same OkRUn private network.

The relay is intentionally not an IPAM service and not a DHCP server. It should behave like a scoped Ethernet hub first, with only the minimum state needed to authenticate connections and avoid sending packets to unrelated networks.

## Placement

Preferred initial placement:

```text
cloud/relay/
  package.json
  apps/server/index.js
  packages/frame-protocol/index.js
  tests/e2e/
```

This mirrors the `okproxy` shape and allows fast local E2E with Node 20 and no third-party dependencies. If we later split it into its own repo, the directory can move cleanly.

## okproxy Patterns To Reuse

- `node:tls` mTLS server with `requestCert: true` and `rejectUnauthorized: true`.
- Local CA CLI for issuing server and host client certs.
- INIT handshake before data frames.
- PING/PONG keepalive.
- Max frame size checks before allocation.
- Reconnect-friendly session handling.
- E2E setup that creates temporary CA/cert directories.

## Protocol

Use a small binary frame protocol inspired by okproxy. Ethernet is datagram-like, so no HTTP stream semantics are needed.

Header:

```text
4 bytes  network-local sequence number, big endian
1 byte   frame type
4 bytes  reserved or flags
4 bytes  payload length, big endian
N bytes  payload
```

Frame types:

| Type | Purpose |
|---|---|
| `0x01 INIT` | Host handshake JSON. |
| `0x02 ETHERNET` | Raw Ethernet frame payload. |
| `0x03 PING` | Keepalive request. |
| `0x04 PONG` | Keepalive response. |
| `0x05 ERROR` | Protocol or policy error. |
| `0x06 PEER_EVENT` | Optional peer count/status update. |

INIT payload:

```json
{
  "protocol": "okrun-vnet/1",
  "hostId": "host-public-key-fingerprint",
  "networkId": "team-a",
  "poolCidr": "10.77.12.0/24",
  "maxFrameSize": 65535
}
```

For phase 2, `poolCidr` may be omitted. Phase 3 uses it for duplicate-pool rejection.

## Server Behavior

1. Accept TLS only from clients with valid certificates signed by the configured CA.
2. Reject revoked certificates.
3. Require INIT as the first protocol frame.
4. Register the connection under `networkId`.
5. Forward each `ETHERNET` payload to all other sessions with the same `networkId`.
6. Never echo to the origin session.
7. Never forward frames across network IDs.
8. Enforce max frame size.
9. Send periodic PING and close sessions that do not PONG.

The server does not parse Ethernet, ARP, IP, DHCP, TCP, or UDP.

## Duplicate Pool Check

Phase 3 needs one small policy check:

- If a session joins `networkId=team-a` with `poolCidr=10.77.12.0/24`, a second live session in the same network cannot claim the same `poolCidr`.
- The server returns `ERROR duplicate_pool` and closes the second session.

This is still not IP allocation. Hosts choose their own pools; the server only rejects exact live conflicts.

## Security Model

- mTLS authenticates every host connection.
- Server certificate is validated by the host client.
- Client certificate identity becomes the default `hostId`, preferably using the public-key fingerprint rather than certificate CN.
- Network membership can initially be configured by shared CA plus `networkId`.
- Later hardening can add a signed allowlist mapping certificate fingerprints to network IDs.

## E2E Test Plan

1. Certificate tests.
   - Generate temporary CA.
   - Generate server cert for `localhost`.
   - Generate two host client certs.
   - Assert valid clients connect.
   - Assert no-cert, wrong-CA, expired, and revoked clients are rejected.

2. Protocol tests.
   - Reject data before INIT.
   - Reject invalid INIT JSON.
   - Reject oversized frames.
   - PING/PONG keeps a connection alive.
   - Missing PONG closes a connection.

3. Forwarding tests.
   - Host A and Host B join the same `networkId`; A sends an Ethernet payload; B receives exact bytes.
   - Host A does not receive its own frame.
   - Host C in a different `networkId` receives nothing.
   - Three hosts in one network all receive broadcast-style forwarded bytes except origin.

4. Pool policy tests.
   - Two hosts with different pools in the same network are accepted.
   - Two hosts with the same pool in the same network: second is rejected.
   - Same pool in different network IDs is accepted.

5. Local run script.
   - Add `scripts/e2e-cloud-relay.sh`.
   - Start relay on `127.0.0.1:0`.
   - Run the above tests without external network access.

## Acceptance Criteria

- The relay can be run locally and in a cloud VM.
- It forwards raw bytes exactly and only within a network ID.
- It requires mTLS.
- It has no DHCP or IP allocation code.
- E2E covers auth, forwarding, no-echo, isolation, keepalive, and duplicate-pool rejection.
