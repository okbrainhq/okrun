#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [[ ! -d "$ROOT/OkrunVM.app" ]]; then
  "$ROOT/scripts/build.sh"
fi

open "$ROOT/OkrunVM.app"
