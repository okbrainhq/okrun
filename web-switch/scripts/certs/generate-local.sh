#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."

npm run ca -- init
npm run ca -- issue-server --hostname localhost --output ./.certs/server
npm run ca -- issue-host --name host-a --output ./.certs/hosts/host-a
npm run ca -- issue-host --name host-b --output ./.certs/hosts/host-b

cat <<'MSG'

Local switch certificates are ready.

Run the server:
  npm run dev

Run e2e tests:
  npm test
MSG
