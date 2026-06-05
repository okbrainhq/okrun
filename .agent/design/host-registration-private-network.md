# Host Registration Into Okrun Private Network

Date: 2026-06-05
Scope: Original research report. Implementation landed after this report in `PrivateNetworkHostSSHService` with UI/config support under Private Network > Host.

## Question

Can the running macOS host be registered into the existing Okrun private network so a VM can SSH directly into the host, similar to how VMs can join the Web Switch / Local Switch fabric?

Short answer: yes, but not by only adding another switch config entry. The current network is a layer-2 frame fabric for VM NICs. The macOS host does not currently have an IP interface on that fabric, so host `sshd` cannot receive packets from `10.77.0.0/24` unless we add either:

1. a real/virtual host network interface, or
2. a user-space host endpoint that speaks enough Ethernet/IP/TCP to proxy SSH.

## Current Implementation Snapshot

### VM networking

- Every VM receives a regular NAT NIC for internet access.
- If private networking is enabled, the VM also receives a second Virtio NIC backed by `VZFileHandleNetworkDeviceAttachment`.
- The private NIC is wired to `PrivateNetworkRuntime`, which uses an `AF_UNIX` datagram socket pair and local `.sock` peer files under `/tmp/okrun-vnet/<network-id>/`.
- Frames from a guest are:
  - observed by local host services such as DHCP,
  - broadcast to local private-network peers on the same Mac,
  - optionally routed to Local Switch / Web Switch transports.

Relevant code:

- `NetworkDeviceFactory.makeDevices(...)` creates NAT plus optional private NIC: `Sources/OkrunVM/Core/VMCore.swift:779`.
- Private NIC uses `VZFileHandleNetworkDeviceAttachment`: `Sources/OkrunVM/Core/VMCore.swift:830`.
- `PrivateNetworkRuntime` owns socket pair/local peer sockets: `Sources/OkrunVM/Core/VMCore.swift:1171`.
- DHCP server observes guest frames and injects DHCP replies: `Sources/OkrunVM/Core/HostDHCP.swift:509`.

### Addressing

- Default private CIDR: `10.77.0.0/24`.
- Default DHCP range: `10.77.0.20` to `10.77.0.200`.
- DHCP server identifier/source IP is `network + 1`, so default `10.77.0.1`.
- No DNS/default route is installed on the private NIC.

### Switch fabric

- Web Switch and Local Switch transport Ethernet frames over TCP.
- Web Switch uses mTLS; Local Switch uses plain TCP for trusted LANs.
- Switch membership is keyed by `networkIdentifier` and `nodeID`.
- It forwards Ethernet frames based on a MAC table, flooding broadcasts/unknown-unicast.
- Current Okrun switch transport exists only when `PrivateNetworkRuntimeRegistry` has a VM runtime to retain.

Relevant code:

- Router selection/fallback: `Sources/OkrunVM/Core/PrivateNetworkRouter.swift`.
- Switch client and protocol: `Sources/OkrunVM/Core/PrivateNetworkSwitch.swift`.
- JS switch fabric admission/MAC forwarding: `web-switch/src/switch-fabric.js`.

## Key Constraint

The current macOS host is a frame observer/injector, not an IP endpoint.

That means:

- Guests can receive DHCP from the host process.
- Guests can exchange Ethernet frames with other guests.
- Remote hosts can participate through Web Switch / Local Switch.
- But macOS itself has no `10.77.0.x` interface, no host ARP presence, and no kernel TCP stack on this network.

So `ssh user@10.77.0.1` from a VM will not reach host `sshd` unless something answers ARP and handles/proxies the TCP connection.

## Option A — User-Space Host Access Endpoint

Build a host endpoint inside Okrun that reserves an IP/MAC on the private network and proxies selected ports to macOS services.

Example behavior:

```text
VM -> ssh user@10.77.0.1
       ARP who-has 10.77.0.1?
Okrun Host Endpoint -> ARP reply with host virtual MAC
VM -> TCP 10.77.0.1:22
Okrun Host Endpoint -> proxy to 127.0.0.1:22 on macOS
```

### What it needs

- Config, likely host-level in `~/.okrun/private-networks.json`, for example:
  - enabled/disabled
  - host IP, default candidate `10.77.0.1` or `10.77.0.2`
  - host MAC
  - allowed TCP ports, default maybe only `22 -> 127.0.0.1:22`
- ARP responder for the host IP.
- Optional ICMP echo responder for diagnostics.
- A user-space TCP implementation or embedded netstack to terminate guest TCP and proxy to local macOS TCP.
- Integration with local runtimes and switch transports so both local VMs and remote Web Switch VMs can reach it.

### Pros

- No root/admin install required if implemented fully in user space.
- Works with existing Web Switch / Local Switch frame fabric.
- Can be strictly scoped to SSH or selected ports.
- Best MVP for “VM can SSH into host”.

### Cons

- Requires a TCP stack/proxy layer; simple frame forwarding is not enough.
- Only supports services explicitly proxied unless a full user-space IP stack is added.
- Needs careful security controls because all private-network members can attempt host access.

### Recommendation

Best short-term direction. It matches the product architecture and avoids privileged macOS networking.

## Option B — Real Host Virtual Interface

Create a real macOS network interface for the private network, assign the host `10.77.0.x`, and bridge/route frames between that interface and Okrun’s private L2 fabric.

### What it gives

- macOS kernel owns the private IP.
- Native host `sshd` can listen normally.
- Arbitrary host TCP/UDP services work, not only SSH.
- Standard tools like `ifconfig`, routing, firewall, and packet capture become useful.

### Possible mechanisms

- TUN/utun style L3 interface plus an L3 bridge/router in Okrun.
- TAP-like Ethernet interface if available via third-party/driver approach.
- Network Extension / System Extension style packet tunnel.

### Pros

- Most complete and natural networking model.
- Supports any protocol, not only selected TCP ports.
- Clean mental model: host is a real node on the subnet.

### Cons

- Significantly more platform complexity on macOS.
- Likely needs elevated privileges, entitlements, a system extension, or external helper installation.
- Harder to ship in the current ad-hoc-signed app model.
- Bigger support/security burden.

### Recommendation

Best long-term/full-feature solution, but too heavy for the first SSH-focused implementation.

## Option C — Standalone Host Agent Registered With Web/Local Switch

Run a separate host-agent process that connects to the same Web Switch / Local Switch as a switch client, without needing a running VM.

This agent would still need either:

- a user-space host endpoint/proxy, or
- a real virtual interface.

### Pros

- Host can stay reachable even when no Okrun VM is currently running.
- Clean separation from VM lifecycle.
- Useful for headless hosts or servers.

### Cons

- “Registering with the switch” alone does not provide SSH; it only creates a frame transport.
- Still needs Option A or Option B to provide IP/TCP behavior.
- Needs stable host identity/nodeID persistence.

### Recommendation

Good companion to Option A. The MVP can start in-app, then move to or add a background agent later.

## Option D — Use Existing NAT/LAN Paths For Local-Only Host SSH

If the requirement is only “VM on this Mac SSH into this Mac”, the regular NAT/LAN side may be enough operationally.

Examples:

- VM SSHs to a host LAN IP.
- VM SSHs to a host address reachable through the NAT network, if available.
- Use normal port forwarding/reverse SSH outside the private network.

### Pros

- No private-network changes.
- Can work immediately for local development.

### Cons

- Does not register the host into the Okrun private network.
- Does not solve remote Web Switch VM -> host access.
- Depends on local routing/firewall behavior.

### Recommendation

Useful workaround only, not the product answer.

## Option E — Bridge VMs To Physical LAN

Use a bridged networking model so VMs are directly on the physical LAN and can SSH to the Mac’s LAN IP.

### Pros

- Simple mental model on trusted LANs.
- Uses normal host networking.

### Cons

- Not the Okrun private network.
- Does not span Web Switch over the internet.
- Physical LAN dependency; may not work on all networks.

### Recommendation

Separate feature/workaround, not suitable for “host joins Okrun private fabric”.

## Important Design Decisions

### Host IP

Default DHCP server IP is already `10.77.0.1`.

Two reasonable choices:

- Use `10.77.0.1` as the host-access IP and treat DHCP + host access as the same virtual host.
- Use `10.77.0.2` for SSH host access and keep `10.77.0.1` as DHCP-only.

Recommendation: use `10.77.0.1` only if we intentionally make the DHCP server and host-access endpoint one virtual node. Otherwise use `10.77.0.2` to avoid mixing roles. Both are outside the default DHCP lease range.

### Host MAC

Use a stable locally-administered MAC derived from:

```text
okrun-private-network-host-access:<network-id>
```

Avoid reusing guest MAC derivation. Stability matters because switches and guests learn MAC routes.

### Switch lifecycle

Currently switch transports are retained through VM runtimes. For host access over Web Switch with no local VM running, we need a host-level switch transport independent of `PrivateNetworkRuntime`.

Minimum viable behavior:

- Host access is active while Okrun app is open and private network is configured.
- Later: LaunchAgent/background helper keeps host access online.

### Security

Host access must be opt-in.

Suggested defaults:

- Disabled by default.
- Only proxy TCP 22 if explicitly enabled.
- Bind proxy target to `127.0.0.1:22` by default, not arbitrary LAN addresses.
- Optional allowlist of remote switch certificate identities or node IDs if the switch exposes enough identity info.
- Clear UI warning: any VM/member on that private network can attempt SSH.

### DHCP

Host access should reserve IPs outside the lease range. It should not advertise a DHCP range as a separate host unless it is actually acting as a DHCP server.

The switch currently rejects overlapping DHCP ranges between different active hosts, so host-only switch sessions should avoid unnecessary `dhcpRange` advertisement.

### Remote reachability flow with Option A

```text
Remote VM sends ARP broadcast for host IP
-> Web Switch floods broadcast
-> Host endpoint receives frame
-> Host endpoint replies with ARP response
-> Web Switch learns host MAC route
-> Remote VM opens TCP to host IP:22
-> Host endpoint terminates/proxies TCP to macOS 127.0.0.1:22
```

This fits the current layer-2 switch design.

## Feasibility Matrix

| Option | Works over Web Switch | Needs admin/system networking | Supports native host sshd | Complexity | Fit |
| --- | --- | --- | --- | --- | --- |
| User-space host endpoint/proxy | Yes | No | Via proxy | Medium/High | Best MVP |
| Real host virtual interface | Yes, with bridge | Likely yes | Yes | High | Best full solution |
| Standalone host agent | Yes | Depends on backend | Depends | Medium/High | Good companion |
| Existing NAT/LAN workaround | No | No | Yes | Low | Workaround |
| Physical LAN bridge | No | Maybe | Yes | Medium | Separate feature |

## Recommended Path

### Phase 1: Host Access MVP

Implement a host-access endpoint inside Okrun:

- Add host-level private-network config.
- Reserve a private IP/MAC outside DHCP range.
- Attach an ARP responder to each local private runtime.
- Add ICMP echo response for `ping` diagnostics.
- Add TCP port proxy for SSH, ideally through a small user-space TCP stack.
- Add switch transport support so the same endpoint can receive/respond via Web Switch / Local Switch.
- Expose UI: “Allow VMs to SSH into this Mac” with host/IP/port display.

Target UX:

```text
ssh <mac-user>@10.77.0.1
```

or, if using a separate IP:

```text
ssh <mac-user>@10.77.0.2
```

### Phase 2: Host Agent / Always-On

- Persist host nodeID.
- Allow host access to run while no VM is running.
- Optional LaunchAgent.
- Add switch status visibility for host endpoint.

### Phase 3: Full Virtual Interface

Only if we need arbitrary protocols or native OS-level private networking:

- Investigate a real macOS virtual interface path.
- Bridge or route between that interface and Okrun’s frame fabric.
- Reuse the same Web Switch transport where possible.

## Final Assessment

Yes, we can make VMs SSH directly into the running host through the private network.

The most practical approach is not “register host with switch only”; it is “create a host endpoint on the private L2 fabric.” For an SSH-focused feature, a user-space ARP/IP/TCP proxy endpoint is the best MVP. A real macOS virtual interface is the cleaner long-term model but has much higher platform and entitlement cost.
