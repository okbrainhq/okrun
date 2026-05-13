# Distributed DHCP

## Objective

Remove the need to manually configure each host DHCP pool. Hosts should choose their own non-overlapping pool for a distributed private network while the cloud relay remains simple.

The cloud relay may reject exact duplicate live pool claims, but it does not allocate or remember IP ownership beyond active sessions.

## Desired Config

Project `okrun-vm.json` only names the local private network:

```json
{
  "privateNetwork": {
    "enabled": true,
    "identifier": "team-a-local"
  }
}
```

Distributed DHCP and cloud settings live in `~/.okrun/private-networks.json`:

```json
{
  "version": 1,
  "privateNetworks": {
    "team-a-local": {
      "dhcp": {
        "enabled": true,
        "mode": "distributed",
        "networkCidr": "10.77.0.0/16",
        "hostPoolPrefixLength": 24,
        "leaseSeconds": 3600
      },
      "cloud": {
        "enabled": true,
        "server": "vnet.example.com:9443",
        "networkId": "team-a",
        "caCertPath": "~/.okrun/certs/ca-cert.pem",
        "clientCertPath": "~/.okrun/certs/client-cert.pem",
        "clientKeyPath": "~/.okrun/certs/client-key.pem"
      }
    }
  }
}
```

The host derives `hostId` from the mTLS client certificate public-key fingerprint unless explicitly overridden for tests.

## Pool Selection

Inputs:

- `networkId`
- `networkCidr`
- `hostPoolPrefixLength`
- `hostId`
- local persistent `salt`

Algorithm:

1. Compute the number of available host pools inside `networkCidr`.
2. Compute `poolIndex = hash(networkId + hostId + salt) % poolCount`.
3. Convert `poolIndex` to a concrete CIDR such as `10.77.44.0/24`.
4. Persist `{ networkId, hostId, salt, poolCidr }` locally.
5. Use that pool for local host DHCP.
6. Send `poolCidr` in relay INIT.
7. If the relay returns `duplicate_pool`, increment salt and retry before starting DHCP for new VMs.

## Host Announcements

Hosts should also announce their selected pool to peers through a control frame. The relay forwards this like any other scoped frame and does not interpret it.

```json
{
  "type": "pool_announcement",
  "protocol": "okrun-vnet-control/1",
  "networkId": "team-a",
  "hostId": "abc123",
  "poolCidr": "10.77.44.0/24",
  "epoch": 4
}
```

This lets hosts detect conflicts after partition/reconnect scenarios where two sides independently selected the same pool.

## Collision Handling

Before DHCP starts:

- If relay rejects the pool, retry with a new salt.
- If a peer announcement conflicts, the deterministic loser retries. Winner can be the lexicographically lower `hostId`.

After DHCP has active leases:

- Avoid immediate disruptive pool changes.
- Mark the network as `poolConflict`.
- Stop issuing new leases.
- On renewal, NAK leases from the losing pool only after a new pool is ready.
- Show a clear status that guests may need DHCP renewal or reboot.

For the first implementation, prefer resolving collisions before guest start. Runtime collision migration can be a follow-up hardening step.

## DHCP Behavior

Once a pool is selected, host DHCP is the same as phase 1:

- Leases are local to the host.
- No default gateway option by default.
- No DNS option by default.
- Lease range is derived from the selected pool, leaving reserved addresses at the start and end.

Example for `10.77.44.0/24`:

- Host DHCP server ID: `10.77.44.1`
- Lease range: `10.77.44.20` through `10.77.44.239`
- Broadcast: `10.77.44.255`
- Guest mask: use the wider distributed network mask if we want ARP across pools, for example `/16`.

The key detail is that guests should consider the full distributed network on-link. With a `/16` mask, a VM in `10.77.12.0/24` can ARP for a VM in `10.77.44.0/24`, and those ARP frames travel through the cloud relay.

## Implementation Plan

1. Extend config.
   - Add DHCP mode: `range`, `distributed` to host network config.
   - Add `networkCidr` and `hostPoolPrefixLength`.
   - Keep explicit range config for phase 3 compatibility.
   - Do not add distributed DHCP fields to `VMConfig` or `PrivateNetworkConfig`.

2. Add local host identity.
   - Derive default `hostId` from mTLS client cert public key.
   - Add test override env `OKRUN_HOST_ID`.
   - Persist salt and selected pool under `~/.okrun/state/private-networks/<identifier>/pool.json`.

3. Add pool allocator.
   - Deterministic hash-based selection.
   - Retry on duplicate-pool rejection.
   - Validate that selected pool fits in `networkCidr`.

4. Add control frames.
   - Host sends pool announcements on connect and periodically.
   - Host records peer pool announcements in memory.
   - Conflict detection is local.

5. Integrate with host DHCP.
   - DHCP range derives from selected pool.
   - DHCP subnet mask can be the distributed `networkCidr` mask.
   - Leases persist per selected pool.

6. Add status and diagnostics.
   - Show selected pool in logs.
   - Include cloud state, host ID, selected pool, peer count, and conflict state in diagnose output.

## E2E Test Plan

1. Pool allocator unit tests.
   - Same inputs produce same pool.
   - Different host IDs usually produce different pools.
   - Salt retry changes pool.
   - Pool is always inside `networkCidr`.
   - Exhaustion reports a clear error.

2. Duplicate rejection retry test.
   - Start local relay.
   - Force two hosts to same initial pool with `OKRUN_HOST_ID` or allocator fixture.
   - Relay rejects second.
   - Second host increments salt, reconnects, and gets a different pool.

3. Announcement conflict test.
   - Start two hosts without relay duplicate rejection, or inject conflicting announcements directly.
   - Assert deterministic loser chooses a new salt before DHCP starts.

4. Distributed DHCP headless E2E.
   - Start local relay.
   - Run each simulated host with its own `OKRUN_HOME`.
   - Start two isolated host roots with distributed mode.
   - Start one VM on each host.
   - Assert each VM gets an IP from a different derived pool.
   - Assert guests can ping across pools.

5. Persistence E2E.
   - Start host, record selected pool.
   - Restart host with same cert and state.
   - Assert same pool is selected.
   - Delete local state, keep same cert.
   - Assert deterministic initial pool is selected again.

## Acceptance Criteria

- Users no longer need to manually choose pools for normal cloud private networks.
- Distributed DHCP settings are host-app settings under `~/.okrun`.
- Hosts converge on unique pools without cloud allocation.
- Guests receive DHCP addresses and can reach guests on other hosts.
- Conflict handling is deterministic and test-covered.
- Cloud relay remains a scoped authenticated packet forwarder, not an IPAM service.
