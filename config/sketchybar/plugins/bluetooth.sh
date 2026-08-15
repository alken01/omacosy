#!/usr/bin/env bash
# Bluetooth pill: state icon (+ connected-device count); click opens a
# popup listing connected (accent, click to disconnect) and paired
# (muted, click to connect) devices, plus power toggle and settings.
# Requires the Bluetooth privacy permission for sketchybar (the helper
# inherits it as a spawned child).
export PATH="/opt/homebrew/bin:$PATH"
source "$HOME/.config/omarchy/current/theme/sketchybar.sh"
PLUGIN_DIR="$(cd "$(dirname "$0")" && pwd)"

close_popup() {
  sketchybar --set bluetooth popup.drawing=off 2>/dev/null
  sketchybar --remove '/bluetooth\.pop\..*/' >/dev/null 2>&1
}

# LABEL_COLOR at ~60% alpha for the quiet action rows (weather-popup style)
DIM="0x99${LABEL_COLOR:4}"

# class-of-device keyword (helper column 4) → Nerd Font glyph
kind_icon() {
  case "$1" in
    headphones) printf '󰋋' ;;
    speaker) printf '󰓃' ;;
    mic) printf '󰍬' ;;
    keyboard | combo) printf '󰌌' ;;
    pointer) printf '󰍽' ;;
    phone) printf '󰏲' ;;
    watch) printf '󰖉' ;;
    gamepad) printf '󰊴' ;;
    *) printf '󰂯' ;;
  esac
}

# BLE devices carry no class-of-device — refine "device" from the name
refine_kind() { # $1 kind, $2 name
  [ "$1" != "device" ] && { printf '%s' "$1"; return; }
  case "$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')" in
    *iphone* | *phone*) printf 'phone' ;;
    *mouse* | *trackpad*) printf 'pointer' ;;
    *keyboard* | *keychron*) printf 'keyboard' ;;
    *controller*) printf 'gamepad' ;;
    *watch*) printf 'watch' ;;
    *bud* | *headphone*) printf 'headphones' ;;
    *) printf 'device' ;;
  esac
}

render() {
  POWER="$("$HOME/.local/bin/omacosy-helper" bt power 2>/dev/null)"
  if [ -z "$POWER" ]; then
    # no permission / helper unavailable
    sketchybar --set bluetooth icon="󰂲" icon.padding_right=10 label.drawing=off label.padding_right=0
    return
  fi
  if [ "$POWER" = "0" ]; then
    sketchybar --set bluetooth icon="󰂲" icon.padding_right=4 label.drawing=on label="off" label.padding_right=10
    return
  fi
  COUNT="$("$HOME/.local/bin/omacosy-helper" bt devices 2>/dev/null | grep -c '^1')"
  if [ "${COUNT:-0}" -gt 0 ]; then
    sketchybar --set bluetooth icon="󰂱" icon.padding_right=4 label.drawing=on label="$COUNT" label.padding_right=10
  else
    sketchybar --set bluetooth icon="󰂯" icon.padding_right=10 label.drawing=off label.padding_right=0
  fi
}

case "${1:-}" in
  toggle_power)
    "$HOME/.local/bin/omacosy-helper" bt power toggle >/dev/null 2>&1
    close_popup
    sleep 1
    render
    exit 0
    ;;
  connect)
    # openConnection blocks up to ~20s when the device doesn't answer
    # (off / out of range / multipoint slots busy) — run it async so
    # the popup closes instantly, show progress on the pill, and say
    # so when the radio comes back empty instead of failing silently
    close_popup
    sketchybar --set bluetooth icon="󰂯" icon.padding_right=4 label.drawing=on label="connecting…" label.padding_right=10
    (
      if "$HOME/.local/bin/omacosy-helper" bt connect "$2" >/dev/null 2>&1; then
        render
      else
        sketchybar --set bluetooth icon="󰂲" label.drawing=on label="no response" label.padding_right=10
        sleep 3
        render
      fi
    ) &
    exit 0
    ;;
  disconnect)
    close_popup
    (
      "$HOME/.local/bin/omacosy-helper" bt disconnect "$2" >/dev/null 2>&1
      sleep 1
      render
    ) &
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
    POWER="$("$HOME/.local/bin/omacosy-helper" bt power 2>/dev/null)"
    i=0
    if [ "$POWER" = "1" ]; then
      DEVICES="$("$HOME/.local/bin/omacosy-helper" bt devices 2>/dev/null)"
      # battery per HID product name (trackpads, keyboards, some
      # headphones) — best-effort enrichment for connected rows
      BATT="$(ioreg -r -c AppleDeviceManagementHIDEventService -l 2>/dev/null \
        | awk '/^[[:space:]]*\+-o/{p="";b=""}
               /"Product" =/{s=$0; gsub(/.*= |"/,"",s); p=s}
               /"BatteryPercent" =/{s=$0; gsub(/.*= /,"",s); b=s}
               p!=""&&b!=""{print p"\t"b; p="";b=""}')"
      # connected devices: type icon + accent, click to disconnect
      while IFS=$'\t' read -r addr name kind; do
        [ -z "$addr" ] && continue
        PCT="$(printf '%s\n' "$BATT" | awk -F'\t' -v n="$name" '$1==n{print $2; exit}')"
        LBL="$name"
        [ -n "$PCT" ] && LBL="$name · ${PCT}%"
        sketchybar --add item "bluetooth.pop.$i" popup.bluetooth \
          --set "bluetooth.pop.$i" icon="$(kind_icon "$(refine_kind "$kind" "$name")")" \
            icon.color="$ACCENT" icon.padding_left=10 icon.padding_right=8 \
            label="$LBL" label.color="$ACCENT" label.padding_left=0 \
            label.padding_right=10 background.drawing=off \
            click_script="$PLUGIN_DIR/bluetooth.sh disconnect $addr"
        i=$((i + 1))
      done < <(printf '%s\n' "$DEVICES" | awk -F'\t' '$1==1 {print $2 "\t" $3 "\t" $4}')
      # paired but not connected: muted type icon, click to connect (first 6)
      while IFS=$'\t' read -r addr name kind; do
        [ -z "$addr" ] && continue
        sketchybar --add item "bluetooth.pop.$i" popup.bluetooth \
          --set "bluetooth.pop.$i" icon="$(kind_icon "$(refine_kind "$kind" "$name")")" \
            icon.color="$MUTED" icon.padding_left=10 icon.padding_right=8 \
            label="$name" label.color="$LABEL_COLOR" label.padding_left=0 \
            label.padding_right=10 background.drawing=off \
            click_script="$PLUGIN_DIR/bluetooth.sh connect $addr"
        i=$((i + 1))
      done < <(printf '%s\n' "$DEVICES" | awk -F'\t' '$1==0 {print $2 "\t" $3 "\t" $4}' | head -6)
    fi
    # quiet action rows — small + dimmed, weather-footer style
    [ "$POWER" = "1" ] && TOGGLE_LABEL="turn bluetooth off" || TOGGLE_LABEL="turn bluetooth on"
    sketchybar --add item "bluetooth.pop.$i" popup.bluetooth \
      --set "bluetooth.pop.$i" icon.drawing=off \
        label="$TOGGLE_LABEL" label.color="$DIM" \
        label.font="JetBrainsMono Nerd Font:Regular:12.0" \
        label.padding_left=10 label.padding_right=10 background.drawing=off \
        click_script="$PLUGIN_DIR/bluetooth.sh toggle_power"
    i=$((i + 1))
    sketchybar --add item "bluetooth.pop.$i" popup.bluetooth \
      --set "bluetooth.pop.$i" icon.drawing=off \
        label="bluetooth settings…" label.color="$DIM" \
        label.font="JetBrainsMono Nerd Font:Regular:12.0" \
        label.padding_left=10 label.padding_right=10 background.drawing=off \
        click_script="open 'x-apple.systempreferences:com.apple.BluetoothSettings'; sketchybar --set bluetooth popup.drawing=off"
    "$PLUGIN_DIR/popup_guard.sh" close_others bluetooth
    sketchybar --set bluetooth popup.drawing=on
    ("$PLUGIN_DIR/popup_guard.sh" bluetooth >/dev/null 2>&1 &)
    exit 0
    ;;
esac

render
