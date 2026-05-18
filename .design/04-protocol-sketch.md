# okrun-switch Protocol Sketch

## Why this protocol

OkRun already has a direct bridge protocol, and okproxy already has a more general virtual socket protocol. The cloud switch should use the okproxy-style virtual socket framing because it gives us multipath, deduplication, keepalive, and reconnect semantics. The payload remains OkRun-specific: raw Ethernet frames.

## Frame header

All integer fields are big endian.

```text
streamId: UInt32
type: UInt8
seqNo: UInt32
payloadLength: UInt32
payload: bytes
```

Header size: 13 bytes.

## Frame types

```text
0x02 DATA
0x04 ERROR
0x05 INIT
0x06 PING
0x07 PONG
0x09 RESET_SEQ
```

Reserved for future compatibility with okproxy:

```text
0x01 HEADERS
0x03 FIN
0x08 UPGRADE
```

## Streams

`streamId = 0` is reserved for connection control.

`streamId = 1` carries the OkRun Ethernet bus. For MVP, one stream is enough because the payload is datagram-like Ethernet frames, not concurrent byte streams.

## INIT

The client must send INIT first.

Client INIT:

```json
{
  "protocol": "okrun-switch/1",
  "nodeID": "86F2C3C1-5D15-4E78-90E6-A6258D35B617",
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

Server INIT ACK:

```json
{
  "protocol": "okrun-switch/1",
  "maxFrameSize": 70000,
  "maxConnectionsPerHost": 8,
  "keepaliveIntervalMs": 10000,
  "keepaliveTimeoutMs": 25000
}
```

Rejects:

- unsupported protocol version
- bad network identifier
- bad UUID
- oversized max frame size
- DHCP range overlap
- same node ID attached to different certificate identity
- revoked certificate

Where possible, the server sends ERROR before closing.

## DATA

Payload is one complete Ethernet frame.

Rules:

- Payload must be non-empty.
- Payload must be less than or equal to negotiated max frame size.
- Server parses only destination and source MACs from the first 12 bytes.
- The full payload is forwarded unchanged.

## Sequence numbers and dedup

Every DATA frame gets a per-sender monotonic `seqNo`.

Multipath senders duplicate the exact same encoded DATA frame over every active real socket. Receivers keep one dedup window per remote host and stream.

RESET_SEQ payload:

```json
{
  "streams": [1]
}
```

RESET_SEQ clears the receiver's incoming dedup window for listed streams. It does not reset outbound counters.

## Keepalive

Either side may send PING on `streamId = 0`.

The peer must respond with PONG on `streamId = 0`.

Suggested timings:

- server PING every 10s, timeout after 25s
- single Swift socket PING every 3s, timeout after 10s
- multipath Swift sockets PING every 15s, timeout after 45s

These values mirror okproxy and can be negotiated in INIT ACK later.

## Error payload

MVP can use UTF-8 strings for ERROR payloads. Prefer JSON once the Swift status layer is wired.

```json
{
  "code": "dhcp_range_overlap",
  "message": "DHCP range overlaps active host in network okrun"
}
```

## Compatibility with direct bridge

The direct host-to-host bridge can keep `PrivateNetworkBridgeMessage`.

The cloud switch path should not tunnel the direct bridge protocol wholesale. It only needs:

- INIT values equivalent to direct bridge hello fields.
- DATA payloads containing raw Ethernet frames.

That keeps the cloud switch protocol small and lets the direct bridge remain stable.

