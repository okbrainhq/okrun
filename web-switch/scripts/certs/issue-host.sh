#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 1 ]; then
  echo "usage: $0 <host-name> [server-host:port]" >&2
  exit 1
fi

HOST_NAME="$1"
SERVER="${2:-localhost:9443}"

cd "$(dirname "$0")/../.."

npm run ca -- issue-host --name "$HOST_NAME" --output "./.certs/hosts/$HOST_NAME"
npm run ca -- print-host-bundle --input "./.certs/hosts/$HOST_NAME" --server "$SERVER"
