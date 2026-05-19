#!/usr/bin/env bash

# setup-local-remote.sh
# Purpose: Installs the local (non-TLS) okrun-switch on macOS and configures it as a LaunchAgent.
# Usage: ./setup-local-remote.sh <REPO_URL> [LOCAL_PORT] [STATUS_PORT] [HOST] [APP_DIR]

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Error: REPO_URL is required."
  echo "Usage: ./setup-local-remote.sh <REPO_URL> [LOCAL_PORT] [STATUS_PORT] [HOST] [APP_DIR]"
  exit 1
fi

REPO_URL="$1"
LOCAL_PORT="${2:-9444}"
STATUS_PORT="${3:-8080}"
HOST="${4:-127.0.0.1}"
APP_DIR="${5:-~/okrun-switch}"

# Resolve APP_DIR to absolute path
APP_DIR="$(eval echo "$APP_DIR")"
WEB_SWITCH_DIR="$APP_DIR/web-switch"
LOG_DIR="$HOME/.okrun-switch/logs"
LAUNCH_LABEL="com.okrun.local-switch"
PLIST_PATH="$HOME/Library/LaunchAgents/${LAUNCH_LABEL}.plist"
NODE_PATH="${OKRUN_SWITCH_NODE_PATH:-}"

echo "Starting setup for okrun-switch (local mode) on macOS..."
echo "App Directory: $APP_DIR"
echo "Repository: $REPO_URL"
echo "Local port: $LOCAL_PORT"
echo "Status port: $STATUS_PORT"
echo "Bind host: $HOST"

# ============================================================
# 1. Install Node.js if needed
# ============================================================

echo "Checking for Node.js..."

LOCAL_NODE="$HOME/.local/bin/node"

if [[ -n "$NODE_PATH" ]]; then
  if [[ -x "$NODE_PATH" ]]; then
    echo "Using custom Node.js path from OKRUN_SWITCH_NODE_PATH: $NODE_PATH"
  else
    echo "Error: OKRUN_SWITCH_NODE_PATH is set but executable not found: $NODE_PATH"
    exit 1
  fi
else
  # Detect architecture
  ARCH=$(uname -m)
  case "$ARCH" in
    arm64)
      NODE_ARCH="darwin-arm64"
      ;;
    x86_64)
      NODE_ARCH="darwin-x64"
      ;;
    *)
      echo "Error: Unsupported architecture: $ARCH"
      exit 1
      ;;
  esac

  # Fetch latest LTS version
  LTS_DATA=$(curl -fsSL https://nodejs.org/dist/index.json 2>/dev/null | head -c 10000 || true)

  if [[ -n "$LTS_DATA" ]]; then
    TARGET_VERSION=$(echo "$LTS_DATA" | grep -oE '\{"version":"v[0-9]+\.[^}]*"lts":"[^"]+"[^}]*\}' | head -1 | grep -oE '"version":"v[0-9]+' | grep -oE 'v[0-9]+')
    TARGET_MAJOR=$(echo "$TARGET_VERSION" | grep -oE '[0-9]+')
  fi

  if [[ -n "${TARGET_MAJOR:-}" ]]; then
    TARGET_NODE_VERSION="v${TARGET_MAJOR}"
    echo "Latest LTS detected: Node.js ${TARGET_NODE_VERSION}.x"
  else
    TARGET_NODE_VERSION="v22"
    TARGET_MAJOR="22"
    echo "Could not detect latest LTS. Using fallback: Node.js ${TARGET_NODE_VERSION}"
  fi

  INSTALL_NODE=false

  if [[ -x "$LOCAL_NODE" ]]; then
    CURRENT_NODE_VERSION=$("$LOCAL_NODE" -v)
    echo "Found custom Node.js installation: ${CURRENT_NODE_VERSION}"

    if [[ "${CURRENT_NODE_VERSION}" == "${TARGET_NODE_VERSION}"* ]]; then
      echo "Node.js is already at target LTS version ${TARGET_NODE_VERSION}."
      INSTALL_NODE=false
    else
      echo "Node.js version mismatch. Target: ${TARGET_NODE_VERSION}, Current: ${CURRENT_NODE_VERSION}"
      echo "Will update to Node.js ${TARGET_NODE_VERSION}..."
      INSTALL_NODE=true
    fi
  else
    echo "Custom Node.js not found at $LOCAL_NODE. Will install Node.js ${TARGET_NODE_VERSION}..."
    INSTALL_NODE=true
  fi

  if [[ "$INSTALL_NODE" == true ]]; then
    echo "Installing Node.js ${TARGET_NODE_VERSION}.x from official Node.js distribution..."

    NODE_VERSION_FULL=$(curl -fsSL "https://nodejs.org/dist/latest-${TARGET_NODE_VERSION}.x/" 2>/dev/null | grep -oE "node-${TARGET_NODE_VERSION}\.[0-9]+\.[0-9]+-${NODE_ARCH}\.tar\.gz" | head -1 | sed "s/node-//;s/-${NODE_ARCH}\.tar\.gz//")
    if [[ -z "$NODE_VERSION_FULL" ]]; then
      NODE_VERSION_FULL="${TARGET_NODE_VERSION}.15.0"
      echo "Could not detect latest ${TARGET_NODE_VERSION}.x version. Using fallback: ${NODE_VERSION_FULL}"
    else
      echo "Installing Node.js ${NODE_VERSION_FULL}..."
    fi

    NODE_TARBALL="node-${NODE_VERSION_FULL}-${NODE_ARCH}.tar.gz"
    NODE_URL="https://nodejs.org/dist/${NODE_VERSION_FULL}/${NODE_TARBALL}"
    SHASUMS_URL="https://nodejs.org/dist/${NODE_VERSION_FULL}/SHASUMS256.txt"

    TEMP_DIR=$(mktemp -d)
    trap "rm -rf $TEMP_DIR" EXIT

    echo "Downloading Node.js ${NODE_VERSION_FULL} for ${ARCH}..."
    curl -fsSL "$NODE_URL" -o "$TEMP_DIR/$NODE_TARBALL"
    curl -fsSL "$SHASUMS_URL" -o "$TEMP_DIR/SHASUMS256.txt"

    echo "Verifying SHA256 checksum..."
    EXPECTED_HASH=$(grep "$NODE_TARBALL" "$TEMP_DIR/SHASUMS256.txt" | awk '{print $1}')
    if [[ -z "$EXPECTED_HASH" ]]; then
      echo "Error: Could not find checksum for $NODE_TARBALL"
      exit 1
    fi

    ACTUAL_HASH=$(shasum -a 256 "$TEMP_DIR/$NODE_TARBALL" | awk '{print $1}')
    if [[ "$EXPECTED_HASH" != "$ACTUAL_HASH" ]]; then
      echo "Error: SHA256 checksum verification failed!"
      echo "Expected: $EXPECTED_HASH"
      echo "Actual:   $ACTUAL_HASH"
      exit 1
    fi
    echo "SHA256 checksum verified."

    # Remove any existing local Node.js installation
    if [[ -d "$HOME/.local/lib/node" ]]; then
      echo "Removing existing Node.js installation..."
      rm -rf "$HOME/.local/lib/node" "$HOME/.local/bin/node" "$HOME/.local/bin/npm" "$HOME/.local/bin/npx" 2>/dev/null || true
    fi

    # Extract tarball to ~/.local
    echo "Extracting Node.js to ~/.local..."
    mkdir -p "$HOME/.local"
    tar -xz -C "$HOME/.local" --strip-components=1 -f "$TEMP_DIR/$NODE_TARBALL"

    # Verify installation
    if [[ -x "$LOCAL_NODE" ]]; then
      echo "Node.js installed successfully: $("$LOCAL_NODE" -v)"
      echo "npm version: $("$HOME/.local/bin/npm" -v)"
    else
      echo "Error: Node.js installation failed"
      exit 1
    fi
  fi

  NODE_PATH="$LOCAL_NODE"
fi

if [[ -z "$NODE_PATH" || ! -x "$NODE_PATH" ]]; then
  echo "Error: Node.js executable not found at ${NODE_PATH:-<unset>}"
  echo "Install Node.js first, or set OKRUN_SWITCH_NODE_PATH to the correct binary"
  exit 1
fi

echo "Using Node.js at: $NODE_PATH ($("$NODE_PATH" -v))"

# ============================================================
# 2. Create directories
# ============================================================

echo "Creating directories..."
mkdir -p "$LOG_DIR"

# ============================================================
# 3. Clone or update repository
# ============================================================

echo "Setting up repository..."
if [[ -d "$APP_DIR/.git" ]]; then
  echo "App directory exists. Updating repository..."
  cd "$APP_DIR"
  git fetch origin
  git reset --hard "origin/main"
  echo "Repository updated."
else
  echo "App directory does not exist. Cloning repository..."
  if [[ -d "$APP_DIR" ]]; then
    rm -rf "$APP_DIR"
  fi
  git clone "$REPO_URL" "$APP_DIR"
  echo "Repository cloned."
fi

if [[ ! -d "$WEB_SWITCH_DIR" ]]; then
  echo "Error: web-switch directory not found at $WEB_SWITCH_DIR"
  exit 1
fi

# ============================================================
# 4. Unload existing LaunchAgent
# ============================================================

echo "Checking for existing LaunchAgent..."
if launchctl list "$LAUNCH_LABEL" &> /dev/null; then
  echo "Unloading existing LaunchAgent..."
  launchctl unload "$PLIST_PATH" 2>/dev/null || true
fi

if [[ -f "$PLIST_PATH" ]]; then
  rm "$PLIST_PATH"
fi

# ============================================================
# 5. Create LaunchAgent plist
# ============================================================

echo "Creating LaunchAgent plist..."
cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LAUNCH_LABEL}</string>

    <key>ProgramArguments</key>
    <array>
        <string>${NODE_PATH}</string>
        <string>${WEB_SWITCH_DIR}/src/index.js</string>
        <string>--tls-enabled</string>
        <string>false</string>
        <string>--local-port</string>
        <string>${LOCAL_PORT}</string>
        <string>--status-port</string>
        <string>${STATUS_PORT}</string>
        <string>--host</string>
        <string>${HOST}</string>
    </array>

    <key>WorkingDirectory</key>
    <string>${WEB_SWITCH_DIR}</string>

    <key>StandardOutPath</key>
    <string>${LOG_DIR}/local-switch.log</string>

    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/local-switch-error.log</string>

    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
        <key>Crashed</key>
        <true/>
    </dict>

    <key>RunAtLoad</key>
    <true/>

    <key>ThrottleInterval</key>
    <integer>10</integer>

    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
        <key>NODE_ENV</key>
        <string>production</string>
    </dict>
</dict>
</plist>
EOF

# ============================================================
# 6. Load and start the LaunchAgent
# ============================================================

echo "Loading LaunchAgent..."
launchctl load "$PLIST_PATH"

echo "Starting local switch..."
launchctl start "$LAUNCH_LABEL"

# ============================================================
# 7. Wait and run health checks
# ============================================================

sleep 2

echo ""
echo "Running health checks..."

# Check if LaunchAgent is loaded
if launchctl list "$LAUNCH_LABEL" &> /dev/null; then
  echo "ok LaunchAgent is loaded"
else
  echo "ok LaunchAgent is NOT loaded"
  exit 1
fi

# Check if process is running
PID=$(launchctl list "$LAUNCH_LABEL" 2>/dev/null | grep '"PID"' | awk '{print $NF}' | tr -d ';')
if [[ -n "$PID" && "$PID" -gt 0 ]] 2>/dev/null; then
  if ps -p "$PID" > /dev/null 2>&1; then
    echo "ok Local switch process is running (PID: $PID)"
  else
    echo "ok Local switch process not found (PID: $PID may have exited)"
  fi
else
  echo "ok Local switch may not be running (checking logs...)"
fi

# Check health endpoint
STATUS_OK=false
for i in 1 2 3 4 5; do
  if curl -fsS --connect-timeout 2 --max-time 5 "http://${HOST}:${STATUS_PORT}/healthz" >/dev/null 2>&1; then
    STATUS_OK=true
    break
  fi
  sleep 1
done

if [[ "$STATUS_OK" == true ]]; then
  echo "ok Status endpoint is responding"
else
  echo "ok Status endpoint is NOT responding"
  if [[ -f "$LOG_DIR/local-switch-error.log" ]]; then
    echo ""
    echo "Recent error log entries:"
    tail -n 10 "$LOG_DIR/local-switch-error.log"
  fi
  exit 1
fi

# Check local TCP port
if lsof -Pi ":${LOCAL_PORT}" -sTCP:LISTEN >/dev/null 2>&1 || netstat -an 2>/dev/null | grep -q "\.${LOCAL_PORT} " || ss -tln 2>/dev/null | grep -q ":${LOCAL_PORT}"; then
  echo "ok Local port ${LOCAL_PORT} is listening"
else
  echo "ok Local port ${LOCAL_PORT} is NOT listening"
fi

# Show recent logs
if [[ -f "$LOG_DIR/local-switch.log" ]]; then
  echo ""
  echo "Recent log entries:"
  tail -n 5 "$LOG_DIR/local-switch.log"
fi

echo ""
echo "Setup completed successfully!"
echo ""
echo "The local switch is configured to:"
echo "  - Listen on: ${HOST}:${LOCAL_PORT} (plain TCP)"
echo "  - Status on: http://${HOST}:${STATUS_PORT}/healthz"
echo ""
echo "Management commands:"
echo "  Check status: launchctl list $LAUNCH_LABEL"
echo "  Start:        launchctl start $LAUNCH_LABEL"
echo "  Stop:         launchctl stop $LAUNCH_LABEL"
echo "  View logs:    tail -f $LOG_DIR/local-switch.log"
echo "  View errors:  tail -f $LOG_DIR/local-switch-error.log"
echo ""
echo "The local switch will automatically start on login and restart on crashes."
