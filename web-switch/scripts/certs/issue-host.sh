#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -lt 1 ]]; then
  echo "usage: $0 <host-name> [server-host:port] [output-dir] [ca-dir]" >&2
  echo "       $0 --certs-dir <dir> <host-name> [server-host:port]" >&2
  exit 1
fi

exec "$(dirname "$0")/../../issue-client.sh" "$@"
