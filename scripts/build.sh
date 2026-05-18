#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/OkrunVM.app"
BINARY="$ROOT/.build/release/OkrunVM"

cd "$ROOT"

# Local builds must not use a Developer ID / Apple Development certificate.
# The final app is ad-hoc signed below so it can carry the virtualization
# entitlement without touching the user's login keychain.
export CODE_SIGNING_ALLOWED=NO
export CODE_SIGN_IDENTITY="-"
swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/OkrunVM"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Assets/okrun-icon.png" "$APP/Contents/Resources/OkrunVM.png"

codesign --force --sign - --timestamp=none --entitlements "$ROOT/OkrunVM.entitlements" "$APP"

echo "Built $APP"
