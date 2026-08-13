#!/usr/bin/env bash
# Apple-logo pill: the system menu the hidden native menu bar used to
# carry, plus omacosy actions. Rows are (label, command) pairs.
export PATH="/opt/homebrew/bin:$PATH"
source "$HOME/.config/omarchy/current/theme/sketchybar.sh"
PLUGIN_DIR="$(cd "$(dirname "$0")" && pwd)"

close_popup() {
  sketchybar --set apple popup.drawing=off 2>/dev/null
  sketchybar --remove '/apple\.pop\..*/' >/dev/null 2>&1
}

case "$SENDER" in
  mouse.clicked)
    if [ "$(sketchybar --query apple | jq -r '.popup.drawing' 2>/dev/null)" = "on" ]; then
      close_popup
      exit 0
    fi
    close_popup

    add_row() { # name label command color
      sketchybar --add item "apple.pop.$1" popup.apple \
        --set "apple.pop.$1" icon.drawing=off \
          label="$2" label.color="${4:-$LABEL_COLOR}" \
          label.padding_left=10 label.padding_right=10 \
          background.drawing=off \
          click_script="sketchybar --set apple popup.drawing=off; $3"
    }

    add_row 0 "About This Mac" "open 'x-apple.systempreferences:com.apple.SystemProfiler.AboutExtension'" "$ACCENT"
    add_row 1 "System Settings…" "open -a 'System Settings'"
    add_row 2 "Lock Screen" "pmset displaysleepnow"
    add_row 3 "Sleep" "pmset sleepnow"
    add_row 4 "Restart…" "osascript -e 'tell application \"System Events\" to restart'"
    add_row 5 "Shut Down…" "osascript -e 'tell application \"System Events\" to shut down'"
    add_row 6 "Next Theme" "$HOME/.local/bin/theme-next"
    add_row 7 "Reload Bar" "sketchybar --reload"

    "$PLUGIN_DIR/popup_guard.sh" close_others apple
    sketchybar --set apple popup.drawing=on
    ("$PLUGIN_DIR/popup_guard.sh" apple >/dev/null 2>&1 &)
    exit 0
    ;;
esac
