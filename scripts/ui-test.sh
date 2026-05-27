#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACT_DIR="${ARTIFACT_DIR:-$ROOT/.e2e/ui-add-delete}"
SCREENSHOT_DIR="$ARTIFACT_DIR/screenshots"
APP_BINARY="$ROOT/OkrunVM.app/Contents/MacOS/OkrunVM"
APP_PID=""

cleanup() {
  if [[ -n "$APP_PID" ]] && ps -p "$APP_PID" >/dev/null 2>&1; then
    kill "$APP_PID" >/dev/null 2>&1 || true
    wait "$APP_PID" >/dev/null 2>&1 || true
  fi
  APP_PID=""
}
trap cleanup EXIT

require_macos_ui_access() {
  if ! osascript -e 'tell application "System Events" to return UI elements enabled' | grep -q true; then
    printf 'Accessibility automation is not enabled for this terminal/Codex app.\n' >&2
    printf 'Enable it in System Settings > Privacy & Security > Accessibility, then rerun this script.\n' >&2
    exit 1
  fi
}

launch_app() {
  local registry_path="$1"
  local home_path="$2"
  shift 2
  env \
    OKRUN_REGISTRY_PATH="$registry_path" \
    OKRUN_HOME="$home_path" \
    OKRUN_UI_E2E_TEST_COMMANDS=1 \
    "$@" \
    "$APP_BINARY" &
  APP_PID="$!"
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

assert_button_exists() {
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

set deadline to (current date) + 12
tell application "System Events"
  repeat while (current date) is less than deadline
    set targetProcess to my appProcess()
    if targetProcess is not missing value then
      tell targetProcess
        set frontmost to true
        if "$identifier" is not "" then
          try
            first UI element of entire contents of window 1 whose role is "AXButton" and identifier is "$identifier"
            return true
          end try
        end if
        try
          first button of window 1 whose name is "$label"
          return true
        end try
        try
          first button of window 1 whose description is "$label"
          return true
        end try
        try
          first UI element of entire contents of window 1 whose role is "AXButton" and (name is "$label" or description is "$label")
          return true
        end try
      end tell
    end if
    delay 0.2
  end repeat
end tell
error "Timed out waiting for button to exist: $label"
APPLESCRIPT
}

click_checkbox() {
  local identifier="$1"
  osascript <<APPLESCRIPT
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
          click (first UI element of entire contents of window 1 whose role is "AXCheckBox" and identifier is "$identifier")
          return true
        end try
      end tell
    end if
    delay 0.2
  end repeat
end tell
error "Timed out waiting for checkbox: $identifier"
APPLESCRIPT
}

click_network_tab() {
  local label="$1"
  osascript <<APPLESCRIPT
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
          click (first radio button of tab group 1 of window "Private Network" whose name is "$label")
          return true
        end try
      end tell
    end if
    delay 0.2
  end repeat
end tell
error "Timed out waiting for network tab: $label"
APPLESCRIPT
}

click_network_checkbox() {
  local label="$1"
  osascript <<APPLESCRIPT
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
          click (first checkbox of tab group 1 of window "Private Network" whose name is "$label")
          return true
        end try
      end tell
    end if
    delay 0.2
  end repeat
end tell
error "Timed out waiting for network checkbox: $label"
APPLESCRIPT
}

set_network_tab_text_field() {
  local index="$1"
  local text="$2"
  osascript <<APPLESCRIPT
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
          set value of text field $index of tab group 1 of window "Private Network" to "$text"
          return true
        end try
      end tell
    end if
    delay 0.2
  end repeat
end tell
error "Timed out waiting for network text field: $index"
APPLESCRIPT
}

set_accessibility_value() {
  local identifier="$1"
  local text="$2"
  osascript <<APPLESCRIPT
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
          set targetElement to first UI element of entire contents of window 1 whose identifier is "$identifier"
          set value of targetElement to "$text"
          return true
        end try
      end tell
    end if
    delay 0.2
  end repeat
end tell
error "Timed out waiting for editable element: $identifier"
APPLESCRIPT
}

wait_for_accessibility_value() {
  local identifier="$1"
  local expected="$2"
  osascript <<APPLESCRIPT
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
          set targetElement to first UI element of entire contents of window 1 whose identifier is "$identifier"
          set targetValue to ""
          try
            set targetValue to value of targetElement as text
          end try
          if targetValue contains "$expected" then return true
        end try
      end tell
    end if
    delay 0.2
  end repeat
end tell
error "Timed out waiting for $identifier to contain: $expected"
APPLESCRIPT
}

click_window_offset() {
  local x_offset="$1"
  local y_offset="$2"
  osascript <<APPLESCRIPT
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
          click at {windowX + $x_offset, windowY + $y_offset}
          return true
        end try
      end tell
    end if
    delay 0.2
  end repeat
end tell
error "Timed out waiting for app window"
APPLESCRIPT
}

assert_sidebar_visible() {
  local phase="$1"
  osascript <<APPLESCRIPT
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
          set targetWindow to window 1
          set newButton to first button of targetWindow whose description is "New VM"
          set firstTab to first UI element of targetWindow whose description is "first-vm"
          set buttonPosition to position of newButton
          set buttonSize to size of newButton
          set tabPosition to position of firstTab
          set tabSize to size of firstTab
          set windowPosition to position of targetWindow
          if (item 1 of buttonSize) < 20 or (item 2 of buttonSize) < 20 then
            error "New VM button is collapsed during $phase"
          end if
          if (item 1 of tabSize) < 200 or (item 2 of tabSize) < 40 then
            error "VM tab row is collapsed during $phase"
          end if
          if (item 2 of buttonPosition) < ((item 2 of windowPosition) + 34) then
            error "New VM button is hidden under the titlebar during $phase"
          end if
          if (item 2 of tabPosition) < ((item 2 of buttonPosition) + (item 2 of buttonSize)) then
            error "VM tab row is hidden behind the sidebar header during $phase"
          end if
          return true
        end try
      end tell
    end if
    delay 0.2
  end repeat
end tell
error "Timed out waiting for visible sidebar during $phase"
APPLESCRIPT
}

window_width() {
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
          set windowSize to size of window 1
          return item 1 of windowSize
        end try
      end tell
    end if
    delay 0.2
  end repeat
end tell
error "Timed out waiting for app window width"
APPLESCRIPT
}

wait_for_window_width_change() {
  local before_width="$1"
  local deadline=$((SECONDS + 12))
  while [[ "$(window_width)" == "$before_width" ]]; do
    if (( SECONDS >= deadline )); then
      printf 'Timed out waiting for window width to change from %s\n' "$before_width" >&2
      exit 1
    fi
    sleep 0.2
  done
}

click_menu_item() {
  local menu_name="$1"
  local item_name="$2"
  osascript <<APPLESCRIPT
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
          click menu item "$item_name" of menu "$menu_name" of menu bar 1
          return true
        end try
      end tell
    end if
    delay 0.2
  end repeat
end tell
error "Timed out waiting for menu item: $menu_name > $item_name"
APPLESCRIPT
}

close_window() {
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
          click (first button of window 1 whose subrole is "AXCloseButton")
          return true
        end try
      end tell
    end if
    delay 0.2
  end repeat
end tell
error "Timed out waiting to close app window"
APPLESCRIPT
}

type_text() {
  local text="$1"
  osascript <<APPLESCRIPT
on appProcess()
  tell application "System Events"
    if exists process "OkrunVM" then return process "OkrunVM"
    if exists process "Okrun VM" then return process "Okrun VM"
  end tell
  return missing value
end appProcess

tell application "System Events"
  set targetProcess to my appProcess()
  tell targetProcess
    set frontmost to true
    try
      click text field 1 of window "Delete VM"
    on error
      click text field 1 of window 1
    end try
    keystroke "$text"
  end tell
end tell
APPLESCRIPT
}

replace_text() {
  local text="$1"
  osascript <<APPLESCRIPT
on appProcess()
  tell application "System Events"
    if exists process "OkrunVM" then return process "OkrunVM"
    if exists process "Okrun VM" then return process "Okrun VM"
  end tell
  return missing value
end appProcess

tell application "System Events"
  set targetProcess to my appProcess()
  tell targetProcess
    set frontmost to true
    try
      click text field 1 of window "Delete VM"
    on error
      click text field 1 of window 1
    end try
    keystroke "a" using command down
    key code 51
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

wait_for_any_file() {
  local deadline=$((SECONDS + 12))
  until false; do
    for path in "$@"; do
      if [[ -e "$path" ]]; then
        return 0
      fi
    done

    if (( SECONDS >= deadline )); then
      printf 'Timed out waiting for one of:\n' >&2
      printf '  %s\n' "$@" >&2
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

wait_for_registry_selected() {
  local registry_path="$1"
  local project_path="$2"
  local deadline=$((SECONDS + 12))
  until tr -d '\\' <"$registry_path" | grep -Fq "\"selectedProject\" : \"$project_path\""; do
    if (( SECONDS >= deadline )); then
      printf 'Timed out waiting for selected project %s in %s\n' "$project_path" "$registry_path" >&2
      exit 1
    fi
    sleep 0.2
  done
}

capture() {
  local name="$1"
  screencapture -x "$SCREENSHOT_DIR/$name.png"
}

write_empty_registry() {
  local registry_path="$1"
  mkdir -p "$(dirname "$registry_path")"
  printf '{\n  "projects" : [],\n  "selectedProject" : null\n}\n' >"$registry_path"
}

registry_contains_project() {
  local registry_path="$1"
  local project_path="$2"
  tr -d '\\' <"$registry_path" | grep -Fq "$project_path"
}

write_config() {
  local project_path="$1"
  local iso_path="$2"
  local disk_gb="${3:-1}"
  local cpu_count="${4:-4}"
  local memory_gb="${5:-4}"
  mkdir -p "$project_path"
  printf '{\n  "cpuCount" : %s,\n  "diskGB" : %s,\n  "installerISOPath" : "%s",\n  "memoryGB" : %s,\n  "privateNetwork" : {\n    "enabled" : false,\n    "identifier" : "okrun"\n  },\n  "sharedDirectories" : []\n}\n' "$cpu_count" "$disk_gb" "$iso_path" "$memory_gb" >"$project_path/okrun-vm.json"
}

write_registry() {
  local registry_path="$1"
  local selected_path="$2"
  shift 2
  mkdir -p "$(dirname "$registry_path")"
  {
    printf '{\n  "projects" : [\n'
    local first=1
    for project_path in "$@"; do
      if [[ "$first" == "0" ]]; then
        printf ',\n'
      fi
      printf '    "%s"' "$project_path"
      first=0
    done
    printf '\n  ],\n  "selectedProject" : "%s"\n}\n' "$selected_path"
  } >"$registry_path"
}

assert_no_project_created() {
  local registry_path="$1"
  local project_path="$2"
  if [[ -e "$project_path" ]]; then
    printf 'Unexpected project was created: %s\n' "$project_path" >&2
    exit 1
  fi
  if registry_contains_project "$registry_path" "$project_path"; then
    printf 'Unexpected registry entry was created: %s\n' "$project_path" >&2
    exit 1
  fi
}

run_project_lifecycle_smoke() {
  printf 'Running project lifecycle smoke...\n'
  local test_dir="$ARTIFACT_DIR/project-lifecycle"
  local registry_path="$test_dir/.okrun"
  local project_path="$test_dir/ui-e2e-vm"
  local iso_path="$test_dir/alpine-ui-e2e.iso"
  local config_open_log="$test_dir/config-opened.txt"

  rm -rf "$test_dir"
  mkdir -p "$test_dir"
  write_empty_registry "$registry_path"
  printf 'okrun-ui-e2e placeholder iso\n' >"$iso_path"

  launch_app "$registry_path" "$test_dir/empty-default-project" \
    OKRUN_UI_E2E_VM_NAME="Lifecycle VM" \
    OKRUN_UI_E2E_PROJECT_PATH="$project_path" \
    OKRUN_UI_E2E_ISO_PATH="$iso_path" \
    OKRUN_UI_E2E_DISK_GB=1 \
    OKRUN_UI_E2E_SKIP_AUTOSTART=1 \
    OKRUN_UI_E2E_CONFIG_OPEN_LOG="$config_open_log"

  assert_button_exists "Import VM" "okrun.import-vm"
  click_button "New VM" "okrun.new-vm"
  capture "01-lifecycle-add-dialog"
  click_button "Create" "okrun.add.create"
  wait_for_file "$project_path/okrun-vm.json"
  wait_for_any_file "$project_path/vm/linux.raw" "$project_path/vm/linux.asif"
  grep -Fq '"name" : "Lifecycle VM"' "$project_path/okrun-vm.json"
  grep -Fq '"enabled" : true' "$project_path/okrun-vm.json"
  wait_for_file "$test_dir/empty-default-project/private-networks.json"
  grep -Fq '"okrun"' "$test_dir/empty-default-project/private-networks.json"
  grep -Fq '"enabled" : true' "$test_dir/empty-default-project/private-networks.json"
  tr -d '\\' <"$test_dir/empty-default-project/private-networks.json" | grep -Fq '"cidr" : "10.77.0.0/24"'
  registry_contains_project "$registry_path" "$project_path"
  capture "02-lifecycle-after-add"

  click_menu_item "VM" "Edit VM Config"
  wait_for_file "$config_open_log"
  grep -Fq "$project_path/okrun-vm.json" "$config_open_log"

  click_menu_item "VM" "Rename VM..."
  capture "03-lifecycle-rename"
  replace_text "Renamed Lifecycle VM"
  click_button "Rename" "okrun.rename.confirm"
  grep -Fq '"name" : "Renamed Lifecycle VM"' "$project_path/okrun-vm.json"

  click_menu_item "VM" "Delete VM"
  capture "04-lifecycle-delete-confirmation"
  type_text "Renamed Lifecycle VM"
  click_button "Delete" "okrun.delete.confirm"
  wait_for_missing "$project_path"
  if registry_contains_project "$registry_path" "$project_path"; then
    printf 'Project path still exists in registry: %s\n' "$registry_path" >&2
    exit 1
  fi
  capture "05-lifecycle-after-delete"
  cleanup
}

run_add_dialog_validation() {
  printf 'Running add dialog validation...\n'
  local test_dir="$ARTIFACT_DIR/add-validation"
  local registry_path="$test_dir/.okrun"
  local project_path="$test_dir/should-not-exist"

  rm -rf "$test_dir"
  mkdir -p "$test_dir"
  write_empty_registry "$registry_path"

  launch_app "$registry_path" "$test_dir/empty-default-project"
  click_button "New VM" "okrun.new-vm"
  capture "05-validation-add-dialog"
  click_button "Create" "okrun.add.create"
  sleep 0.5
  assert_no_project_created "$registry_path" "$project_path"
  capture "06-validation-still-open"
  click_button "Cancel" "okrun.add.cancel"
  capture "07-validation-after-cancel"
  cleanup
}

run_network_config_smoke() {
  printf 'Running network config smoke...\n'
  local test_dir="$ARTIFACT_DIR/network-config"
  local registry_path="$test_dir/.okrun"
  local home_path="$test_dir/home"
  local bind_port=$((20000 + $$ % 20000))

  rm -rf "$test_dir"
  mkdir -p "$test_dir"
  write_empty_registry "$registry_path"

  launch_app "$registry_path" "$home_path"
  click_button "Private Network" "okrun.network-config"
  wait_for_file "$home_path/private-networks.json"
  capture "08-network-config-open"

  click_network_tab "Local Switch"
  click_network_checkbox "Local Switch"
  set_network_tab_text_field 1 "127.0.0.1:$bind_port"
  click_button "Apply & Connect" "okrun.network.apply"

  grep -Fq '"localSwitch"' "$home_path/private-networks.json"
  grep -Fq '"enabled" : true' "$home_path/private-networks.json"
  grep -Fq "\"server\" : \"127.0.0.1:$bind_port\"" "$home_path/private-networks.json"

  click_network_checkbox "Local Switch"
  click_button "Apply & Connect" "okrun.network.apply"
  if grep -Fq "\"server\" : \"127.0.0.1:$bind_port\"" "$home_path/private-networks.json"; then
    printf 'Local Switch was not removed from private network config.\n' >&2
    exit 1
  fi
  capture "09-network-config-bound"
  click_button "Close" "okrun.network.close"
  cleanup
}

run_registry_restore_and_selection() {
  printf 'Running registry restore and multi-VM selection...\n'
  local test_dir="$ARTIFACT_DIR/registry-selection"
  local registry_path="$test_dir/.okrun"
  local iso_path="$test_dir/alpine-ui-e2e.iso"
  local first_project="$test_dir/first-vm"
  local second_project="$test_dir/second-vm"
  local config_open_log="$test_dir/config-opened.txt"

  rm -rf "$test_dir"
  mkdir -p "$test_dir"
  printf 'okrun-ui-e2e placeholder iso\n' >"$iso_path"
  write_config "$first_project" "$iso_path" 1
  write_config "$second_project" "$iso_path" 2
  write_registry "$registry_path" "$second_project" "$first_project" "$second_project"

  launch_app "$registry_path" "$test_dir/default-project" \
    OKRUN_UI_E2E_CONFIG_OPEN_LOG="$config_open_log"
  wait_for_registry_selected "$registry_path" "$second_project"
  capture "08-registry-restored"

  click_menu_item "VM" "Select First VM"
  wait_for_registry_selected "$registry_path" "$first_project"
  capture "09-registry-first-selected"

  click_menu_item "VM" "Edit VM Config"
  wait_for_file "$config_open_log"
  grep -Fq "$first_project/okrun-vm.json" "$config_open_log"

  click_menu_item "VM" "Select Last VM"
  wait_for_registry_selected "$registry_path" "$second_project"
  capture "10-registry-second-selected"
  cleanup
}

run_titlebar_zoom_keeps_sidebar_visible() {
  printf 'Running titlebar zoom sidebar visibility...\n'
  local test_dir="$ARTIFACT_DIR/titlebar-zoom"
  local registry_path="$test_dir/.okrun"
  local iso_path="$test_dir/alpine-ui-e2e.iso"
  local first_project="$test_dir/first-vm"
  local second_project="$test_dir/second-vm"

  rm -rf "$test_dir"
  mkdir -p "$test_dir"
  printf 'okrun-ui-e2e placeholder iso\n' >"$iso_path"
  write_config "$first_project" "$iso_path" 1
  write_config "$second_project" "$iso_path" 1
  write_registry "$registry_path" "$first_project" "$first_project" "$second_project"

  launch_app "$registry_path" "$test_dir/default-project"
  assert_sidebar_visible "before titlebar zoom"
  capture "11-titlebar-before-zoom"
  local before_width
  before_width="$(window_width)"
  click_menu_item "VM" "Zoom Window"
  wait_for_window_width_change "$before_width"
  sleep 0.8
  assert_sidebar_visible "after titlebar zoom"
  capture "12-titlebar-after-zoom"
  click_button "Hide Sidebar" "okrun.sidebar.hide"
  assert_button_exists "Show Sidebar" "okrun.sidebar.show"
  capture "13-titlebar-sidebar-collapsed"
  click_button "Show Sidebar" "okrun.sidebar.show"
  assert_sidebar_visible "after sidebar restore"
  capture "14-titlebar-sidebar-restored"
  cleanup
}

run_fake_running_close_flow() {
  printf 'Running fake running VM close alert flow...\n'
  local test_dir="$ARTIFACT_DIR/fake-running-close"
  local registry_path="$test_dir/.okrun"
  local project_path="$test_dir/devbox"
  local second_project_path="$test_dir/devbox-sandbox"
  local iso_path="$test_dir/alpine-ui-e2e.iso"

  rm -rf "$test_dir"
  mkdir -p "$test_dir"
  printf 'okrun-ui-e2e placeholder iso\n' >"$iso_path"
  write_config "$project_path" "$iso_path" 64 6 8
  write_config "$second_project_path" "$iso_path" 64 4 4
  write_registry "$registry_path" "$project_path" "$project_path" "$second_project_path"

  launch_app "$registry_path" "$test_dir/default-project" \
    OKRUN_UI_E2E_FAKE_VM_BACKEND=1
  click_button "Start" "okrun.context.start"
  capture "11-fake-running"

  close_window
  capture "12-fake-running-close-confirmation"
  click_button "Cancel" "okrun.close.cancel"
  capture "13-fake-running-after-cancel"
  cleanup
}

require_macos_ui_access
"$ROOT/scripts/build.sh"

rm -rf "$ARTIFACT_DIR"
mkdir -p "$SCREENSHOT_DIR"

run_project_lifecycle_smoke
run_add_dialog_validation
run_network_config_smoke
run_registry_restore_and_selection
run_titlebar_zoom_keeps_sidebar_visible
run_fake_running_close_flow

printf 'Critical UI E2E suite passed.\n'
printf 'Artifacts: %s\n' "$ARTIFACT_DIR"
printf 'Screenshots:\n'
find "$SCREENSHOT_DIR" -type f -name '*.png' -print | sort
