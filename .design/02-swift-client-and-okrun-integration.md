# Swift Client and OkRun Integration Design

## Summary

After the standalone server passes E2E, add a Swift client that connects OkRun's existing private network runtime to the cloud switch.

The guest VM should not know anything changed. It still gets the same second Virtio network device backed by `PrivateNetworkRuntime`.

## New Swift types

`SwitchFrameProtocol`

- Encodes and decodes the 13-byte okproxy-style frame header.
- Handles partial TCP reads.
- Enforces max payload length.
- Produces frames with `streamId`, `type`, `seqNo`, and `payload`.

`SwitchDedupWindow`

- Swift port of okproxy's 128-bit sliding dedup window.
- Used by `VirtualSwitchSocket` to drop duplicate DATA frames when multipath is enabled.

`RealSwitchSocket`

- Owns one TLS connection to the switch server.
- Sends INIT after TLS connect.
- Handles PING/PONG, INIT ACK, reconnect, and write backpressure.
- Emits decoded DATA payloads upward.

`VirtualSwitchSocket`

- Owns one or more `RealSwitchSocket` instances.
- Sends each DATA frame over every connected real socket.
- Assigns per-stream sequence numbers.
- Deduplicates inbound DATA frames.
- Presents a single logical `send(frame:)` and `onFrame` API.

`PrivateNetworkSwitchBridge`

- Mirrors the role of `PrivateNetworkBridge`, but remote transport is the cloud switch instead of direct TCP peers.
- Registers `PrivateNetworkRuntime` observers.
- Sends frames from guests to the switch.
- Injects switch frames into local guests.
- Tracks local MACs to avoid sending known-local unicast frames to the switch.

## TLS client identity

Network.framework is the preferred transport:

- `NWConnection` to `host:port` over TCP with TLS options.
- Configure trust roots from `caCert`.
- Configure client identity from a keychain identity or imported PKCS#12.

The config can start with PEM paths because that mirrors okproxy, but implementation may need a small import layer:

- Read `clientCert` and `clientKey` PEM.
- Create a temporary keychain identity or require a `.p12` export.
- Long term, provide an `okrun switch cert import` helper.

Implementation should hide this behind `SwitchTLSIdentity` so the config shape can evolve.

## Config model

Extend `HostPrivateNetworkConfig`:

```swift
struct HostPrivateNetworkConfig: Codable, Equatable {
    var dhcp: PrivateNetworkDHCPConfig?
    var bridge: PrivateNetworkBridgeConfig?
    var `switch`: PrivateNetworkSwitchConfig?
}
```

Suggested config:

```json
{
  "version": 1,
  "privateNetworks": {
    "okrun": {
      "dhcp": {
        "enabled": true,
        "mode": "range",
        "cidr": "10.77.0.0/24",
        "rangeStart": "10.77.0.20",
        "rangeEnd": "10.77.0.200",
        "leaseSeconds": 3600
      },
      "switch": {
        "enabled": true,
        "server": "switch.example.com:9443",
        "caCert": "/Users/me/.okrun/switch/ca-cert.pem",
        "clientCert": "/Users/me/.okrun/switch/client-cert.pem",
        "clientKey": "/Users/me/.okrun/switch/client-key.pem",
        "multipath": false
      }
    }
  }
}
```

Paste-mode UI writes the PEM blocks to files and stores the same path-based shape in JSON. The config file should not embed private key material by default.

Validation:

- `server` must be `host:port`.
- `port` must be 1...65535.
- cert/key/CA paths must be non-empty when `enabled` is true.
- For MVP, reject configs that enable both direct `bridge` and cloud `switch` for the same private network.

## Config UI certificate section

Extend `NetworkConfigUI` with a Cloud Switch section after Bridge Settings.

Controls:

- Cloud Switch checkbox.
- Server field.
- Certificate mode segmented control: Paste, Files.
- Paste mode text areas:
  - CA certificate PEM
  - Client certificate PEM
  - Client private key PEM
- Files mode fields:
  - CA certificate path
  - Client certificate path
  - Client key path
- Save/Apply validates and writes the selected mode.

Paste mode behavior:

- Validate PEM block headers before saving.
- Write to `~/.okrun/switch/<networkIdentifier>/ca-cert.pem`.
- Write to `~/.okrun/switch/<networkIdentifier>/client-cert.pem`.
- Write to `~/.okrun/switch/<networkIdentifier>/client-key.pem`.
- Set private key permissions to `0600`.
- Store only paths in `private-networks.json`.
- Clear text fields after successful save or replace them with a short "saved" status so the private key is not left sitting in UI state longer than needed.

Status hints:

- Missing CA/client cert/client key.
- Client cert expiry if easy to parse.
- Connected, connecting, rejected, or failed.
- Last server error, for example DHCP overlap or revoked certificate.


## Runtime registry changes

Current shape:

- `NetworkDeviceFactory.makePrivateNetworkDevice` creates a `PrivateNetworkRuntime`.
- It creates a host DHCP server if DHCP is enabled.
- It asks `PrivateNetworkRuntimeRegistry.shared.retain(runtime, bridgeConfig, dhcpRange)`.
- Registry keeps local runtimes and one direct `PrivateNetworkBridge` per identifier.

Target shape:

- Add `switchConfig` as another optional transport config.
- Registry decides whether to retain a direct bridge or a switch bridge.
- `PrivateNetworkSwitchBridge` is keyed by private network identifier.
- Multiple runtimes with the same identifier attach to the same switch bridge.

This keeps local multi-VM behavior intact: local frames still broadcast through `PrivateNetworkRuntime`; the switch bridge only handles frames leaving or entering the host.

## Frame flow

Guest to remote host:

1. Guest writes Ethernet frame to private NIC.
2. `PrivateNetworkRuntime.readGuestFrames` notifies observers.
3. `PrivateNetworkSwitchBridge` sees `.fromGuest`.
4. It learns the local source MAC.
5. It skips known-local unicast destinations.
6. It sends raw Ethernet payload as switch DATA.
7. Server learns source MAC and forwards.

Remote host to guest:

1. `VirtualSwitchSocket` receives DATA once after dedup.
2. `PrivateNetworkSwitchBridge` calls `runtime.injectFrameToGuest(frame)`.
3. Each local runtime on that private network receives the frame.

## Status model

Add status types parallel to the current bridge status:

- `PrivateNetworkSwitchConnectionState`: connecting, connected, failed, rejected.
- `PrivateNetworkSwitchStatus`: identifier, server, isConnected, activeConnections, message, error.

Expose through `PrivateNetworkRuntimeRegistry` so the existing Network Config UI can show:

- disabled
- connecting to server
- connected with one or more sockets
- rejected by server, including network mismatch or DHCP overlap
- failed with retry/backoff message

## Unit tests

Add Swift tests before full integration:

- frame encode/decode round trip
- decoder handles partial frame chunks
- oversized frame throws
- dedup window drops duplicates and accepts out-of-order frames inside the window
- switch config loads and validates
- enabling both direct bridge and cloud switch is rejected for MVP

## Integration test without full VM

Use existing `PrivateNetworkRuntime` in tests:

- Start `web-switch` on localhost with temp certs.
- Create two `PrivateNetworkRuntime` instances with different identifiers or host sessions.
- Attach each runtime to its own `PrivateNetworkSwitchBridge`.
- Send an Ethernet frame into runtime A's file handle.
- Assert runtime B receives it.
- Assert learned unicast avoids sending to unrelated runtime C.

This mirrors the current direct bridge tests and avoids full VM boot time while proving the runtime path.
