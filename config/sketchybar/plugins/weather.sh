#!/usr/bin/env bash
# Weather pill via wttr.in (no API key; located by IP). The pill shows
# condition + temperature; clicking opens a details popup built from the
# cached last fetch (instant — no network on click, which also avoids
# the popup racing the mouse-leave close). Hides itself while offline.
export PATH="/opt/homebrew/bin:$PATH"
source "$HOME/.config/omarchy/current/theme/sketchybar.sh"

CACHE="${TMPDIR:-/tmp}/sketchybar-weather"

close_popup() {
  sketchybar --set weather popup.drawing=off 2>/dev/null
  sketchybar --remove '/weather\.pop\..*/' >/dev/null 2>&1
}

case "$SENDER" in
  mouse.exited.global)
    close_popup
    exit 0
    ;;
  mouse.clicked)
    if [ "$(sketchybar --query weather | jq -r '.popup.drawing' 2>/dev/null)" = "on" ]; then
      close_popup
      exit 0
    fi
    close_popup
    [ -s "$CACHE" ] || exit 0
    i=0
    while IFS= read -r line; do
      [ "$i" -eq 0 ] && { i=1; continue; }  # line 1 is the pill text
      COLOR="$LABEL_COLOR"
      [ "$i" -eq 1 ] && COLOR="$ACCENT"
      sketchybar --add item "weather.pop.$i" popup.weather \
        --set "weather.pop.$i" \
          icon.drawing=off \
          label="$line" \
          label.color="$COLOR" \
          label.padding_left=10 \
          label.padding_right=10 \
          background.drawing=off
      i=$((i + 1))
    done < "$CACHE"
    sketchybar --set weather popup.drawing=on
("$(cd "$(dirname "$0")" && pwd)/popup_guard.sh" weather >/dev/null 2>&1 &)
    exit 0
    ;;
esac

# routine render: one fetch covers the pill (line 1) and the popup rows
DATA="$(curl -sf --max-time 6 'wttr.in/?format=%c%t\n%l\n%C+%t+(feels+%f)\nwind+%w+·+humidity+%h\n%m+moon+·+%p+precip' | sed 's/+/ /g; s/  */ /g')"
if [ -z "$DATA" ]; then
  # offline: hide the pill, keep the last cache for when we're back
  sketchybar --set "$NAME" drawing=off
  exit 0
fi
printf '%s\n' "$DATA" > "$CACHE"
sketchybar --set "$NAME" drawing=on icon.drawing=off label="$(printf '%s\n' "$DATA" | head -1)"
