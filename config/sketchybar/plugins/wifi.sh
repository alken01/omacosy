#!/usr/bin/env bash
# WiFi pill: icon + SSID; click opens a popup with connection details,
# a Wi-Fi power toggle, and a shortcut to the settings pane.
export PATH="/opt/homebrew/bin:$PATH"
source "$HOME/.config/omarchy/current/theme/sketchybar.sh"
PLUGIN_DIR="$(cd "$(dirname "$0")" && pwd)"

DEV="$(networksetup -listallhardwareports 2>/dev/null | awk '/Wi-Fi|AirPort/{getline; print $2; exit}')"
[ -z "$DEV" ] && DEV=en0

ssid() {
  # macOS 26 redacts SSIDs from CLI tools without Location Services;
  # return empty rather than the literal "<redacted>"
  local s
  s="$(ipconfig getsummary "$DEV" 2>/dev/null | awk -F' SSID : ' '/ SSID : /{print $2; exit}')"
  case "$s" in '<redacted>' | '') echo '' ;; *) echo "$s" ;; esac
}

close_popup() {
  sketchybar --set wifi popup.drawing=off 2>/dev/null
  sketchybar --remove '/wifi\.pop\..*/' >/dev/null 2>&1
}

render() {
  POWER="$(networksetup -getairportpower "$DEV" 2>/dev/null | awk '{print $NF}')"
  SSID="$(ssid)"
  IP="$(ipconfig getifaddr "$DEV" 2>/dev/null)"
  if [ "$POWER" != "On" ]; then
    sketchybar --set wifi icon="󰖪" label.drawing=on label="off"
  elif [ -n "$SSID" ]; then
    sketchybar --set wifi icon="󰖩" label.drawing=on label="$SSID"
  elif [ -n "$IP" ]; then
    # connected but macOS redacts the name: icon-only pill
    sketchybar --set wifi icon="󰖩" label.drawing=off
  else
    sketchybar --set wifi icon="󰖪" label.drawing=off
  fi
}

case "${1:-}" in
  toggle_power)
    POWER="$(networksetup -getairportpower "$DEV" 2>/dev/null | awk '{print $NF}')"
    if [ "$POWER" = "On" ]; then
      networksetup -setairportpower "$DEV" off
    else
      networksetup -setairportpower "$DEV" on
    fi
    close_popup
    sleep 1
    render
    exit 0
    ;;
esac

case "$SENDER" in
  mouse.clicked)
    if [ "$(sketchybar --query wifi | jq -r '.popup.drawing' 2>/dev/null)" = "on" ]; then
      close_popup
      exit 0
    fi
    close_popup
    POWER="$(networksetup -getairportpower "$DEV" 2>/dev/null | awk '{print $NF}')"
    SSID="$(ssid)"
    IP="$(ipconfig getifaddr "$DEV" 2>/dev/null)"
    [ "$POWER" = "On" ] && TOGGLE_LABEL="turn Wi-Fi off" || TOGGLE_LABEL="turn Wi-Fi on"
    sketchybar --add item wifi.pop.0 popup.wifi \
      --set wifi.pop.0 icon.drawing=off \
        label="${SSID:-connected} · ${IP:-no ip}" \
        label.color="$ACCENT" label.padding_left=10 label.padding_right=10 \
        background.drawing=off
    sketchybar --add item wifi.pop.1 popup.wifi \
      --set wifi.pop.1 icon.drawing=off \
        label="$TOGGLE_LABEL" \
        label.color="$LABEL_COLOR" label.padding_left=10 label.padding_right=10 \
        background.drawing=off \
        click_script="$PLUGIN_DIR/wifi.sh toggle_power"
    sketchybar --add item wifi.pop.2 popup.wifi \
      --set wifi.pop.2 icon.drawing=off \
        label="Wi-Fi settings…" \
        label.color="$LABEL_COLOR" label.padding_left=10 label.padding_right=10 \
        background.drawing=off \
        click_script="open 'x-apple.systempreferences:com.apple.wifi-settings-extension'; sketchybar --set wifi popup.drawing=off"
    sketchybar --set wifi popup.drawing=on
    ("$PLUGIN_DIR/popup_guard.sh" wifi >/dev/null 2>&1 &)
    exit 0
    ;;
esac

render
