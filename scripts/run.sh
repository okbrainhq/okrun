#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Parse environment flag (default: dev)
ENV="dev"
for arg in "$@"; do
  case "$arg" in
    --prod) ENV="prod" ;;
    --dev)  ENV="dev" ;;
  esac
done

if [[ "$ENV" == "dev" ]]; then
  APP="$ROOT/OkrunVM-Dev.app"
else
  APP="$ROOT/OkrunVM.app"
fi

if [[ ! -d "$APP" ]]; then
  "$ROOT/scripts/build.sh" "--$ENV"
fi

# Use -n for dev so it can run alongside prod without conflicts
if [[ "$ENV" == "dev" ]]; then
  open -n "$APP"
else
  open "$APP"
fi
