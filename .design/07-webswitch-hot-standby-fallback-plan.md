# WebSwitch Hot Standby Fallback Plan

## Problem

LocalSwitch fallback is now correct, but not instant.

The current behavior during LocalSwitch loss is:

1. RouterLayer stops using LocalSwitch once LocalSwitch keepalive or local member count proves it is unavailable.
2. RouterLayer starts sending frames to WebSwitch quickly.
3. Guest traffic still has a visible recovery period while WebSwitch reconnects, finishes INIT, relearns MAC paths, and/or refreshes guest neighbor state.

The desired behavior is that WebSwitch remains hot while LocalSwitch is preferred. When LocalSwitch disappears, RouterLayer should already have a connected, initialized, route-warmed WebSwitch path available.

## Goals

- Keep WebSwitch connected and initialized even while LocalSwitch carries all normal traffic.
- Keep WebSwitch route state warm enough that fallback does not require a fresh reconnect or first-packet discovery burst.
- Preserve LocalSwitch preference whenever it has more than one local member.
- Avoid duplicate guest delivery and L2 loops.
- Keep server behavior compatible with older clients where possible.

## Non-goals

- Do not make WebSwitch and LocalSwitch both deliver the same data frame to guests by default.
- Do not add full active-active multipath across LocalSwitch and WebSwitch yet.
- Do not change DHCP allocation or guest-visible private network config.

## Current Signals

The router currently has two remote transports:

- LocalSwitch: plain TCP, preferred only when connected and `localMemberCount > 1`.
- WebSwitch: mTLS, fallback path, currently routable while connecting or connected.

The server reports:

- `networkMemberCount`: hosts in the network across all listeners.
- `localMemberCount`: hosts with an active LocalSwitch listener connection.

Swift already:

- Uses LocalSwitch keepalive for dead local path detection.
- Uses LocalSwitch-specific member count for routing eligibility.
- Falls back to WebSwitch when LocalSwitch is unavailable.

The remaining delay likely comes from WebSwitch not being fully useful at the moment of fallback.

## Design

### 1. Split Transport State From Route Preference

Keep both transports retained and running whenever both configs are enabled.

RouterLayer should treat transport state and route preference separately:

- `transport.isReady`: connection is initialized and can send frames immediately.
- `transport.isPreferred`: LocalSwitch has more than one local member.
- `transport.isFallbackReady`: WebSwitch is initialized and has recent liveness.

Route choice:

1. Use LocalSwitch when `localSwitch.isPreferred`.
2. Otherwise use WebSwitch only if `webSwitch.isReady`.
3. If WebSwitch is connecting, either buffer a tiny number of discovery frames or drop with debug logs.

This makes the behavior explicit instead of relying on `canSendFrames()` to mean both "ready" and "should be preferred".

### 2. Keep WebSwitch Connected In The Background

When LocalSwitch is active, WebSwitch should still:

- Maintain its mTLS connection.
- Complete INIT.
- Respond to server PINGs.
- Reconnect independently if it fails.
- Keep status visible in the UI.

Do not stop or deprioritize WebSwitch reconnect just because LocalSwitch is active.

If there is existing logic that recreates or pauses WebSwitch when LocalSwitch is configured, remove that coupling. LocalSwitch should only affect route choice, not WebSwitch lifecycle.

### 3. Warm WebSwitch MAC And Peer State

The first WebSwitch frame after fallback may be broadcast/ARP-heavy or hit stale MAC state. To reduce that, add a low-rate warmup channel while LocalSwitch is active.

Candidate approach:

- Continue sending selected broadcast/control frames to WebSwitch even while LocalSwitch is preferred.
- Keep normal unicast data only on LocalSwitch.
- Candidate warmup frame types:
  - ARP request/reply
  - IPv6 neighbor discovery if supported later
  - mDNS only if needed, probably not initially

This gives WebSwitch enough source MAC updates to keep the server MAC table fresh without duplicating every data packet.

Implementation shape:

- Add `shouldMirrorToFallback(frame:)` in RouterLayer.
- If LocalSwitch is selected and WebSwitch is ready, mirror only safe discovery frames to WebSwitch.
- Keep a rate limit per source MAC and protocol to avoid chatty broadcast storms.

Initial safe rule:

- Mirror ARP frames only.
- Mirror no IP unicast payloads.
- Rate limit to one mirrored ARP frame per source MAC per second.

### 4. Avoid Duplicate Remote Delivery

Mirroring ARP to WebSwitch can still reach remote hosts while LocalSwitch also carries it.

Risk controls:

- Only mirror when WebSwitch is ready.
- Start with ARP only.
- Use existing sequence/dedup per transport where available.
- Consider adding a route marker or transport ID only if duplicate ARP becomes a real problem.

Because ARP is idempotent and already broadcast-like, duplicate ARP is acceptable for a first implementation. Do not mirror ICMP or TCP/UDP payloads.

### 5. Faster WebSwitch Readiness Reporting

Add logs/status that make fallback diagnosis obvious:

- WebSwitch ready/initialized timestamp.
- LocalSwitch preferred/unpreferred transitions with local member count.
- Route changes: `local-switch -> web-switch`, `web-switch -> local-switch`.
- WebSwitch warmup mirror counts.

This should make ping traces easier to line up with app logs.

### 6. Optional Packet Buffer During Route Flip

If the hot WebSwitch path still has a sub-second blind spot, add a tiny bounded retry buffer in RouterLayer.

Rules:

- Only buffer when LocalSwitch just became unavailable and WebSwitch is not ready yet.
- Buffer max 8-16 frames or 250ms, whichever comes first.
- Prefer ARP/ICMP over arbitrary payload only if we add packet classification.
- Drop on overflow with debug logs.

This should be a second pass. A hot WebSwitch path is cleaner than buffering.

## Implementation Phases

### Phase 1: Observability

Add logs and tests without changing routing behavior:

- Log LocalSwitch route eligibility changes with `localMemberCount`.
- Log WebSwitch initialized/uninitialized transitions.
- Log RouterLayer route changes.
- Add Swift tests for route-change logging hooks if practical, or unit-test a small route decision object.

Exit criteria:

- A ping fallback run can show exactly when LocalSwitch became ineligible, when WebSwitch was ready, and when the router changed route.

### Phase 2: Explicit Ready/Preferred Model

Refactor `PrivateNetworkRoutableTransport` or add a small adapter so RouterLayer can ask:

- `isReadyForPrivateNetworkFrames`
- `isPreferredForPrivateNetworkFrames`

Expected behavior:

- LocalSwitch ready means connected.
- LocalSwitch preferred means connected and local member count > 1.
- WebSwitch ready means connected or current accepted behavior if buffering during connecting remains intentional.
- WebSwitch preferred is always false when LocalSwitch is preferred.

Exit criteria:

- Existing fallback and return-to-local tests pass.
- Tests distinguish "LocalSwitch connected but not preferred" from "LocalSwitch disconnected".

### Phase 3: Ensure WebSwitch Stays Hot

Audit `PrivateNetworkRuntimeRegistry` and switch retention:

- WebSwitch should be retained and started whenever WebSwitch config is enabled.
- LocalSwitch config should not stop WebSwitch.
- Reconnect timers should continue while LocalSwitch is active.

Add tests:

- Configure both switches.
- Mark LocalSwitch preferred.
- Simulate WebSwitch disconnect.
- Assert WebSwitch schedules reconnect anyway.

Exit criteria:

- App logs show WebSwitch remains initialized during LocalSwitch traffic.

### Phase 4: ARP Warmup Mirroring

Add Ethernet frame classification:

- Parse EtherType.
- Detect ARP: `0x0806`.
- Add `shouldMirrorToFallback(frame:)`.

Router behavior:

- If route is LocalSwitch and WebSwitch is ready, send selected ARP frames to WebSwitch too.
- Do not mirror unknown unicast, ICMP, TCP, UDP, or malformed frames.

Add tests:

- Broadcast ARP while LocalSwitch preferred sends to LocalSwitch and WebSwitch.
- ICMP while LocalSwitch preferred sends only to LocalSwitch.
- Rate limit suppresses repeated ARP mirror bursts.
- When WebSwitch is not ready, ARP is not mirrored.

Exit criteria:

- WebSwitch MAC table remains warm without duplicating normal data traffic.

### Phase 5: Full Fallback E2E

Extend headless E2E with a LocalSwitch + WebSwitch scenario:

1. Start WebSwitch with both TLS and LocalSwitch listeners.
2. Start two hosts with both configs.
3. Confirm ping uses LocalSwitch latency.
4. Stop or firewall LocalSwitch only.
5. Assert traffic recovers through WebSwitch within a target window.
6. Restart LocalSwitch.
7. Assert traffic moves back to LocalSwitch.

Initial target:

- Fallback to WebSwitch: under 3 seconds for first successful ping.
- Return to LocalSwitch: under 5 seconds after LocalSwitch server is reachable.

Later target:

- Fallback under 1 second when WebSwitch was already initialized.

## Test Matrix

Swift unit tests:

- Router prefers LocalSwitch when preferred.
- Router uses WebSwitch when LocalSwitch connected but `localMemberCount == 1`.
- Router does not mirror non-ARP payloads.
- Router mirrors ARP only when WebSwitch is ready.
- Route changes do not deadlock with runtime callbacks.

Node e2e tests:

- `localMemberCount` ignores WebSwitch-only peers.
- `localMemberCount` drops when a host loses only its local interface.
- Member updates are sent when local membership changes even if global network membership does not.

Headless e2e tests:

- WebSwitch-only reconnect remains passing.
- LocalSwitch preferred path has low latency.
- LocalSwitch loss falls back to WebSwitch.
- LocalSwitch return moves back to LocalSwitch.

Manual validation:

- Run continuous ping.
- Tail logs.
- Verify route flip timestamps match ping behavior.

## Risks

- Mirrored ARP may create extra broadcast traffic. Rate limiting should keep this small.
- WebSwitch warmup may refresh MAC ownership incorrectly if LocalSwitch and WebSwitch observe frames in different order. Start with ARP only and inspect MAC-table behavior.
- Keeping WebSwitch always hot increases server connections. This is expected but should be visible in status.
- If the remote host is old and does not keep WebSwitch hot, this host can only optimize its side. Full benefit needs both hosts updated.

## Rollout

1. Ship observability and explicit route state first.
2. Verify WebSwitch stays initialized while LocalSwitch carries traffic.
3. Add ARP warmup behind a default-on internal flag or env toggle if we want a quick rollback.
4. Run manual ping tests on two-host setup.
5. Promote the headless LocalSwitch/WebSwitch fallback e2e to the regular suite.

Suggested env toggle:

```bash
OKRUN_SWITCH_MIRROR_ARP_TO_FALLBACK=1
```

If the feature is stable, remove the toggle later and keep the rate limiter.
