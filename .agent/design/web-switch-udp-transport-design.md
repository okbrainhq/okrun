# Web Switch UDP Accelerated Transport Design

**Created:** 2026-06-07 15:16 Asia/Colombo  
**Updated:** 2026-06-07 15:51 Asia/Colombo  
**Status:** Design v2; no implementation changes in this document.

## Goal

Add a faster internet transport for Web Switch while keeping the existing TCP/TLS implementation fully supported.

The new design uses:

- Existing TCP/TLS or mTLS connection as the control plane.
- New encrypted UDP data plane for Ethernet `DATA` frames.
- Backward-compatible negotiation so old clients and old servers continue to work.
- Pacing, congestion/backpressure, MTU discovery, and DoS limits so UDP does not become an unsafe firehose.

Local LAN switch behavior stays unchanged for now because current local performance is acceptable.

## Non-Goals

- No SSH-specific plaintext or auth-only shortcut. All internet UDP Ethernet frames remain encrypted and authenticated.
- No custom cipher design.
- No Web Switch retransmission layer for guest traffic.
- No replacement of the existing TCP/TLS server path.
- No QUIC dependency for the first production version.

## Current Situation

The Web Switch currently sends Ethernet frames through one TCP/TLS stream.

This is safe and compatible, but over the internet it can suffer from:

- TCP-over-TCP behavior when guest traffic is TCP.
- Head-of-line blocking.
- Higher latency under loss.
- Poor recovery behavior when packets are dropped or reordered.

UDP is a better fit for carrying virtual Ethernet frames because loss should be handled by the guest protocols, especially guest TCP. However, UDP needs explicit safety controls that TCP normally provides automatically:

- Congestion control / pacing.
- Backpressure.
- MTU handling.
- Replay protection.
- Fragment reassembly limits.
- Path/NAT health checks.

## Success Criteria

The UDP data plane should only be considered successful if it beats the existing TCP/TLS path under realistic internet conditions without increasing operational risk.

Suggested go/no-go targets:

- Under simulated WAN loss of `1%` to `2%`, UDP mode should reduce interactive SSH/session p95 latency by at least `20%` compared with the existing TCP/TLS data path.
- Under simulated WAN loss of `1%` to `2%`, UDP mode should improve sustained guest TCP throughput by at least `30%` compared with the existing TCP/TLS data path.
- On clean low-loss links, UDP mode should be no worse than TCP/TLS by more than `5%` for throughput or latency.
- Auto mode should fall back to TCP/TLS within `5s` when UDP is blocked during setup.
- Auto mode should fall back to TCP/TLS within `45s` when an established UDP path becomes unhealthy.
- Memory usage must stay bounded during packet loss, malicious fragments, and unauthenticated UDP floods.
- Old clients must continue working with new servers without behavior changes.

## High-Level Architecture

```text
Swift Client                         Node Web Switch Server
------------                         ----------------------
TCP/TLS control connection  <----->  Existing TLS server
UDP encrypted data plane    <----->  New dgram UDP socket
```

### Control Plane

The existing TCP/TLS connection remains responsible for:

- Client authentication.
- Certificate validation / mTLS.
- INIT and ACK handshake.
- Member updates.
- Keepalive.
- Errors.
- UDP capability negotiation.
- UDP session/key setup.
- UDP rekey coordination.
- UDP health/stat reports if needed.
- Fallback coordination.

### Data Plane

The new UDP path carries only Ethernet `DATA` frames and minimal UDP-path probes/keepalives.

UDP packets must be encrypted and authenticated. No raw Ethernet frames should be sent over the internet.

## Transport Modes

Add a client-side Web Switch transport option:

1. **TCP/TLS Compatibility**
   - Uses current behavior only.
   - Does not open UDP.
   - Best for maximum compatibility.

2. **UDP Accelerated**
   - Requires UDP negotiation and UDP probe success.
   - Uses encrypted UDP for Ethernet frames.
   - TCP/TLS remains open for control.
   - If UDP cannot be established, connection should fail with a clear error.

3. **Auto**
   - Starts with TCP/TLS control.
   - Attempts UDP acceleration.
   - Uses UDP when ready.
   - Falls back to TCP/TLS when UDP is blocked or fails.

Recommended defaults:

- Existing saved configs: `TCP/TLS Compatibility`
- New configs: `Auto`

## Swift UI Design

In the Web Switch configuration UI, add a picker/button labeled something like:

- **Data Transport**

Options:

- **Auto**
- **TCP/TLS Compatibility**
- **UDP Accelerated**

The selected value should be saved in the existing Web Switch configuration model.

Changing this option should require reconnecting the Web Switch session because transport negotiation happens during connection setup.

Status UI should show:

- `TCP/TLS`
- `UDP probing`
- `UDP Accelerated`
- `TCP/TLS fallback`
- `UDP unhealthy`
- `UDP failed`

Optional advanced UI/status fields:

- UDP payload MTU.
- Current UDP pacing rate.
- UDP loss estimate.
- UDP fallback reason.

## Server Compatibility Design

The Node server should support both old and new clients.

### Existing Clients

Old clients continue using only TCP/TLS.

They do not send UDP capability fields and should behave exactly as today.

### New Clients

New clients send optional capability information in INIT.

Example:

```json
{
  "protocol": "okrun-switch/1",
  "capabilities": ["ethernet-frame", "udp-data-v1"],
  "transportPreference": "auto"
}
```

Valid `transportPreference` values:

- `tcp`
- `udp`
- `auto`

The server ACK may include optional data-plane information.

Example:

```json
{
  "protocol": "okrun-switch/1",
  "dataPlane": {
    "selected": "udp",
    "udpPort": 9443,
    "sessionId": "base64url-session-id",
    "cipher": "aes-256-gcm",
    "mtu": 1200,
    "minMtu": 1200,
    "maxProbeMtu": 1450,
    "keyId": 1,
    "pacing": {
      "initialMbps": 10,
      "maxMbps": 0
    }
  }
}
```

If the server does not support UDP or UDP is disabled, it omits `dataPlane` or returns `selected: "tcp"`.

New clients must gracefully fallback when no UDP data plane is returned.

## UDP Security Model

UDP packets must use standard authenticated encryption.

Recommended primitives:

- Node.js: `node:dgram` + `node:crypto`
- Swift/macOS: Network.framework UDP + CryptoKit or Security framework
- Cipher: AES-256-GCM preferred if both sides support it cleanly
- Alternative: ChaCha20-Poly1305 if easier and available on both sides

Do not design a custom cipher.

All UDP Ethernet frames are encrypted, including SSH traffic. There is no SSH-only bypass.

## Key Establishment

Use the existing TLS/mTLS control connection to authenticate the peer and negotiate UDP session material.

Recommended flow:

1. Client connects via TCP/TLS/mTLS.
2. Server authenticates the client certificate as today.
3. Client sends INIT with UDP capability and preference.
4. Server creates a UDP session and returns session parameters.
5. Client and server exchange random nonces over the TLS channel.
6. Client and server derive UDP keys from those nonces and authenticated identities.
7. Separate keys are derived for each direction:
   - client-to-server
   - server-to-client
8. UDP probe validates that both sides can send and receive encrypted packets.

Use HKDF for key derivation.

Inputs should include:

- Client random.
- Server random.
- Session ID.
- Client identity / host ID.
- Server identity.
- Direction label.
- Protocol label, e.g. `okrun-switch udp-data-v1`.

## Key Rotation

Key rotation must be explicit, not vague.

Recommended rotation triggers per direction, whichever comes first:

- Soft rotation after `10 minutes`.
- Soft rotation after `1,000,000` UDP packets.
- Soft rotation after `1 GiB` of UDP ciphertext sent.

Hard safety limits per direction:

- Hard expire after `30 minutes`.
- Hard expire after `4,000,000` UDP packets.
- Hard expire after `4 GiB` of UDP ciphertext sent.

Rotation flow:

1. Rekey is initiated over the existing TCP/TLS control channel.
2. New client/server nonces are exchanged over TCP/TLS.
3. New per-direction UDP keys are derived with HKDF.
4. New keys receive a new `keyId`.
5. UDP senders switch to the new `keyId` after both sides acknowledge over TCP/TLS.
6. Receivers accept old and new `keyId` values during a `60s` overlap window.
7. Old keys are destroyed after the overlap window or when their hard limit is reached.

Rules:

- Never reuse packet numbers with the same key.
- Packet numbers may reset only when `keyId` changes and the actual AEAD key changes.
- Maintain replay windows independently per `keyId`.
- If rekey fails in Auto mode, fall back to TCP/TLS before the hard limit.
- If rekey fails in UDP Accelerated mode, mark the session failed before the hard limit.

## UDP Packet Format

Conceptual packet fields:

```text
magic/version
sessionId
keyId
flags
packetNumber
fragmentId
fragmentIndex
fragmentCount
ciphertext
authTag
```

### Required Fields

- `version`: UDP data-plane protocol version.
- `sessionId`: identifies the active UDP session.
- `keyId`: supports key rotation.
- `packetNumber`: unique per direction and key.
- `flags`: identifies packet type and fragmentation.
- `ciphertext`: encrypted Ethernet frame, fragment, probe, or keepalive payload.
- `authTag`: AEAD authentication tag.

### AEAD Nonce Rule

Never reuse the same AEAD nonce with the same key.

A safe design:

- Per-direction key.
- Monotonic packet number.
- Nonce derived from packet number plus fixed per-session nonce prefix.

## UDP Packet Types

Suggested UDP packet types:

- `PROBE`
- `PROBE_ACK`
- `DATA`
- `FRAGMENT`
- `KEEPALIVE`
- `KEEPALIVE_ACK`
- `PMTU_PROBE`
- `PMTU_PROBE_ACK`

Keep these minimal. Complex control messages, including rekey negotiation, should remain on TCP/TLS.

## Congestion Control, Pacing, and Backpressure

This is required. UDP must not send frames as an unbounded firehose.

### Sender Pacing

Every UDP sender should have a per-session pacer.

Recommended design:

- Token-bucket pacer per remote session.
- Pacer accounts for encrypted UDP packet size, including UDP/IP overhead estimate.
- Initial pacing rate: `10 Mbps` per session, configurable.
- Minimum pacing rate: `256 Kbps`.
- Maximum pacing rate: configured by server/client policy.
- `0` max means no fixed user cap, but adaptive pacing still applies.

Suggested config:

- `OKRUN_SWITCH_UDP_INITIAL_MBPS=10`
- `OKRUN_SWITCH_UDP_MIN_MBPS=0.25`
- `OKRUN_SWITCH_UDP_MAX_MBPS=0`

### Adaptive Rate Control

Use receiver feedback to avoid persistent congestion.

Feedback can be sent over TCP/TLS control or encrypted UDP health packets. TCP/TLS feedback is simpler and authenticated by the existing control plane.

Receiver should report every `5s`:

- highest packet number seen
- estimated packet loss / gaps
- duplicate/replay drops
- reorder depth
- receive queue pressure
- fragment drops

Suggested adaptation:

- If loss is below `1%` and queue pressure is low, increase target rate gradually, e.g. `+10%` per health interval.
- If loss is above `5%`, reduce target rate aggressively, e.g. multiply by `0.5`.
- If loss is between `1%` and `5%`, hold or reduce mildly.
- If queue delay exceeds `100ms`, stop increasing.
- If queue delay exceeds `250ms`, drop queued frames and reduce rate.

This does not need to be perfect TCP-equivalent congestion control in v1, but it must prevent runaway UDP transmission.

### Backpressure and Queue Limits

Each outbound UDP session should have bounded queues.

Recommended defaults:

- Max queued bytes per session: `4 MiB`.
- Max queued frames per session: `4096`.
- Max queue delay target: `100ms`.
- Hard max queue delay: `250ms`.

When limits are exceeded:

- Drop Ethernet frames instead of growing memory indefinitely.
- Prefer dropping newest frames for bulk traffic if queue is full.
- Consider dropping oldest frames for stale broadcast/ARP-like bursts.
- Never block the entire switch fabric because one remote UDP path is congested.

Broadcast and unknown-unicast traffic should be rate-limited per recipient because one inbound frame can fan out to many UDP sends.

## Fragmentation and MTU

Internet UDP should avoid IP fragmentation.

Recommended safe default UDP payload target:

- `1200 bytes`

This is conservative but safe for internet and IPv6 paths. It means standard Ethernet frames around `1500 bytes` may need app-level fragmentation.

### Path MTU Discovery

Add authenticated application-level PMTU probing.

Recommended process:

1. Start at `1200` bytes UDP payload.
2. Send encrypted padded `PMTU_PROBE` packets at candidate sizes.
3. Candidate sizes: `1280`, `1350`, `1400`, `1450` bytes payload, subject to configured maximum.
4. Only raise the active UDP payload MTU after receiving authenticated `PMTU_PROBE_ACK` for that size.
5. Periodically re-probe larger sizes no more than once every `60s`.
6. If larger packets appear black-holed, reduce back to the last known good size.

Recommended defaults:

- Min UDP payload MTU: `1200`.
- Default active UDP payload MTU: `1200`.
- Max internet probe payload MTU: `1450`.
- Jumbo frame support: disabled by default.

### Guest MTU Handling

If the app can influence guest/virtual network MTU in a safe way, UDP mode may advertise a lower guest MTU to reduce overlay fragmentation.

Recommended behavior:

- Default guest Ethernet MTU remains compatible with existing behavior.
- Optional advanced setting may advertise a lower MTU when UDP mode is selected.
- Do not require guest MTU changes for v1.

### Fragment Behavior

Fragment behavior:

- Split large Ethernet frames into fragments only when frame size exceeds active UDP payload MTU.
- Encrypt/authenticate each UDP packet.
- Reassemble only after all fragments arrive.
- If a fragment is missing or times out, drop the whole Ethernet frame.
- Do not retransmit fragments at the Web Switch layer.

Guest TCP will retransmit when needed.

## Fragment Reassembly DoS Limits

Fragment reassembly must be bounded.

Recommended defaults:

- Fragment reassembly timeout: `1s`.
- Max Ethernet frame size without jumbo mode: `1518 bytes` plus expected metadata allowance.
- Max Ethernet frame size with explicit jumbo mode: `9000 bytes`.
- Max fragments per Ethernet frame: `16`.
- Max incomplete fragmented frames per session: `64`.
- Max reassembly bytes per session: `1 MiB`.
- Global max incomplete fragmented frames: `4096`.
- Global max reassembly bytes: `64 MiB`.

Rules:

- Authenticate and decrypt the UDP packet before allocating reassembly state.
- Drop fragment sets that exceed size/count limits.
- Drop duplicate fragments for the same `fragmentId` and `fragmentIndex`.
- Drop inconsistent metadata for an existing `fragmentId`.
- Expire old reassembly buffers on a timer.
- Apply per-session and global caps before allocating memory.
- Rate-limit sessions that repeatedly create incomplete fragment sets.

## Duplicate Frame Handling

Packet replay protection should catch normal duplicate UDP packets, but reassembly needs its own duplicate-delivery guard.

Rules:

- Deliver a reassembled Ethernet frame at most once per `(sessionId, keyId, fragmentId)`.
- Keep a short completed-fragment cache for `2s` or the last `1024` completed fragment IDs per session, whichever is smaller.
- Duplicate completed frames should be dropped.
- During transport switching, send each Ethernet frame through exactly one active data path, not both TCP and UDP.
- Do not retransmit old UDP frames over TCP during fallback.

Guest TCP can tolerate duplicates, but the switch should avoid creating them.

## Replay Protection

Each UDP session must maintain a replay window per direction and per `keyId`.

Drop packets when:

- Authentication tag is invalid.
- Session ID is unknown.
- Key ID is unknown or expired.
- Packet number is too old.
- Packet number was already seen.
- Fragment metadata is invalid.

Recommended replay window:

- At least `4096` packets.
- Configurable upward for high-bandwidth/high-reorder paths.

A sliding replay window is sufficient.

## NAT, Endpoint, and IPv6 Handling

The server should learn the client's UDP endpoint from a validated encrypted UDP probe.

Flow:

1. Server returns UDP session info over TCP/TLS.
2. Client sends encrypted UDP `PROBE`.
3. Server validates AEAD and session.
4. Server records source IP/port/address-family for that session.
5. Server replies with encrypted `PROBE_ACK`.
6. Client marks UDP as ready.

If the client's UDP source endpoint changes, require a new authenticated probe before accepting DATA from the new endpoint.

### Multi-Client Same NAT

Do not key sessions only by source IP/port.

Server mapping rules:

- Primary lookup should use `sessionId`.
- `sessionId` must be random and unique.
- AEAD validation must use the key derived for that session.
- The learned endpoint is an anti-spoof/path validation attribute, not the session identity.
- Multiple clients behind the same NAT are safe because each has a distinct `sessionId` and distinct keys.
- If the same endpoint appears for a different session, require that session's own valid AEAD probe before accepting DATA.

### IPv4 / IPv6

Support dual-stack explicitly.

Recommended behavior:

- Server can bind `udp4`, `udp6`, or both depending on config/platform behavior.
- Session endpoint records address family.
- Client should prefer the same address family that worked for TCP/TLS unless configured otherwise.
- IPv6 should keep the `1200` byte default payload because IPv6 requires careful MTU handling and routers do not fragment packets.
- PMTU probing should run independently per address family/path.

## Timeout Defaults

Use explicit defaults so behavior is testable.

Recommended values:

| Setting | Default |
| --- | ---: |
| UDP probe first retry | `500ms` |
| UDP probe retry schedule | `500ms`, `1s`, `2s` |
| UDP setup failure in UDP mode | `5s` |
| UDP setup fallback in Auto mode | `5s` |
| UDP health report interval | `5s` |
| NAT keepalive when idle | `15s` |
| UDP unhealthy timeout | `45s` |
| Fragment reassembly timeout | `1s` |
| Completed fragment duplicate cache TTL | `2s` |
| Key overlap during rotation | `60s` |
| UDP session cleanup after TCP control closes | immediate, with `10s` resource cleanup grace |
| PMTU upward probe interval | `60s` minimum |

Notes:

- `UDP unhealthy timeout` should be based on missing valid UDP keepalive/health/probe responses, not merely absence of DATA traffic.
- TCP/TLS control keepalive remains separate.

## Fallback Rules

### TCP/TLS Compatibility Mode

- Never starts UDP.
- All frames use existing TCP/TLS path.

### UDP Accelerated Mode

- Requires UDP support from server.
- Requires successful UDP probe.
- If UDP setup fails, show error and do not silently fall back.
- If UDP later becomes unhealthy, show error/reconnect rather than silently switching unless user explicitly selected Auto.

### Auto Mode

- Starts TCP/TLS control path.
- Sends data over TCP/TLS until UDP is ready.
- Switches to UDP after successful probe.
- Falls back to TCP/TLS if UDP becomes unhealthy.
- May retry UDP in the background after a cooldown.

Fallback triggers:

- UDP probe timeout.
- Repeated UDP authentication failures.
- UDP health timeout.
- NAT/path change without successful re-probe.
- Pacing rate falls below useful threshold for sustained period.
- Server disables UDP for session.

Recommended retry after fallback:

- Wait at least `60s` before retrying UDP.
- Use exponential backoff after repeated failures.
- Keep status visible as `TCP/TLS fallback`.

## Server Design

Add a new UDP component beside the current TLS server.

Suggested conceptual modules:

- `SwitchTLSServer`
- `SwitchFabric`
- `SwitchConnection`
- `SwitchUDPDataPlane`
- `SwitchUDPSession`
- `SwitchUDPCrypto`
- `SwitchUDPReplayWindow`
- `SwitchUDPFragmentReassembler`
- `SwitchUDPPacer`
- `SwitchUDPMTUProber`
- `SwitchUDPHealthMonitor`

### Server Responsibilities

- Keep existing TCP/TLS code path unchanged.
- Create UDP sessions only for authenticated TCP/TLS sessions.
- Bind UDP socket using Node's core `dgram` module.
- Encrypt/decrypt using Node's core `crypto` module.
- Map validated UDP packets to existing switch connections.
- Forward received Ethernet frames into `SwitchFabric` like current TCP DATA frames.
- Send outgoing Ethernet frames over UDP when the target connection has UDP ready and pacing allows it.
- Fall back to TCP for targets without UDP ready.
- Apply per-session congestion/pacing and queue limits.
- Apply fragment reassembly caps before allocating memory.
- Expose UDP counters in `/status`.

### Server Config

Add environment/config options such as:

- `OKRUN_SWITCH_UDP_ENABLED=true|false`
- `OKRUN_SWITCH_UDP_PORT=9443`
- `OKRUN_SWITCH_UDP_MTU=1200`
- `OKRUN_SWITCH_UDP_MIN_MTU=1200`
- `OKRUN_SWITCH_UDP_MAX_PROBE_MTU=1450`
- `OKRUN_SWITCH_UDP_REQUIRE=false`
- `OKRUN_SWITCH_UDP_INITIAL_MBPS=10`
- `OKRUN_SWITCH_UDP_MIN_MBPS=0.25`
- `OKRUN_SWITCH_UDP_MAX_MBPS=0`
- `OKRUN_SWITCH_UDP_QUEUE_BYTES=4194304`
- `OKRUN_SWITCH_UDP_REASSEMBLY_SESSION_BYTES=1048576`
- `OKRUN_SWITCH_UDP_REASSEMBLY_GLOBAL_BYTES=67108864`
- `OKRUN_SWITCH_UDP_SESSION_TTL_SECONDS=0`
- `OKRUN_SWITCH_UDP_IPV4=true`
- `OKRUN_SWITCH_UDP_IPV6=true`

Default should be safe:

- UDP disabled or optional depending on rollout stage.
- TCP/TLS always supported.
- Pacing always enabled when UDP is enabled.
- Reassembly memory always capped.

## UDP Socket Tuning

High-throughput UDP needs socket buffer planning.

Node server should tune where supported by core APIs:

- UDP receive buffer target: `4 MiB` default.
- UDP send buffer target: `4 MiB` default.
- Log actual buffer sizes after setting because OS may clamp them.
- Expose buffer sizes in `/status`.

Suggested config:

- `OKRUN_SWITCH_UDP_RECV_BUFFER_BYTES=4194304`
- `OKRUN_SWITCH_UDP_SEND_BUFFER_BYTES=4194304`

Swift/macOS side should tune only through available Network.framework or supported platform APIs. If direct socket buffer tuning is not available, rely on bounded app queues and pacing.

Important:

- Larger socket buffers do not replace congestion control.
- Larger buffers can increase latency if the app queues too much.
- App-level queue delay caps still apply.

## Swift Client Design

Conceptually split Web Switch networking into:

- `SwitchControlConnection`
  - existing TCP/TLS `NWConnection`
  - sends INIT, keepalive, member updates, errors

- `SwitchUDPDataPlane`
  - UDP `NWConnection` or UDP connection group using Network.framework
  - handles encrypted UDP packet send/receive

- `SwitchDataTransportMode`
  - `.tcp`
  - `.udp`
  - `.auto`

- `SwitchDataTransportState`
  - `.tcpOnly`
  - `.udpProbing`
  - `.udpReady`
  - `.tcpFallback`
  - `.udpUnhealthy`
  - `.failed`

- `SwitchUDPPacer`
  - per-session send pacing
  - queue limits
  - drop policy

- `SwitchUDPFragmentReassembler`
  - fragment caps
  - timeout cleanup
  - duplicate-delivery guard

### Swift Send Path

```text
VM Ethernet frame
→ PrivateNetworkSwitch
→ Web Switch connection
→ if UDP ready and pacer/queue allows: encrypt + fragment + send UDP
→ else if Auto fallback or TCP mode: send existing TCP/TLS DATA frame
→ else if UDP mode queue is full: drop and count
```

### Swift Receive Path

```text
UDP packet
→ validate session/key
→ AEAD decrypt
→ replay check
→ reassemble if fragmented
→ duplicate-delivery check
→ pass Ethernet frame to existing switch logic
```

The TCP/TLS receive path remains active for control messages and fallback DATA.

## Switch Fabric Behavior

The switch fabric should remain transport-agnostic.

It should not care whether an Ethernet frame arrived from:

- TCP/TLS DATA frame.
- UDP DATA packet.

It should continue making forwarding decisions based on existing MAC/member logic.

Transport-specific logic belongs at the connection/session edge.

The fabric should not block globally when one UDP target is congested. Per-target queues and drops must isolate slow receivers.

## Observability

Add client status counters:

- configured transport mode
- active transport
- UDP probe status
- UDP payload MTU
- UDP pacing rate
- UDP queue bytes / queue delay
- UDP packets sent/received
- UDP bytes sent/received
- UDP estimated loss
- UDP auth failures
- UDP replay drops
- UDP duplicate drops
- UDP fragment drops
- UDP PMTU probe status
- UDP fallback count and reason

Add server status counters:

- UDP enabled/disabled
- UDP sockets bound by address family
- UDP socket send/receive buffer sizes
- UDP sessions active
- UDP rx packets/bytes
- UDP tx packets/bytes
- UDP current pacing rates per session or aggregate
- UDP queue bytes per session or high-water marks
- UDP unknown session drops
- UDP invalid tag drops
- UDP replay drops
- UDP duplicate drops
- UDP fragment timeout drops
- UDP reassembly memory usage
- UDP PMTU probe success/failure
- UDP fallback sends

Server `/status` should expose UDP counters when enabled.

## Rollout Plan

### Phase 1: Server Capability Only

- Add UDP config fields and protocol negotiation response.
- Keep actual frame data over TCP/TLS.
- Verify backward compatibility.

### Phase 2: UDP Probe and Keying

- Add encrypted UDP probe/probe-ack.
- Add key derivation and rekey control flow.
- No Ethernet DATA over UDP yet.
- Validate NAT behavior and server counters.

### Phase 3: Pacing, MTU, and Reassembly Infrastructure

- Add token-bucket pacer.
- Add bounded send queues.
- Add PMTU probing.
- Add bounded fragment reassembly.
- Add duplicate-delivery guard.
- Still keep Ethernet DATA mostly on TCP until safety behavior is verified.

### Phase 4: UDP DATA Send/Receive

- Send Ethernet DATA over UDP after probe succeeds.
- Keep TCP/TLS fallback path.
- Start with Auto mode hidden or behind advanced option.

### Phase 5: UI Exposure

- Add Web Switch transport picker.
- Default new configs to Auto.
- Keep existing configs on TCP/TLS Compatibility.

### Phase 6: Hardening and Performance Validation

- Replay window tests.
- Tamper/drop tests.
- Fragment timeout tests.
- Fragment memory cap tests.
- Congestion/pacing tests.
- UDP blocked network tests.
- Long-running NAT rebinding tests.
- IPv4 and IPv6 tests.
- Multi-client same-NAT tests.
- PMTU black-hole tests.

## Testing Matrix

Required scenarios:

- Old Swift client to new server: TCP/TLS works.
- New Swift client in TCP mode to new server: TCP/TLS works.
- New Swift client in Auto mode with UDP allowed: UDP becomes active.
- New Swift client in Auto mode with UDP blocked: TCP/TLS fallback works.
- New Swift client in UDP mode with UDP blocked: clear failure.
- Tampered UDP packet: dropped.
- Replayed UDP packet: dropped.
- Duplicate UDP packet: dropped.
- Duplicate fragment set: delivered at most once.
- Unknown session UDP packet: dropped/rate-limited.
- Large Ethernet frame: fragmented/reassembled or safely dropped.
- Lost fragment: whole Ethernet frame dropped, no crash/leak.
- Malicious partial fragments: memory caps enforced.
- Fragment flood from authenticated peer: per-session caps enforced.
- Fragment flood from unauthenticated source: dropped before allocation.
- TCP/TLS control disconnect: UDP session expires.
- Rekey at time threshold: no packet loss beyond expected transition.
- Rekey at packet/byte threshold: no nonce reuse.
- Rekey failure in Auto mode: TCP/TLS fallback before hard limit.
- IPv4 UDP path works.
- IPv6 UDP path works or falls back cleanly.
- IPv6 PMTU black-hole: active MTU returns to safe default.
- Two or more clients behind the same NAT: sessions remain distinct.
- UDP endpoint rebinding: requires authenticated re-probe.
- Sender overload: pacer/queue drops are bounded and visible.
- Broadcast/unknown-unicast burst: per-recipient rate limits work.
- Clean link benchmark: UDP not worse than TCP/TLS by more than target.
- Lossy WAN benchmark: UDP meets throughput/latency target.

## Security Notes

- Do not send plaintext Ethernet frames over internet UDP.
- Do not use unauthenticated UDP, even for SSH traffic.
- Do not create a custom cipher.
- Do not allow UDP packets to create sessions without a prior authenticated TCP/TLS control session.
- Avoid amplification by keeping unauthenticated responses tiny or nonexistent.
- Rate-limit invalid UDP traffic.
- Expire UDP sessions when TCP/TLS control closes.
- Authenticate packets before fragment allocation.
- Keep memory bounded under malicious traffic.
- Use session IDs and AEAD keys to distinguish clients, not source IP/port alone.

## Recommendation

Implement this as an optional **UDP Accelerated data plane** for Web Switch only.

Keep the existing TCP/TLS transport as the compatibility baseline and control plane. Add Auto mode for the best user experience, with a strict UDP mode available for users who specifically want acceleration and are willing to fail when UDP is unavailable.

Before coding the full data path, implement and test the safety foundations first:

1. UDP negotiation/probe.
2. AEAD and replay protection.
3. Pacing/backpressure.
4. PMTU probing.
5. Fragment reassembly caps.
6. Explicit timeout/key-rotation behavior.

UDP remains the right direction for internet performance, but only with these production hardening pieces included from the start.
