#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export CLANG_MODULE_CACHE_PATH="$ROOT/.build/clang-module-cache"
export SWIFTPM_HOME="$ROOT/.build/swiftpm-home"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_HOME"

SWIFT_TEST_ARGS=(--disable-sandbox)
SWIFT_TESTING_FRAMEWORK_DIR="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
SWIFT_TESTING_LIB_DIR="/Library/Developer/CommandLineTools/Library/Developer/usr/lib"

if [[ -d "$SWIFT_TESTING_FRAMEWORK_DIR/Testing.framework" && -f "$SWIFT_TESTING_LIB_DIR/lib_TestingInterop.dylib" ]]; then
  SWIFT_TEST_ARGS+=(
    -Xswiftc "-F$SWIFT_TESTING_FRAMEWORK_DIR"
    -Xlinker "-F$SWIFT_TESTING_FRAMEWORK_DIR"
    -Xlinker -rpath
    -Xlinker "$SWIFT_TESTING_FRAMEWORK_DIR"
    -Xlinker -rpath
    -Xlinker "$SWIFT_TESTING_LIB_DIR"
  )
fi

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

(cd "$ROOT" && swift test "${SWIFT_TEST_ARGS[@]}")
run_e2e "Guest tools installer E2E" "$ROOT/scripts/e2e-guest-tools-installer.sh"
run_e2e "Headless boot E2E" "$ROOT/scripts/e2e-headless-boot.sh"
run_e2e "Headless switch E2E" "$ROOT/scripts/e2e-switch-headless.sh"
printf '\nAll tests passed.\n'
