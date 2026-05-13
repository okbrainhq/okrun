#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export CLANG_MODULE_CACHE_PATH="$ROOT/.build/clang-module-cache"
export SWIFTPM_HOME="$ROOT/.build/swiftpm-home"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_HOME"

run_e2e() {
  local name="$1"
  shift

  local start="$SECONDS"

  printf '\n==> %s\n' "$name"
  if "$@"; then
    printf 'OK  %s (%ss)\n' "$name" "$((SECONDS - start))"
    return 0
  fi

  local status="$?"
  printf 'FAIL %s (%ss)\n' "$name" "$((SECONDS - start))" >&2
  return "$status"
}

(cd "$ROOT" && swift test --disable-sandbox)
run_e2e "Guest tools installer E2E" "$ROOT/scripts/e2e-guest-tools-installer.sh"
run_e2e "Headless boot E2E" "$ROOT/scripts/e2e-headless-boot.sh"
printf '\nAll tests passed.\n'
