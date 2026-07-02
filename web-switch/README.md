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

## Linux Access Port

On a Linux cloud switch host, `web-switch` can join one private network through a
real TAP interface. This lets a normal SSH login on the cloud host reach private
hosts by IP, and `.local` names when mDNS/NSS is configured on that Linux host.

```bash
sudo npm run start -- \
  --tls-port 9443 \
  --status-port 8080 \
  --server-bundle .certs/server/okrun-switch-server-bundle.json \
  --crl .ca/crl.txt \
  --access-network okrun \
  --access-iface oksw0 \
  --access-ip 10.77.0.1/24
```

Equivalent environment variables:

```bash
OKRUN_SWITCH_ACCESS_NETWORK=okrun
OKRUN_SWITCH_ACCESS_IFACE=oksw0
OKRUN_SWITCH_ACCESS_IP=10.77.0.1/24
```

`OKRUN_SWITCH_ACCESS_NETWORK` must match the exact `networkIdentifier` used by
the VM clients. For the current deployment that network is `okrun`; if the access
port joins `okrun-prod` while clients join `okrun`, the TAP interface will be
alone and ARP/ping/SSH to private hosts will fail.

The access port requires Linux `/dev/net/tun`, `iproute2`, and root or
`CAP_NET_ADMIN`. It is disabled by default. Treat the cloud host as a full L2
member of the selected private network while this is enabled.

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

## Deploying To A Linux VM

Create the deploy config:

```bash
cp .deploy.switch.example .deploy.switch
```

Edit `.deploy.switch` with the VM SSH target, switch hostname, and repo URL.
To expose a private network from the cloud host, also set the optional TAP access
variables:

```bash
SWITCH_ACCESS_NETWORK=okrun
SWITCH_ACCESS_IFACE=oksw0
SWITCH_ACCESS_IP=10.77.0.1/24
SWITCH_ACCESS_MTU=1500
```

`SWITCH_ACCESS_NETWORK` is not an environment label; it is the switch fabric
network name. It must match the VM clients' `networkIdentifier` shown in
`/status`.

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

The setup installs Node.js, Python 3, iproute2, avahi-daemon, and libnss-mdns,
clones/updates the repo under
`/opt/okrun-switch/source`, runs `okrun-switch` with systemd, and configures UFW
to allow only SSH plus the switch mTLS port. If `SWITCH_ACCESS_NETWORK` is set,
the systemd unit grants `CAP_NET_ADMIN` so the TAP helper can create the access
interface. The status HTTP port is for local health checks and SSH access; it is
not opened in the firewall.

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

Linux TAP access-port E2E runs on a Linux host with passwordless sudo:

```bash
../scripts/e2e-web-switch-access-linux.sh
# or from macOS, after SSH auth is available:
../scripts/e2e-web-switch-access-remote.sh arunoda@devbox-sandbox.local
```
