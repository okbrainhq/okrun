# Deployment and Key Script Design

## Goal

Make `okrun-switch` deployable with a small set of predictable commands. This should feel like okproxy's deployment flow, but named for OkRun and focused on the cloud switch.

## Files to add

```text
web-switch/
  .deploy.switch.example
  bin/
    okrun-switch-ca.js
  scripts/
    certs/
      generate-local.sh
      issue-host.sh
      revoke-host.sh
    deploy/
      setup-server.sh
      setup-server-remote.sh
```

## package.json scripts

```json
{
  "scripts": {
    "start": "node src/index.js",
    "dev": "node src/index.js --tls-port 9443 --status-port 8080",
    "test": "node tests/e2e/run.js",
    "ca": "node bin/okrun-switch-ca.js"
  },
  "bin": {
    "okrun-switch-ca": "bin/okrun-switch-ca.js"
  }
}
```

## .deploy.switch

Example:

```bash
# Required
HOSTNAME=switch.example.com
REPO_URL=https://github.com/okbrainhq/okrun.git

# Optional
DEPLOY_HOST=deploy@switch.example.com
SSH_PORT=22
SWITCH_TLS_PORT=9443
SWITCH_STATUS_PORT=8080
```

## CA CLI

Commands:

```bash
npm run ca -- init
npm run ca -- issue-server --hostname switch.example.com --output ./.certs/server
npm run ca -- issue-host --name arun-mac --output ./.certs/hosts/arun-mac
npm run ca -- print-host-bundle --input ./.certs/hosts/arun-mac --server switch.example.com:9443
npm run ca -- list
npm run ca -- revoke --serial 42
```

Implementation details:

- Use `openssl` through `execFileSync`, not shell string interpolation.
- Generate CA key as 4096-bit RSA with `0600` permissions.
- Generate server and client keys as 2048-bit RSA or stronger.
- Server cert includes SAN for DNS/IP hostname.
- Client cert CN can be `okrun-host:<name>`; identity still comes from serial/fingerprint.
- Track issued certs in `.ca/issued.txt`.
- Track revoked certs in `.ca/crl.txt`.
- The server reloads CRL or caches it with mtime checks like okproxy.

## Host bundle

The host bundle is for copy/paste into OkRun UI.

```json
{
  "server": "switch.example.com:9443",
  "caCertPem": "-----BEGIN CERTIFICATE-----\n...\n-----END CERTIFICATE-----\n",
  "clientCertPem": "-----BEGIN CERTIFICATE-----\n...\n-----END CERTIFICATE-----\n",
  "clientKeyPem": "-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----\n"
}
```

Rules:

- Never include server private key.
- Include the server address so UI can fill it automatically.
- JSON output avoids users needing to paste three separate boxes, while the UI can still support separate PEM fields.

## Local dev script

`scripts/certs/generate-local.sh`:

```bash
./scripts/certs/generate-local.sh
```

Creates:

```text
.ca/
.certs/server/
.certs/hosts/host-a/
.certs/hosts/host-b/
```

It should issue a localhost server cert and two host certs, then print the commands for running server-only E2E.

## Host issue script

`scripts/certs/issue-host.sh arun-mac` should wrap:

```bash
npm run ca -- issue-host --name arun-mac --output ./.certs/hosts/arun-mac
npm run ca -- print-host-bundle --input ./.certs/hosts/arun-mac
```

The output is intended to be pasted into OkRun's Cloud Switch certificate section.

## Revoke script

`scripts/certs/revoke-host.sh <serial>`:

- Adds the serial to `.ca/crl.txt`.
- Prints deployment instructions to upload refreshed CRL.
- Optional follow-up: `--deploy deploy@switch.example.com` copies the CRL to `/opt/okrun-switch/certs/crl.txt` and restarts/reloads the service.

## Server deployment script

`scripts/deploy/setup-server.sh`:

- Reads `.deploy.switch`.
- Accepts `[USER@HOST]`, `--upload-certs`, and optional `--restart-only`.
- Validates required local certificate files before upload.
- Uploads certs to `/opt/okrun-switch/certs`.
- Copies `setup-server-remote.sh`.
- Runs the remote script via SSH.

Important local checks:

```text
.certs/server/server-cert.pem
.certs/server/server-key.pem
.ca/ca-cert.pem
.ca/crl.txt
```

## Remote setup script

`scripts/deploy/setup-server-remote.sh`:

- Create `/opt/okrun-switch`.
- Install Node.js 20+ if absent.
- Clone or update `REPO_URL`.
- Run install in `web-switch`.
- Write a systemd unit.
- Start and enable `okrun-switch`.

Service environment:

```text
OKRUN_SWITCH_TLS_PORT=9443
OKRUN_SWITCH_STATUS_PORT=8080
OKRUN_SWITCH_SERVER_KEY=/opt/okrun-switch/certs/server-key.pem
OKRUN_SWITCH_SERVER_CERT=/opt/okrun-switch/certs/server-cert.pem
OKRUN_SWITCH_CA_CERT=/opt/okrun-switch/certs/ca-cert.pem
OKRUN_SWITCH_CRL=/opt/okrun-switch/certs/crl.txt
```

## First deployment flow

```bash
cd web-switch
cp .deploy.switch.example .deploy.switch
npm run ca -- init
npm run ca -- issue-server --hostname switch.example.com --output ./.certs/server
npm run ca -- issue-host --name arun-mac --output ./.certs/hosts/arun-mac
./scripts/deploy/setup-server.sh deploy@switch.example.com --upload-certs
npm run ca -- print-host-bundle --input ./.certs/hosts/arun-mac --server switch.example.com:9443
```

## Update deployment flow

```bash
cd web-switch
./scripts/deploy/setup-server.sh deploy@switch.example.com
```

## Revocation flow

```bash
cd web-switch
npm run ca -- revoke --serial 42
./scripts/deploy/setup-server.sh deploy@switch.example.com --upload-certs
```

Later, add a lightweight `reload-crl` path so code deployment is not required for revocations.

