#!/usr/bin/env bash
if [ "$SENDER" = "mouse.exited.global" ]; then
  "$CONFIG_DIR/plugins/calendar.sh" close
  exit 0
fi
sketchybar --set "$NAME" icon="󰃰" label="$(date '+%a %d %b  %H:%M')"
