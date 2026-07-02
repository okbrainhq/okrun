# 🧰 Skill: macOS Swift GUI App Jumpstart

Use this skill when creating or extending a native macOS GUI app in Swift. It is a simple starter direction for new apps: SwiftPM executable, script-driven `.app` packaging, dev/prod separation, and local self-signing.

Keep it generic. Replace placeholders like `<AppName>`, `<TargetName>`, `<BundlePrefix>`, and `<StateDir>` with the new app’s names.

## ✅ Recommended Project Shape

```text
Package.swift
Sources/<TargetName>/main.swift
Sources/<TargetName>/UI/
Sources/<TargetName>/Core/
Tests/<TargetName>Tests/
Assets/<app-icon>.png
Info.plist
Info-Dev.plist
<AppName>.entitlements
scripts/build.sh
scripts/run.sh
scripts/test.sh
scripts/ui-test.sh        # optional, only if UI automation exists
README.md
```

## 🧭 Development Direction

- Pick **AppKit** or **SwiftUI** early; do not mix unless there is a clear reason.
- Keep UI code under `UI/` and non-UI/domain logic under `Core/`.
- Use `scripts/` as the source of truth for build, run, test, signing, and packaging.
- Add accessibility identifiers for important controls if UI automation will be used.
- Keep long-running work off the main thread.
- Update `README.md` when setup, scripts, permissions, or user-facing behavior changes.

## 🧪 Dev vs Prod Setup

Use separate dev/prod app bundles so local development can run beside the installed/prod app without mixing state.

| Mode | Command | App bundle | Info plist | Bundle ID | State dir example |
| --- | --- | --- | --- | --- | --- |
| Dev | `./scripts/build.sh` or `--dev` | `<AppName>-Dev.app` | `Info-Dev.plist` | `<BundlePrefix>.<app>.dev` | `~/.<app>-dev` |
| Prod | `./scripts/build.sh --prod` | `<AppName>.app` | `Info.plist` | `<BundlePrefix>.<app>` | `~/.<app>` |

Recommended app config pattern:

- Add an app-specific key like `AppEnvironment` in both plist files: `dev` or `prod`.
- Add an app-specific state key like `AppStateDirectoryName` if the app stores files.
- Let environment variables override local state when useful, e.g. `<APP>_HOME` or `<APP>_REGISTRY_PATH`.
- In `scripts/run.sh`, use `open -n` for dev so dev and prod can run side by side.

## 🏗️ Build, Run, Test Approach

Use scripts first, not raw commands, when validating app behavior:

```bash
./scripts/build.sh          # dev build: <AppName>-Dev.app
./scripts/build.sh --prod   # prod build: <AppName>.app

./scripts/run.sh            # build if needed, then open dev
./scripts/run.sh --prod     # build if needed, then open prod

swift test                  # quick unit tests
./scripts/test.sh           # standard repo test pass
./scripts/ui-test.sh        # optional UI automation
```

Guidance:

- Use `swift test` for quick logic checks.
- Use `./scripts/build.sh` to validate app-bundle creation, resources, plist, and signing.
- Use `./scripts/run.sh` for local GUI launches.
- Use `./scripts/test.sh` before handing off larger changes.
- Use `./scripts/ui-test.sh` only after the app has accessibility identifiers and required macOS permissions.

## 🔐 Local Self-Signing

For local builds, prefer **ad-hoc self-signing** so contributors do not need Apple certificates.

Rules:

- Build the Swift executable first.
- Assemble the final `.app` bundle.
- Copy resources and `Info.plist` into the bundle.
- Sign **after** the bundle is complete.
- Do not commit machine-specific signing identities.
- Add entitlements only when the app needs them.
- Use a separate release/notarization flow if distributing outside local development.

Common signing commands:

```bash
export CODE_SIGNING_ALLOWED=NO
export CODE_SIGN_IDENTITY="-"

codesign --force --sign - --timestamp=none --entitlements "$ROOT/<AppName>.entitlements" "$APP"

codesign --verify --deep --strict "$APP"
codesign -d --entitlements :- "$APP"
plutil -lint "$APP/Contents/Info.plist"
```

If no entitlements are needed, sign without the `--entitlements` flag.

## 📄 Sample `scripts/build.sh`

Use this as a starting point and replace the names at the top.

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

APP_BASENAME="MyApp"
EXECUTABLE_NAME="MyApp"
DEV_PLIST="$ROOT/Info-Dev.plist"
PROD_PLIST="$ROOT/Info.plist"
ENTITLEMENTS="$ROOT/$APP_BASENAME.entitlements"

ENV="dev"
for arg in "$@"; do
  case "$arg" in
    --prod) ENV="prod" ;;
    --dev)  ENV="dev" ;;
  esac
done

if [[ "$ENV" == "dev" ]]; then
  APP_NAME="$APP_BASENAME-Dev"
  PLIST="$DEV_PLIST"
else
  APP_NAME="$APP_BASENAME"
  PLIST="$PROD_PLIST"
fi

APP="$ROOT/$APP_NAME.app"
BINARY="$ROOT/.build/release/$EXECUTABLE_NAME"

cd "$ROOT"
export CODE_SIGNING_ALLOWED=NO
export CODE_SIGN_IDENTITY="-"
swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/$EXECUTABLE_NAME"
cp "$PLIST" "$APP/Contents/Info.plist"

if [[ -d "$ROOT/Assets" ]]; then
  cp -R "$ROOT/Assets/"* "$APP/Contents/Resources/" 2>/dev/null || true
fi

if [[ -f "$ENTITLEMENTS" ]]; then
  codesign --force --sign - --timestamp=none --entitlements "$ENTITLEMENTS" "$APP"
else
  codesign --force --sign - --timestamp=none "$APP"
fi

echo "Built $APP (env=$ENV)"
```

## 📄 Sample `scripts/run.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_BASENAME="MyApp"

ENV="dev"
for arg in "$@"; do
  case "$arg" in
    --prod) ENV="prod" ;;
    --dev)  ENV="dev" ;;
  esac
done

if [[ "$ENV" == "dev" ]]; then
  APP="$ROOT/$APP_BASENAME-Dev.app"
else
  APP="$ROOT/$APP_BASENAME.app"
fi

if [[ ! -d "$APP" ]]; then
  "$ROOT/scripts/build.sh" "--$ENV"
fi

if [[ "$ENV" == "dev" ]]; then
  open -n "$APP"
else
  open "$APP"
fi
```

## 📄 Sample `scripts/test.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export CLANG_MODULE_CACHE_PATH="$ROOT/.build/clang-module-cache"
export SWIFTPM_HOME="$ROOT/.build/swiftpm-home"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_HOME"

(cd "$ROOT" && swift test --disable-sandbox)

# Optional: run extra local checks if they exist.
for script in "$ROOT"/scripts/e2e-*.sh; do
  [[ -x "$script" ]] || continue
  echo "==> $(basename "$script")"
  "$script"
done

printf '\nAll tests passed.\n'
```

## 📄 Minimal Plist Direction

Keep `Info.plist` and `Info-Dev.plist` mostly identical except app name, bundle ID, and environment/state keys.

Important keys:

```text
CFBundleExecutable      <TargetName>
CFBundleIdentifier      <BundlePrefix>.<app> or <BundlePrefix>.<app>.dev
CFBundleName            <AppName> or <AppName> Dev
CFBundlePackageType     APPL
LSMinimumSystemVersion  chosen minimum macOS version
NSHighResolutionCapable true
AppEnvironment          prod or dev
AppStateDirectoryName   optional state folder name
```

## 📄 Minimal Entitlements Direction

Start with no entitlements or an empty entitlements file. Add keys only when required by the app’s capabilities.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <!-- Add only the capabilities this app actually needs. -->
</dict>
</plist>
```

## 🚫 Avoid

- Do not make Xcode the only build path if the repo is script-driven.
- Do not treat raw `swift build` as full app validation; it does not assemble resources, plist, or signing.
- Do not mix dev/prod bundle IDs or state directories.
- Do not sign before the final bundle is assembled.
- Do not hardcode absolute user paths.
- Do not add entitlements “just in case.”
