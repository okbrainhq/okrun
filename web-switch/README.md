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

Health and status:

```bash
curl http://127.0.0.1:8080/healthz
curl http://127.0.0.1:8080/status
```

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
