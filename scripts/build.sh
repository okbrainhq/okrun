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
  APP_NAME="OkrunVM-Dev"
  PLIST="$ROOT/Info-Dev.plist"
else
  APP_NAME="OkrunVM"
  PLIST="$ROOT/Info.plist"
fi

APP="$ROOT/$APP_NAME.app"
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
cp "$PLIST" "$APP/Contents/Info.plist"
cp "$ROOT/Assets/okrun-icon.png" "$APP/Contents/Resources/OkrunVM.png"

codesign --force --sign - --timestamp=none --entitlements "$ROOT/OkrunVM.entitlements" "$APP"

echo "Built $APP (env=$ENV)"
