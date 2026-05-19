# WebSwitch & LocalSwitch Reliability Review

## Architecture Summary

The system is a virtual Layer-2 Ethernet switch over TCP/TLS. Two server types feed into the same `SwitchFabric`:

- **SwitchTLSServer** (`tls-server.js:67`) — TLS-encrypted for remote hosts, mTLS auth, CRL checking. Identity kind: `tls`.
- **SwitchLocalServer** (`tls-server.js:169`) — Plain TCP for local/trusted, no auth. Identity kind: `local`.

Both share a single `SwitchFabric`, so local and remote hosts in the same network can exchange frames.

## Routing Logic (server: `switch-fabric.js:431-456`)

1. **MAC learning** — Source MAC extracted from frames >= 14 bytes, stored in MAC table (MAC -> nodeID).
2. **Unicast routing** — Non-multicast destination MAC looked up in MAC table. If found, forward to single target. If not found, fall through to flood.
3. **Broadcast/flood** — Multicast/broadcast or unknown unicast forwarded to all hosts except source.
4. **MAC table expiry** — Entries expire after 5 minutes (`macTtlMs`).

## Reconnect & Connection Handling

### Server Side (Node.js)

- **Keepalive**: TLS PING every 10s, timeout 25s. Local PING every 500ms, timeout 1500ms.
- **Teardown** (`tls-server.js:455-473`): On socket close, connection removed from HostSession. If host has other interfaces, MEMBER_UPDATE broadcast (no data loss). If zero connections remain, HostSession deleted, MAC table purged, MEMBER_UPDATE broadcast.
- **Interface replacement** (`host-session.js:47-58`): Same nodeID + interface name reconnect kills old socket, keeps session (MAC table, dedup state preserved).
- **Multipath delivery** (`host-session.js:101-124`): Frames sent to all active connections of a host. If one drops, others keep delivering.

### Client Side (Swift)

- **Exponential backoff reconnect** (`PrivateNetworkSwitch.swift:613-614`): 0.5s initial, 3s max, doubling each attempt. Resets on successful INIT ACK.
- **Network path monitoring** (`PrivateNetworkSwitch.swift:777-859`): `NWPathMonitor` detects Wi-Fi/Ethernet changes. Immediate reconnect on path satisfied. Suspends reconnect when path unsatisfied.
- **Write buffering** (`PrivateNetworkSwitch.swift:1105-1126`): Frames queued during disconnect (up to 512), flushed after INIT ACK.
- **Connection timeouts**: 25s TLS / 3s local connection timeout. 10s INIT response timeout. Client-side keepalive for local connections only.
- **Dedup**: `SwitchDedupWindow` on incoming frames (bitmap sliding window, 128 slots).

## What Works Well

1. **Reconnect with exponential backoff** — Handles transient failures gracefully.
2. **Network path monitoring** — Immediate reconnect on path change, avoids futile reconnects when offline.
3. **Write buffering during reconnect** — Prevents frame loss during brief reconnects.
4. **Seamless interface replacement** — Same nodeID+interface reconnect preserves session state.
5. **Multipath dedup on both sides** — Server deduplicates per HostSession, Swift client deduplicates per VirtualSwitchSocket.
6. **Connection timeouts on both ends** — Server (init + keepalive), client (connection + init + client keepalive).

## Edge Cases & Potential Issues

### 1. Pending write buffer has no age limit

**File**: `PrivateNetworkSwitch.swift:1108`

Frames buffered during disconnect are capped at 512 entries but have no TTL. If the server is down for hours, stale frames will be flushed on reconnect. This could cause weird behavior (stale ARP responses, TCP retransmission confusion).

**Consideration**: Add a max buffer age or clear the buffer on network path change.

### 2. Swift client does not send keepalives for TLS connections

**File**: `PrivateNetworkSwitch.swift:1203`

`startClientKeepaliveIfNeeded` only activates for `case .none` (local switch). For TLS, the server sends keepalives, but the client has no independent way to detect a half-open TCP where the server's PONG is lost but the session appears alive.

The server will kill its end after its keepalive timeout, triggering client reconnect — so this mostly works. But the client relies on TCP/NWConnection failure detection, which can be slow.

**Consideration**: Client could send its own PINGs for TLS too, using the server-advertised `keepaliveIntervalMs`/`keepaliveTimeoutMs` from the INIT ACK.

### 3. Local switch `canSendFrames()` requires >1 active connection

**File**: `PrivateNetworkSwitch.swift:1594-1595`

For `connectedOnly` route availability (local switch), `canSendFrames()` returns true only when `activeConnections > 1`. A local switch that's the only peer won't forward frames. Appears intentional (need 2+ members for traffic to go anywhere), but it's a subtle gotcha.

### 4. Router MAC table never expires (client side)

**File**: `PrivateNetworkRouter.swift:57`

`localMACs` and `remoteRoutes` are never expired. If a VM's MAC address changes (guest OS reinstall), old entries stay forever. The server expires MACs after 5 minutes, but the client-side router doesn't.

**Consideration**: Add a TTL to `localMACs` and `remoteRoutes`, or clear them on reconnect.

### 5. No dedup on the Swift -> Server send path

The `VirtualSwitchSocket` deduplicates incoming frames from the server. But when the client sends via `send()` (`PrivateNetworkSwitch.swift:592-609`), there's no send-side dedup. If the same Ethernet frame arrives from two VM runtimes simultaneously, it could be sent twice with different seqNos.

The server's `DedupWindow` won't catch this (different seqNos), so the receiving client's dedup handles it. Functionally correct but wastes bandwidth.

### 6. Server ERROR frame triggers infinite reconnect loop

**File**: `PrivateNetworkSwitch.swift:1052-1054`

When the server sends an ERROR frame (e.g., `certificate_revoked`), the client logs `.rejected` but calls `closeConnection` with `retry: true`. A permanently revoked certificate causes infinite reconnect loops (0.5-3s cycle forever). `reportFinalFailure: false` prevents overwriting status, but the reconnect loop still runs.

**Consideration**: For terminal errors (`certificate_revoked`, `same_node_different_certificate`), set `retry: false` or add a max retry count for rejected state.

### 7. `handleState` stale connection handling (correct)

**File**: `PrivateNetworkSwitch.swift:740`

The `stateUpdateHandler` checks `connection === self.connection` to avoid stale events. If `closeConnection` sets `self.connection = nil` before the old connection's `.cancelled` fires, it falls into the else branch (harmless nil assignment). This is correctly handled.

### 8. `queue.sync` potential deadlock risk

**File**: `PrivateNetworkSwitchTransport.swift:1570-1573`, `PrivateNetworkRouter.swift:237-242`

`canSendFrames()` and `statusSnapshot()` use `queue.sync` without checking whether already on the queue. The router's `runOnQueue` guards against this with `DispatchQueue.getSpecific`, but the transport doesn't. Currently no internal callers trigger this, but it's fragile.

**Consideration**: Add the same `getSpecific` guard to `PrivateNetworkSwitchTransport`.

## Summary

The design is reliable for production use. Reconnect, multipath dedup, write buffering, and network path monitoring work together well. Priority items to address:

| Priority | Issue | Effort |
|----------|-------|--------|
| High | #6 Infinite reconnect on rejected cert | Small — add `retry: false` for terminal errors |
| Medium | #1 Stale write buffer age | Small — add max age or clear on path change |
| Low | #4 Client-side MAC table never expires | Small — add TTL or clear on reconnect |
| Low | #8 `queue.sync` deadlock guard | Small — add `getSpecific` check |
| Low | #2 Client-side TLS keepalive | Medium — reuse server-advertised intervals |
