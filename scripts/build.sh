#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/OkrunVM.app"
BINARY="$ROOT/.build/release/OkrunVM"

cd "$ROOT"
swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BINARY" "$APP/Contents/MacOS/OkrunVM"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"

codesign --force --sign - --entitlements "$ROOT/OkrunVM.entitlements" "$APP"

echo "Built $APP"
