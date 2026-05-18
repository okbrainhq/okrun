#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

./init-ca.sh .ca
./issue-server.sh localhost .certs/server .ca
./issue-client.sh host-a localhost:9443 .certs/hosts/host-a .ca
./issue-client.sh host-b localhost:9443 .certs/hosts/host-b .ca

cat <<'MSG'

Local switch bundles are ready.

Server bundle:
  .certs/server/okrun-switch-server-bundle.json

Host bundles:
  .certs/hosts/host-a/okrun-switch-bundle.json
  .certs/hosts/host-b/okrun-switch-bundle.json

Run the server:
  npm run dev

Run e2e tests:
  npm test
MSG
