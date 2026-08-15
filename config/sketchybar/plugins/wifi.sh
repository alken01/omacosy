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

# LABEL_COLOR at ~60% alpha for the quiet action rows (weather-popup style)
DIM="0x99${LABEL_COLOR:4}"
PUB_CACHE="${TMPDIR:-/tmp}/sketchybar-pubip"

render() {
  POWER="$(networksetup -getairportpower "$DEV" 2>/dev/null | awk '{print $NF}')"
  SSID="$(ssid)"
  IP="$(ipconfig getifaddr "$DEV" 2>/dev/null)"
  if [ "$POWER" != "On" ]; then
    sketchybar --set wifi icon="󰖪" icon.padding_right=4 label.drawing=on label="off" label.padding_right=10
  elif [ -n "$SSID" ]; then
    sketchybar --set wifi icon="󰖩" icon.padding_right=4 label.drawing=on label="$SSID" label.padding_right=10
  elif [ -n "$IP" ]; then
    # connected but macOS redacts the name: icon-only pill
    sketchybar --set wifi icon="󰖩" icon.padding_right=10 label.drawing=off label.padding_right=0
  else
    sketchybar --set wifi icon="󰖪" icon.padding_right=10 label.drawing=off label.padding_right=0
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
    GW="$(route -n get default 2>/dev/null | awk '/gateway:/{print $2; exit}')"
    row() { # name  label  color  [font]
      sketchybar --add item "$1" popup.wifi \
        --set "$1" icon.drawing=off label="$2" label.color="$3" \
          ${4:+label.font="$4"} \
          label.padding_left=10 label.padding_right=10 background.drawing=off
    }
    if [ "$POWER" = "On" ]; then
      # hero fills in the signal verdict asynchronously (~3s fetch)
      row wifi.pop.0 "${SSID:-connected}" "$ACCENT" "JetBrainsMono Nerd Font:Bold:14.0"
      row wifi.pop.1 "ip ${IP:-none yet} · gateway ${GW:-?}" "$LABEL_COLOR"
      row wifi.pop.2 "measuring link…" "$DIM"
      # public ip: cached 15min so the row is instant on repeat opens
      if [ -s "$PUB_CACHE" ] && [ "$(($(date +%s) - $(stat -f %m "$PUB_CACHE")))" -lt 900 ]; then
        row wifi.pop.3 "public ip $(cat "$PUB_CACHE")" "$LABEL_COLOR"
      else
        row wifi.pop.3 "public ip …" "$DIM"
      fi
      NEXT=4
    else
      row wifi.pop.0 "wi-fi is off" "$DIM"
      NEXT=1
    fi
    # quiet action rows — small + dimmed, weather-footer style
    [ "$POWER" = "On" ] && TOGGLE_LABEL="turn wi-fi off" || TOGGLE_LABEL="turn wi-fi on"
    sketchybar --add item "wifi.pop.$NEXT" popup.wifi \
      --set "wifi.pop.$NEXT" icon.drawing=off \
        label="$TOGGLE_LABEL" label.color="$DIM" \
        label.font="JetBrainsMono Nerd Font:Regular:12.0" \
        label.padding_left=10 label.padding_right=10 background.drawing=off \
        click_script="$PLUGIN_DIR/wifi.sh toggle_power"
    NEXT=$((NEXT + 1))
    sketchybar --add item "wifi.pop.$NEXT" popup.wifi \
      --set "wifi.pop.$NEXT" icon.drawing=off \
        label="wi-fi settings…" label.color="$DIM" \
        label.font="JetBrainsMono Nerd Font:Regular:12.0" \
        label.padding_left=10 label.padding_right=10 background.drawing=off \
        click_script="open 'x-apple.systempreferences:com.apple.wifi-settings-extension'; sketchybar --set wifi popup.drawing=off"
    "$PLUGIN_DIR/popup_guard.sh" close_others wifi
    sketchybar --set wifi popup.drawing=on
    ("$PLUGIN_DIR/popup_guard.sh" wifi >/dev/null 2>&1 &)
    if [ "$POWER" = "On" ]; then
      # fill the slow rows AFTER the popup is already on screen; if the
      # popup closed meanwhile the --set just misses (items removed)
      (
        LINK="$(system_profiler SPAirPortDataType -detailLevel basic 2>/dev/null | awk '
          /Signal \/ Noise:/ { if (sig == "") sig = $4 }
          /^ *Channel:/ { if (ch == "") { ch = $2; band = $3; gsub(/[(,]/, "", band) } }
          /^ *Security:/ { if (sec == "") sec = tolower($2) }
          /Transmit Rate:/ { if (rate == "") rate = $3 }
          END { if (sig != "") printf "%s\t%s\t%s\t%s\t%s", sig, ch, band, sec, rate }')"
        if [ -n "$LINK" ]; then
          IFS=$'\t' read -r SIG CH BAND SEC RATE <<<"$LINK"
          QUAL="$(awk -v s="$SIG" 'BEGIN{s+=0; print (s>=-55)?"excellent":(s>=-67)?"good":(s>=-75)?"fair":"weak"}')"
          sketchybar --set wifi.pop.0 label="${SSID:-connected} · $QUAL signal" 2>/dev/null
          sketchybar --set wifi.pop.2 \
            label="channel $CH · $BAND · $SEC · ${RATE} Mbps · ${SIG} dBm" \
            label.color="$LABEL_COLOR" 2>/dev/null
        else
          sketchybar --set wifi.pop.2 label="link details unavailable" 2>/dev/null
        fi
        PUB="$(curl -sf --max-time 3 https://api.ipify.org 2>/dev/null)"
        if [ -n "$PUB" ]; then
          printf '%s' "$PUB" >"$PUB_CACHE"
          sketchybar --set wifi.pop.3 label="public ip $PUB" label.color="$LABEL_COLOR" 2>/dev/null
        fi
      ) &
    fi
    exit 0
    ;;
esac

render
