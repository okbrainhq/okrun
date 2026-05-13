# Host DHCP And Guest Tools

## Objective

Add a DHCP server inside the OkRUn host app for the private VM network, then update guest tools so Linux guests configure the private NIC through DHCP instead of requiring static IPs.

This phase is local-only. No cloud relay is required.

## User-Facing Behavior

Projects continue to enable the private NIC in `okrun-vm.json`, but they do not own DHCP ranges:

```json
{
  "privateNetwork": {
    "enabled": true,
    "identifier": "team-a"
  }
}
```

The host app stores DHCP policy under `~/.okrun/private-networks.json`:

```json
{
  "version": 1,
  "privateNetworks": {
    "team-a": {
      "dhcp": {
        "enabled": true,
        "mode": "range",
        "cidr": "10.77.0.0/24",
        "rangeStart": "10.77.0.20",
        "rangeEnd": "10.77.0.200",
        "leaseSeconds": 3600
      }
    }
  }
}
```

Guest tools install a DHCP-based private-network config:

```sh
scripts/install-guest-tools.sh --user debian --private-dhcp devbox.local
```

`--private-ip` remains as a legacy/static option. When both are supplied, static wins and the script reports that DHCP was skipped.

## Host App Implementation Plan

1. Add host app config storage.
   - Introduce `OkrunHome` rooted at `~/.okrun` by default and overridable with `OKRUN_HOME`.
   - Migrate the current file-based `~/.okrun` registry to `~/.okrun/registry.json`.
   - Keep `OKRUN_REGISTRY_PATH` as an override for the registry only.
   - Add `HostNetworkConfigStore` for `~/.okrun/private-networks.json`.
   - Key DHCP settings by `privateNetwork.identifier`.

2. Extend host network config models.
   - Add `PrivateNetworkDHCPConfig` outside `VMConfig`.
   - Do not add DHCP fields to `PrivateNetworkConfig`.
   - Validate CIDR, lease range, lease duration, and that the range is inside the CIDR.
   - Default is enabled for private networks: the host creates an enabled default DHCP config the first time a VM runs with a private-network identifier.

3. Stabilize guest identity for leases.
   - Prefer explicitly setting a deterministic MAC address on the private `VZVirtioNetworkDeviceConfiguration`, derived from project machine identifier plus private network identifier.
   - If the Virtualization.framework API is unavailable on a target macOS version, persist leases by DHCP client identifier when present and fall back to observed MAC.

4. Add packet parsing and encoding.
   - Create small Swift types for Ethernet, IPv4, UDP, and DHCP/BOOTP packets.
   - Parse enough for DHCPDISCOVER, DHCPREQUEST, DHCPDECLINE, DHCPRELEASE, and DHCPINFORM.
   - Encode DHCPOFFER, DHCPACK, and DHCPNAK.
   - Compute IPv4 and UDP checksums correctly.
   - Keep this dependency-free.

5. Add a packet tap to the private network runtime.
   - Introduce a `PrivateNetworkFrameDirection` enum.
   - Let `PrivateNetworkRuntime` notify observers before forwarding guest frames and before injecting peer frames.
   - Add an injection method for host-generated frames back to the VM attached to that runtime.

6. Add `HostDHCPServer`.
   - One DHCP server instance per VM private runtime is enough for phase 1 because each runtime sees frames from its attached local guest.
   - The server should answer only frames from its local guest path, not frames received from peers.
   - Persist leases under `~/.okrun/state/private-networks/<identifier>/leases.json`.
   - Offer no router option by default.
   - Avoid DNS options by default unless explicitly configured later.
   - Include subnet mask, lease time, renewal time, rebinding time, server identifier, and broadcast address.

7. Update runtime lifecycle.
   - Start DHCP when private network is enabled in the project and DHCP is enabled for that identifier in host config.
   - Stop it when the VM stops and the runtime is released.
   - Log lease assignment, renewal, and conflicts through `AppLog.virtualMachine`.

## Guest Tools Implementation Plan

1. Update `scripts/install-guest-tools.sh`.
   - Add `--private-dhcp`.
   - Pass `--private-dhcp` through to `scripts/guest-tools/install-okrun-guest-tools.sh`.
   - Keep `--private-ip CIDR` for static configuration.

2. Update `scripts/guest-tools/install-okrun-guest-tools.sh`.
   - Add `--private-dhcp`.
   - Detect the private interface as today.
   - Install a systemd-networkd file like:

```ini
[Match]
Name=enp0s2

[Network]
DHCP=ipv4
LinkLocalAddressing=no
IPv6AcceptRA=no

[DHCPv4]
UseDNS=false
UseRoutes=false
```

   - Do not overwrite manually managed private network files.
   - If `--private-ip` is present, keep the current static `Address=` behavior.

3. Update README.
   - Document that `okrun-vm.json` only enables the private NIC and selects an identifier.
   - Document DHCP config under `~/.okrun/private-networks.json`.
   - Replace the primary private-network setup path with `--private-dhcp`.
   - Keep a static IP subsection for advanced users.
   - Explain that the private NIC intentionally receives no default gateway.

## E2E Test Plan

1. Unit tests in `Tests/OkrunVMTests`.
   - Host config decoding, validation, and migration from file-based `~/.okrun`.
   - CIDR/range validation.
   - DHCP parser fixtures for DISCOVER and REQUEST.
   - DHCP OFFER/ACK encoder checksum validation.
   - Lease allocator behavior, including reuse and exhaustion.

2. Guest tools fake-root E2E.
   - Extend `scripts/e2e-guest-tools-installer.sh`.
   - Assert `--private-dhcp` is passed by the wrapper.
   - Assert the generated `.network` file contains `DHCP=ipv4`.
   - Assert `UseRoutes=false` and no `Address=` line.
   - Assert existing manual network files are preserved.
   - Assert static `--private-ip` still works.

3. Headless VM E2E.
   - Add `--private-network-dhcp` to `HeadlessBootTest`.
   - Add DHCP initramfs fixtures in `scripts/prepare-e2e-linux.sh`.
   - Run with isolated `OKRUN_HOME`.
   - In the guest, bring up the private NIC with BusyBox `udhcpc`.
   - Print the acquired IP to serial output.
   - Assert one VM receives an address inside the configured range.
   - Assert two VMs receive different addresses and can ping each other.
   - Assert no default route is installed on the private NIC.

4. Regression E2E.
   - Existing static private network ping test must still pass.
   - Boot without an existing DHCP config must create the default host config and start DHCP for the private network.

## Acceptance Criteria

- A fresh guest can configure the private NIC without static IP instructions.
- DHCP policy is stored under `~/.okrun`, not in `okrun-vm.json`.
- Static private IP setup remains supported.
- Guest internet routing still uses the NAT NIC.
- DHCP leases survive VM restart when the client identity is stable.
- All shell, unit, and headless E2E tests pass locally.
