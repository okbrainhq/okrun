#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACT_DIR="${ARTIFACT_DIR:-$ROOT/.e2e/asif-import}"
APP_BINARY="$ROOT/OkrunVM.app/Contents/MacOS/OkrunVM"

if [[ ! -x /usr/sbin/diskutil ]]; then
  printf 'SKIP ASIF import E2E: diskutil is unavailable\n'
  exit 0
fi

"$ROOT/scripts/build.sh"

rm -rf "$ARTIFACT_DIR"
mkdir -p "$ARTIFACT_DIR"

SOURCE_ASIF="$ARTIFACT_DIR/source.asif"
PROJECT_ROOT="$ARTIFACT_DIR/imported-vm"
REGISTRY_PATH="$ARTIFACT_DIR/registry.json"
CREATE_LOG="$ARTIFACT_DIR/create-asif.log"

if ! /usr/sbin/diskutil image create blank --fs none --format ASIF --size 1537m "$SOURCE_ASIF" >"$CREATE_LOG" 2>&1; then
  printf 'SKIP ASIF import E2E: ASIF disk creation is unavailable\n'
  sed -n '1,80p' "$CREATE_LOG"
  exit 0
fi

"$APP_BINARY" \
  --headless-import-asif \
  --source-asif "$SOURCE_ASIF" \
  --project-root "$PROJECT_ROOT" \
  --registry-path "$REGISTRY_PATH"

[[ -f "$PROJECT_ROOT/okrun-vm.json" ]]
[[ -f "$PROJECT_ROOT/vm/linux.asif" ]]
[[ -f "$PROJECT_ROOT/vm/efi.variables" ]]
[[ -f "$PROJECT_ROOT/vm/machine.identifier" ]]
grep -Fq '"diskFormat" : "asif"' "$PROJECT_ROOT/okrun-vm.json"
grep -Fq '"diskGB" : 2' "$PROJECT_ROOT/okrun-vm.json"
grep -Fq 'imported-vm' "$REGISTRY_PATH"
grep -Fq '"selectedProject"' "$REGISTRY_PATH"

printf 'ASIF import E2E passed.\n'
printf 'Artifacts: %s\n' "$ARTIFACT_DIR"
