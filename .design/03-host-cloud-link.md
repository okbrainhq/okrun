# Host Cloud Link

## Objective

Connect the OkRUn host app to the cloud relay so private VM Ethernet frames can move between Macs. In this phase, each host uses a configured DHCP pool. The relay rejects duplicate pools in the same network.

## Config Shape

Project `okrun-vm.json` stays small:

```json
{
  "privateNetwork": {
    "enabled": true,
    "identifier": "team-a-local"
  }
}
```

Host policy lives in `~/.okrun/private-networks.json` and maps that local identifier to DHCP/cloud settings:

```json
{
  "version": 1,
  "privateNetworks": {
    "team-a-local": {
      "dhcp": {
        "enabled": true,
        "mode": "range",
        "cidr": "10.77.0.0/16",
        "rangeStart": "10.77.12.20",
        "rangeEnd": "10.77.12.200",
        "leaseSeconds": 3600
      },
      "cloud": {
        "enabled": true,
        "server": "vnet.example.com:9443",
        "networkId": "team-a",
        "hostId": "macbook-a",
        "poolCidr": "10.77.12.0/24",
        "caCertPath": "~/.okrun/certs/ca-cert.pem",
        "clientCertPath": "~/.okrun/certs/client-cert.pem",
        "clientKeyPath": "~/.okrun/certs/client-key.pem"
      }
    }
  }
}
```

`privateNetwork.identifier` remains the local Unix-socket bus name and host-config lookup key. `cloud.networkId` is the distributed network name and may differ.

## Architecture

Add a cloud bridge peer to the existing local private bus:

```text
Local VM A private NIC
       |
PrivateNetworkRuntime
       |
/tmp/okrun-vnet/<identifier>/*.sock
       |
PrivateNetworkCloudBridge peer
       |
mTLS connection
       |
Cloud relay
       |
Remote host cloud bridge
       |
Remote VM private NIC
```

The cloud bridge should be a peer on the same Unix datagram bus as VMs. That avoids special-casing VM runtimes and lets local VM-to-VM behavior continue unchanged.

## Host Implementation Plan

1. Factor local bus operations.
   - Extract common Unix datagram socket path handling from `PrivateNetworkRuntime`.
   - Add `OKRUN_VNET_ROOT` env override for tests. Default remains `/tmp/okrun-vnet`.
   - Provide helpers to bind a peer socket, list peers, send to a peer, and broadcast to peers except self.

2. Add `PrivateNetworkCloudBridge`.
   - Binds its own `.sock` file inside the local network directory.
   - Reads local VM frames broadcast by existing runtimes.
   - Sends eligible local frames to the cloud relay.
   - Receives cloud frames and broadcasts them to local VM peers.
   - Does not feed cloud-origin frames back to the cloud.

3. Add cloud client transport.
   - Swift `Network.framework` TLS client or a small helper process are both viable; prefer Swift in-process if mTLS file loading is straightforward.
   - Use the phase 2 frame protocol.
   - INIT includes `networkId`, `hostId`, and `poolCidr`.
   - Reconnect with bounded exponential backoff.
   - PING/PONG keepalive.
   - Surface connection state in logs and optionally the UI status line.

4. Add forwarding filters.
   - Forward ARP, IPv4, IPv6, and multicast frames by default.
   - Drop local DHCP client broadcasts from cloud forwarding when host DHCP is enabled, because DHCP is local to each host pool in this phase.
   - Drop inbound cloud DHCP frames by default.
   - Add counters for forwarded, dropped, oversized, and errored frames.

5. Add lifecycle management.
   - One cloud bridge per local private network identifier and cloud network ID.
   - Reference count it across VM sessions in the same app.
   - Stop it when no running VM needs that network.

6. Add host config integration.
   - Load cloud settings from `~/.okrun/private-networks.json` using the VM's private network identifier.
   - Use `OKRUN_HOME` for isolated local E2E.
   - Keep cloud and DHCP disabled if no host policy exists for the identifier.

7. Add cloud duplicate-pool handling.
   - If the relay rejects `poolCidr`, show a clear error and keep local-only private networking running.
   - DHCP should not start for cloud mode if the configured local pool conflicts with cloud acceptance.

## Local E2E Test Plan

1. Isolated local buses.
   - Add `OKRUN_VNET_ROOT` support.
   - Start two host processes with different vnet roots on the same Mac.
   - Without cloud, assert VMs in different roots cannot ping each other.

2. Cloud bridge packet test without VMs.
   - Start local relay.
   - Start two `PrivateNetworkCloudBridge` instances with different vnet roots.
   - Send a synthetic Ethernet frame into one local bus.
   - Assert the other local bus receives exact bytes.
   - Assert origin bus does not receive an echo.

3. Headless VM cross-host test.
   - Start local relay with test certs.
   - Run each simulated host with its own `OKRUN_HOME`.
   - Start server VM in host root A with DHCP pool `10.77.12.0/24`.
   - Start client VM in host root B with DHCP pool `10.77.44.0/24`.
   - Guests use DHCP.
   - Assert each guest gets an address from its host pool.
   - Assert client can ping server across the local relay.

4. Pool conflict test.
   - Start relay.
   - Start host A with `poolCidr=10.77.12.0/24`.
   - Start host B with the same pool.
   - Assert host B cloud link is rejected with a duplicate-pool error.
   - Assert host B local-only private networking still works.

5. Reconnect test.
   - Start two hosts and relay.
   - Stop relay, assert local VMs keep their local private network.
   - Restart relay, assert host links reconnect and cross-host ping resumes.

## Acceptance Criteria

- Two simulated hosts on one Mac can communicate only through the relay.
- Configured pools are enforced by the relay.
- DHCP and cloud settings are read from `~/.okrun`, not project `okrun-vm.json`.
- DHCP remains local to each host pool.
- Cloud outage does not break same-host private networking.
- Existing local private-network E2E still passes.
