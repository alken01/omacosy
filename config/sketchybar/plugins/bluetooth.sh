#!/usr/bin/env bash
# Bluetooth pill: state icon (+ connected-device count); click opens a
# popup listing connected (accent, click to disconnect) and paired
# (muted, click to connect) devices, plus power toggle and settings.
# Requires blueutil and the Bluetooth privacy permission for sketchybar.
export PATH="/opt/homebrew/bin:$PATH"
source "$HOME/.config/omarchy/current/theme/sketchybar.sh"
PLUGIN_DIR="$(cd "$(dirname "$0")" && pwd)"

close_popup() {
  sketchybar --set bluetooth popup.drawing=off 2>/dev/null
  sketchybar --remove '/bt\.pop\..*/' >/dev/null 2>&1
}

render() {
  POWER="$(blueutil -p 2>/dev/null)"
  if [ -z "$POWER" ]; then
    # no permission / blueutil unavailable
    sketchybar --set bluetooth icon="󰂲" icon.padding_right=10 label.drawing=off label.padding_right=0
    return
  fi
  if [ "$POWER" = "0" ]; then
    sketchybar --set bluetooth icon="󰂲" icon.padding_right=4 label.drawing=on label="off" label.padding_right=10
    return
  fi
  COUNT="$(blueutil --connected --format json 2>/dev/null | jq 'length')"
  if [ "${COUNT:-0}" -gt 0 ]; then
    sketchybar --set bluetooth icon="󰂱" icon.padding_right=4 label.drawing=on label="$COUNT" label.padding_right=10
  else
    sketchybar --set bluetooth icon="󰂯" icon.padding_right=10 label.drawing=off label.padding_right=0
  fi
}

case "${1:-}" in
  toggle_power)
    blueutil -p toggle 2>/dev/null
    close_popup
    sleep 1
    render
    exit 0
    ;;
  connect)
    blueutil --connect "$2" 2>/dev/null
    close_popup
    sleep 1
    render
    exit 0
    ;;
  disconnect)
    blueutil --disconnect "$2" 2>/dev/null
    close_popup
    sleep 1
    render
    exit 0
    ;;
esac

case "$SENDER" in
  mouse.clicked)
    if [ "$(sketchybar --query bluetooth | jq -r '.popup.drawing' 2>/dev/null)" = "on" ]; then
      close_popup
      exit 0
    fi
    close_popup
    POWER="$(blueutil -p 2>/dev/null)"
    i=0
    if [ "$POWER" = "1" ]; then
      # connected devices: accent, click to disconnect
      while IFS=$'\t' read -r addr name; do
        [ -z "$addr" ] && continue
        sketchybar --add item "bt.pop.$i" popup.bluetooth \
          --set "bt.pop.$i" icon="󰄬" icon.color="$ACCENT" \
            label="$name" label.color="$ACCENT" \
            label.padding_right=10 background.drawing=off \
            click_script="$PLUGIN_DIR/bluetooth.sh disconnect $addr"
        i=$((i + 1))
      done < <(blueutil --connected --format json 2>/dev/null | jq -r '.[] | [.address, .name] | @tsv')
      # paired but not connected: muted, click to connect (first 6)
      while IFS=$'\t' read -r addr name; do
        [ -z "$addr" ] && continue
        sketchybar --add item "bt.pop.$i" popup.bluetooth \
          --set "bt.pop.$i" icon="·" icon.color="$MUTED" \
            label="$name" label.color="$LABEL_COLOR" \
            label.padding_right=10 background.drawing=off \
            click_script="$PLUGIN_DIR/bluetooth.sh connect $addr"
        i=$((i + 1))
      done < <(blueutil --paired --format json 2>/dev/null | jq -r '.[] | select(.connected | not) | [.address, .name] | @tsv' | head -6)
    fi
    [ "$POWER" = "1" ] && TOGGLE_LABEL="turn Bluetooth off" || TOGGLE_LABEL="turn Bluetooth on"
    sketchybar --add item "bt.pop.$i" popup.bluetooth \
      --set "bt.pop.$i" icon.drawing=off \
        label="$TOGGLE_LABEL" label.color="$LABEL_COLOR" \
        label.padding_left=10 label.padding_right=10 background.drawing=off \
        click_script="$PLUGIN_DIR/bluetooth.sh toggle_power"
    i=$((i + 1))
    sketchybar --add item "bt.pop.$i" popup.bluetooth \
      --set "bt.pop.$i" icon.drawing=off \
        label="Bluetooth settings…" label.color="$LABEL_COLOR" \
        label.padding_left=10 label.padding_right=10 background.drawing=off \
        click_script="open 'x-apple.systempreferences:com.apple.BluetoothSettings'; sketchybar --set bluetooth popup.drawing=off"
    sketchybar --set bluetooth popup.drawing=on
    ("$PLUGIN_DIR/popup_guard.sh" bluetooth >/dev/null 2>&1 &)
    exit 0
    ;;
esac

render
