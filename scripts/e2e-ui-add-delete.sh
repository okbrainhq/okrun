#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACT_DIR="${ARTIFACT_DIR:-$ROOT/.e2e/ui-add-delete}"
REGISTRY_PATH="$ARTIFACT_DIR/.okrun"
PROJECT_PATH="$ARTIFACT_DIR/ui-e2e-vm"
ISO_PATH="$ARTIFACT_DIR/alpine-ui-e2e.iso"
SCREENSHOT_DIR="$ARTIFACT_DIR/screenshots"
APP_BINARY="$ROOT/OkrunVM.app/Contents/MacOS/OkrunVM"
APP_PID=""

cleanup() {
  if [[ -n "$APP_PID" ]] && ps -p "$APP_PID" >/dev/null 2>&1; then
    kill "$APP_PID" >/dev/null 2>&1 || true
    wait "$APP_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

require_macos_ui_access() {
  if ! osascript -e 'tell application "System Events" to return UI elements enabled' | grep -q true; then
    printf 'Accessibility automation is not enabled for this terminal/Codex app.\n' >&2
    printf 'Enable it in System Settings > Privacy & Security > Accessibility, then rerun this script.\n' >&2
    exit 1
  fi
}

click_button() {
  local label="$1"
  local identifier="${2:-}"
  osascript <<APPLESCRIPT
on appProcess()
  tell application "System Events"
    if exists process "OkrunVM" then return process "OkrunVM"
    if exists process "Okrun VM" then return process "Okrun VM"
  end tell
  return missing value
end appProcess

on clickButton(labelText, identifierText)
  set deadline to (current date) + 12
  tell application "System Events"
    repeat while (current date) is less than deadline
      set targetProcess to my appProcess()
      if targetProcess is not missing value then
        tell targetProcess
          set frontmost to true
          if identifierText is not "" then
            try
              click (first UI element of entire contents of window 1 whose role is "AXButton" and identifier is identifierText)
              return true
            end try
          end if
          try
            click (first button of window 1 whose name is labelText)
            return true
          end try
          try
            click (first button of window 1 whose description is labelText)
            return true
          end try
          try
            click (first UI element of entire contents of window 1 whose role is "AXButton" and (name is labelText or description is labelText))
            return true
          end try
        end tell
      end if
      delay 0.2
    end repeat
  end tell
  error "Timed out waiting for button: " & labelText
end clickButton

clickButton("$label", "$identifier")
APPLESCRIPT
}

click_first_tab_delete_button() {
  osascript <<'APPLESCRIPT'
on appProcess()
  tell application "System Events"
    if exists process "OkrunVM" then return process "OkrunVM"
    if exists process "Okrun VM" then return process "Okrun VM"
  end tell
  return missing value
end appProcess

set deadline to (current date) + 12
tell application "System Events"
  repeat while (current date) is less than deadline
    set targetProcess to my appProcess()
    if targetProcess is not missing value then
      tell targetProcess
        set frontmost to true
        try
          set windowPosition to position of window 1
          set windowX to item 1 of windowPosition
          set windowY to item 2 of windowPosition
          click at {windowX + 284, windowY + 116}
          return true
        end try
      end tell
    end if
    delay 0.2
  end repeat
end tell
error "Timed out waiting for first tab delete button"
APPLESCRIPT
}

type_text() {
  local text="$1"
  osascript <<APPLESCRIPT
tell application "System Events"
  tell process "OkrunVM"
    set frontmost to true
    try
      click text field 1 of window 1
    end try
    keystroke "$text"
  end tell
end tell
APPLESCRIPT
}

wait_for_file() {
  local path="$1"
  local deadline=$((SECONDS + 12))
  until [[ -e "$path" ]]; do
    if (( SECONDS >= deadline )); then
      printf 'Timed out waiting for %s\n' "$path" >&2
      exit 1
    fi
    sleep 0.2
  done
}

wait_for_missing() {
  local path="$1"
  local deadline=$((SECONDS + 12))
  while [[ -e "$path" ]]; do
    if (( SECONDS >= deadline )); then
      printf 'Timed out waiting for %s to be removed\n' "$path" >&2
      exit 1
    fi
    sleep 0.2
  done
}

capture() {
  local name="$1"
  screencapture -x "$SCREENSHOT_DIR/$name.png"
}

registry_contains_project() {
  tr -d '\\' <"$REGISTRY_PATH" | grep -Fq "$PROJECT_PATH"
}

require_macos_ui_access
"$ROOT/scripts/build.sh"

rm -rf "$ARTIFACT_DIR"
mkdir -p "$ARTIFACT_DIR" "$SCREENSHOT_DIR"
printf '{\n  "projects" : [],\n  "selectedProject" : null\n}\n' >"$REGISTRY_PATH"
printf 'okrun-ui-e2e placeholder iso\n' >"$ISO_PATH"

OKRUN_REGISTRY_PATH="$REGISTRY_PATH" \
OKRUN_HOME="$ARTIFACT_DIR/empty-default-project" \
OKRUN_UI_E2E_PROJECT_PATH="$PROJECT_PATH" \
OKRUN_UI_E2E_ISO_PATH="$ISO_PATH" \
OKRUN_UI_E2E_DISK_GB=1 \
OKRUN_UI_E2E_SKIP_AUTOSTART=1 \
"$APP_BINARY" &
APP_PID="$!"

click_button "New VM" "okrun.new-vm"
capture "01-add-dialog"
click_button "Create" "okrun.add.create"

wait_for_file "$PROJECT_PATH/okrun-vm.json"
wait_for_file "$PROJECT_PATH/vm/linux.raw"
registry_contains_project
capture "02-after-add"

if ! click_button "Delete VM" "okrun.vm-tab.delete"; then
  click_first_tab_delete_button
fi
capture "03-delete-confirmation"
type_text "ui-e2e-vm"
click_button "Delete" "okrun.delete.confirm"

wait_for_missing "$PROJECT_PATH"
if registry_contains_project; then
  printf 'Project path still exists in registry: %s\n' "$REGISTRY_PATH" >&2
  exit 1
fi
capture "04-after-delete"

printf 'UI add/delete E2E passed.\n'
printf 'Artifacts: %s\n' "$ARTIFACT_DIR"
printf 'Screenshots:\n'
find "$SCREENSHOT_DIR" -type f -name '*.png' -print | sort
