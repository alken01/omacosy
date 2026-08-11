#!/usr/bin/env bash
source "$HOME/.config/omarchy/current/theme/sketchybar.sh"

if [ "$1" = "$FOCUSED_WORKSPACE" ]; then
  sketchybar --set "$NAME" \
    background.drawing=on \
    background.color="$ACCENT" \
    label.color="$BAR_BG_SOLID"
else
  sketchybar --set "$NAME" \
    background.drawing=off \
    label.color="$MUTED"
fi
