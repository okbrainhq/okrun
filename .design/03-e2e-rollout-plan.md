# okrun-switch E2E and Rollout Plan

## Principle

Prove each layer before adding the next. The order should be:

1. Standalone server protocol and switching.
2. Swift protocol primitives.
3. Swift client against the standalone server.
4. OkRun runtime integration without full VM boot.
5. Full OkRun VM workflow.

## Milestone 1: web-switch starts and authenticates

Deliverables:

- `web-switch/package.json`
- TLS switch server
- local CA helper for tests
- `npm test` E2E runner

Tests:

- Server starts on an unused TLS port.
- Valid client cert connects.
- Missing client cert is rejected.
- Wrong CA client cert is rejected.
- Revoked cert is rejected.
- Bad frame before INIT closes the socket.
- Valid INIT returns ACK.

Exit criteria:

- Server E2E auth tests pass repeatedly.
- Logs identify why rejected clients were rejected.

## Milestone 2: web-switch switches Ethernet frames

Deliverables:

- host session registry
- network registry
- MAC learning table
- DHCP overlap guard

Tests:

- Host A broadcast reaches Host B.
- Host A broadcast does not echo back to Host A.
- Unknown unicast floods to other hosts.
- After Host B sends a frame, known unicast to Host B goes only to Host B.
- Hosts on `network-a` cannot receive frames from `network-b`.
- Overlapping DHCP ranges reject the second host.
- Non-overlapping DHCP ranges can coexist.
- Host disconnect removes MAC ownership.

Exit criteria:

- Server switching behavior matches a simple L2 switch.
- No OkRun code has changed yet.

## Milestone 3: multipath virtual socket behavior

Deliverables:

- server-side connection pool per host
- client test helper with multiple TLS sockets
- RESET_SEQ handling

Tests:

- Same host connects through two interface names.
- DATA duplicated over two sockets is delivered once.
- If one socket closes, traffic continues on the other.
- Reconnecting the same host/interface replaces the old socket.
- Server-to-host DATA is duplicated across active sockets.
- Client-side test helper receives only one logical frame after dedup.

Exit criteria:

- The protocol can support okproxy-style multipath.
- Swift can start with one connection but share the same logical model.

## Milestone 4: Swift protocol primitives

Deliverables:

- `SwitchFrameProtocol`
- `SwitchDedupWindow`
- frame type definitions

Tests:

- Swift frame bytes match Node frame bytes.
- Partial reads decode correctly.
- Oversized payload fails.
- Dedup logic matches okproxy behavior for duplicate, old, out-of-order, and far-ahead sequence numbers.

Exit criteria:

- Swift and Node agree on the wire protocol.

## Milestone 5: Swift client connects to web-switch

Deliverables:

- `RealSwitchSocket`
- `VirtualSwitchSocket`
- TLS identity loader
- reconnect and keepalive handling

Tests:

- Swift client completes mTLS and INIT against local `web-switch`.
- Swift client sends DATA and Node test client receives it.
- Node test client sends DATA and Swift receives it.
- PING/PONG keeps the connection alive.
- Server close triggers reconnect.
- Rejected INIT reports a useful status.

Exit criteria:

- Swift can act as a switch host without touching VM runtime code.

## Milestone 6: OkRun runtime integration

Deliverables:

- `PrivateNetworkSwitchConfig`
- config validation
- registry support
- `PrivateNetworkSwitchBridge`
- status plumbing

Tests:

- Config load/save preserves `switch`.
- Invalid server or missing cert path fails validation.
- Direct bridge and switch together are rejected for MVP.
- Two local `PrivateNetworkRuntime` instances on separate simulated hosts exchange frames through `web-switch`.
- Broadcast and known unicast behavior remains correct.
- Existing direct bridge tests still pass.

Exit criteria:

- OkRun can use cloud switch transport in tests without launching a full VM.

## Milestone 7: Full VM smoke

Deliverables:

- script to start local switch server with temp certs
- two OkRun projects configured with separate DHCP ranges
- optional guest-tools validation

Tests:

- VM A and VM B boot with private network enabled.
- Both hosts connect to the switch.
- Guests receive DHCP leases from their local host ranges.
- Guest A can ping Guest B's private IP after routing/name setup.
- Disconnecting one host removes it from switch status.

Exit criteria:

- The cloud switch works end to end with real VMs.

## Implementation guardrails

- Do not modify existing direct LAN bridge behavior while building server-only E2E.
- Keep the server protocol versioned from the first INIT.
- Keep max frame size explicit on both sides.
- Fail closed on malformed protocol, bad auth, and DHCP overlap.
- Treat Ethernet frames as opaque bytes except for MAC learning.
- Keep secrets out of logs.
- Leave the existing deleted `.design` files in the repo untouched unless explicitly asked.

