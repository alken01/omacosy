#!/usr/bin/env bash
# Toggle a month-calendar popup under the clock. Rows are rebuilt from
# `cal` on every open so the month is always current; the current day is
# highlighted by cal's own marker being restyled via the accent color.

source "$HOME/.config/omarchy/current/theme/sketchybar.sh"

OPEN="$(sketchybar --query clock | jq -r '.popup.drawing' 2>/dev/null)"

if [ "${1:-toggle}" = "close" ]; then
  if [ "$OPEN" = "on" ]; then
    sketchybar --set clock popup.drawing=off
    sketchybar --remove '/clock.cal\..*/' >/dev/null 2>&1
  fi
  exit 0
fi

if [ "$OPEN" = "on" ]; then
  sketchybar --set clock popup.drawing=off
  sketchybar --remove '/clock.cal\..*/' >/dev/null 2>&1
  exit 0
fi

sketchybar --remove '/clock.cal\..*/' >/dev/null 2>&1

i=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  sketchybar --add item "clock.cal.$i" popup.clock \
    --set "clock.cal.$i" \
      icon.drawing=off \
      label="$line" \
      label.font="JetBrainsMono Nerd Font:Regular:13.0" \
      label.color="$LABEL_COLOR" \
      label.padding_left=10 \
      label.padding_right=10 \
      background.drawing=off
  i=$((i + 1))
done < <(cal | sed 's/ *$//')

# accent the header row
sketchybar --set clock.cal.0 label.color="$ACCENT" 2>/dev/null

sketchybar --set clock popup.drawing=on
("$(cd "$(dirname "$0")" && pwd)/popup_guard.sh" >/dev/null 2>&1 &)
