# OkRun Web Switch

`web-switch` is the layer-2 switch used by OkRun private networks. Web Switch
hosts connect outbound with mTLS client certificates. Local Switch hosts can
connect to a plain TCP listener on a trusted local network without TLS
credentials. Both listeners use the same switch protocol and fabric.

## Certificate Scripts

Run these from the `web-switch` directory. Each script also has an `npm run` alias.

Create or reuse a local CA:

```bash
./init-ca.sh
# or
npm run cert:init
```

This writes:

- `.ca/ca-cert.pem`
- `.ca/ca-key.pem`
- `.ca/crl.txt`

Issue the server TLS bundle:

```bash
./issue-server.sh switch.example.com
# or
npm run cert:server -- switch.example.com
```

For local development:

```bash
npm run cert:server -- localhost
```

This writes:

- `.certs/server/okrun-switch-server-bundle.json`

The server bundle contains the CA public certificate, server certificate, and server private key. Keep it private.

Issue an OkRun host/client bundle and print a UI-ready bundle:

```bash
./issue-client.sh arun-mac switch.example.com:9443
# or
npm run cert:client -- arun-mac switch.example.com:9443
# alias
npm run cert:host -- arun-mac switch.example.com:9443
```

This writes:

- `.certs/hosts/arun-mac/okrun-switch-bundle.json`

Paste the printed JSON into OkRun's Private Network panel under Web Switch > Host Bundle JSON.

Use `--certs-dir` to keep multiple environments side by side. A cert root stores
`ca/`, `server/`, and `hosts/` under one directory:

```bash
npm run cert:init -- --certs-dir .certs/prod
npm run cert:server -- --certs-dir .certs/prod switch.example.com
npm run cert:host -- --certs-dir .certs/prod arun-mac switch.example.com:9443
```

For a two-host local setup:

```bash
./generate-local-certs.sh
# or
npm run cert:local

# custom root
npm run cert:local -- --certs-dir .certs/local
```

## Starting Locally

```bash
npm run start -- \
  --host 127.0.0.1 \
  --tls-port 9443 \
  --local-port 9444 \
  --status-port 8080 \
  --server-bundle .certs/server/okrun-switch-server-bundle.json \
  --crl .ca/crl.txt
```

For a Local Switch only listener, disable the TLS listener and provide a local
port:

```bash
npm run start -- \
  --host 127.0.0.1 \
  --tls-enabled false \
  --local-port 9444 \
  --status-port 8080
```

The equivalent environment variables are `OKRUN_SWITCH_TLS_ENABLED=false` and
`OKRUN_SWITCH_LOCAL_PORT=9444`.

Local Switch uses shorter keepalives by default so clients can fall back quickly
when a LAN peer disappears. Tune them with
`OKRUN_SWITCH_LOCAL_KEEPALIVE_INTERVAL_MS` and
`OKRUN_SWITCH_LOCAL_KEEPALIVE_TIMEOUT_MS`.

Health and status:

```bash
curl http://127.0.0.1:8080/healthz
curl http://127.0.0.1:8080/status
```

Safety limits are enabled by default and can be tuned per deployment:

```bash
OKRUN_SWITCH_RATE_LIMIT_FRAMES_PER_SECOND=20000
OKRUN_SWITCH_RATE_LIMIT_BYTES_PER_SECOND=134217728
OKRUN_SWITCH_RATE_LIMIT_BROADCAST_FRAMES_PER_SECOND=2000
OKRUN_SWITCH_RATE_LIMIT_MULTICAST_FRAMES_PER_SECOND=5000
OKRUN_SWITCH_RATE_LIMIT_UNKNOWN_UNICAST_FRAMES_PER_SECOND=5000
OKRUN_SWITCH_MAX_PENDING_WRITES=256
OKRUN_SWITCH_MAX_PENDING_BYTES=4194304
```

Set a rate limit to `0` to disable that specific limiter. Dropped frames and
drop reasons are included in `/status` per host.

## UDP Accelerated Transport

Web Switch negotiates an encrypted UDP data plane for Ethernet `DATA` frames
when a client opts in, while keeping the existing TCP/TLS connection as the
control plane and compatibility fallback.

UDP is enabled by default whenever the mTLS listener is enabled, so the server
needs no extra enable flag. By default it listens on the same numeric port as
TLS. Tune it, or disable it explicitly, with:

```bash
OKRUN_SWITCH_UDP_ENABLED=false
OKRUN_SWITCH_UDP_PORT=9443
OKRUN_SWITCH_UDP_MTU=1200
OKRUN_SWITCH_UDP_MIN_MTU=1200
OKRUN_SWITCH_UDP_MAX_PROBE_MTU=1450
OKRUN_SWITCH_UDP_INITIAL_MBPS=10
OKRUN_SWITCH_UDP_MIN_MBPS=0.25
OKRUN_SWITCH_UDP_MAX_MBPS=0
OKRUN_SWITCH_UDP_QUEUE_BYTES=4194304
OKRUN_SWITCH_UDP_REASSEMBLY_SESSION_BYTES=1048576
OKRUN_SWITCH_UDP_REASSEMBLY_GLOBAL_BYTES=67108864
OKRUN_SWITCH_UDP_RECV_BUFFER_BYTES=4194304
OKRUN_SWITCH_UDP_SEND_BUFFER_BYTES=4194304
```

New clients advertise `udp-data-v1` in `INIT` and receive a `dataPlane` block in
`INIT` ACK when UDP is available. Clients that choose **UDP Accelerated** require
UDP and are rejected/fail closed if the data plane is unavailable; **Auto** clients
fall back to TCP/TLS.

The UDP path uses AES-256-GCM with keys derived from random material exchanged
over the authenticated TLS control channel. v1 uses one key per UDP session
(`keyId: 1`); reconnect to rekey. UDP packets include replay protection, endpoint
validation, fixed-MTU fragmentation/reassembly, static token-bucket pacing,
bounded queues, and bounded fragment reassembly. `/status` includes UDP socket,
session, queue, reassembly, and drop counters when UDP is enabled.

Current v1 scope:

- IPv4 UDP listener/client paths only.
- Fixed configured MTU (`OKRUN_SWITCH_UDP_MTU`, default `1200`); adaptive PMTU
  probing is disabled in v1. PMTU probe packets are ignored and
  `OKRUN_SWITCH_UDP_MAX_PROBE_MTU` is reserved for future probing.
- Static pacing only; no loss/RTT/bandwidth-based congestion control yet.
- No mid-session key rotation; reconnecting creates fresh UDP keys.

## Deploying To A Linux VM

Create the deploy config:

```bash
cp .deploy.switch.example .deploy.switch
```

Edit `.deploy.switch` with the VM SSH target, switch hostname, and repo URL.
Then create the server certificate locally and deploy it:

```bash
npm run cert:init -- --certs-dir .certs/prod
npm run cert:server -- --certs-dir .certs/prod switch.example.com
./scripts/deploy/setup-server.sh deploy@switch.example.com --upload-certs .certs/prod
```

`--upload-certs` does not auto-detect local certs. Pass the cert root explicitly,
or set `CERTS_DIR=.certs/prod` in `.deploy.switch`. If you keep CA and server
certs in separate directories, use `--server-cert-dir <dir> --ca-dir <dir>`.

Later code updates can reuse the remote certificates:

```bash
./scripts/deploy/setup-server.sh deploy@switch.example.com
```

The setup installs Node.js, clones/updates the repo under
`/opt/okrun-switch/source`, runs `okrun-switch` with systemd, and configures UFW
to allow only SSH plus the switch mTLS port. The status HTTP port is for local
health checks and SSH access; it is not opened in the firewall.

## Deploying a Local Switch to a Mac

For a trusted local network, deploy a non-TLS `okrun-switch` as a macOS
LaunchAgent. Create the deploy config:

```bash
cp .deploy.local.example .deploy.local
```

Edit `.deploy.local` with the Mac SSH target, repo URL, and listener ports:

```
REPO_URL=https://github.com/okbrainhq/okrun.git
DEPLOY_HOST=arun@macbook.local
LOCAL_PORT=9444
STATUS_PORT=8080
HOST=127.0.0.1
```

Deploy:

```bash
./scripts/deploy/setup-local.sh
```

Or pass the host on the command line:

```bash
./scripts/deploy/setup-local.sh arun@macbook.local
```

The setup installs Node.js to `~/.local`, clones/updates the repo under
`~/okrun-switch`, and runs the local switch as a LaunchAgent. It listens on a
plain TCP port (no mTLS), so it should only be used on a trusted LAN.

Later code updates can be redeployed the same way:

```bash
./scripts/deploy/setup-local.sh
```

## Revoking A Host

```bash
./revoke-host.sh <certificate-serial>
# or
npm run cert:revoke -- <certificate-serial>

# custom root
npm run cert:revoke -- --certs-dir .certs/prod <certificate-serial>
```

The switch reads the CA directory's `crl.txt`; restart or redeploy the switch
after updating the CRL.

## Tests

```bash
npm test
```
