#!/usr/bin/env bash
export PATH="/opt/homebrew/bin:$PATH"
source "$HOME/.config/omarchy/current/theme/sketchybar.sh"

SID="$1"
FOCUSED="${FOCUSED_WORKSPACE:-$(aerospace list-workspaces --focused 2>/dev/null)}"
VISIBLE=" $(aerospace list-workspaces --visible --monitor all 2>/dev/null | tr '\n' ' ') "

if [ "$SID" = "$FOCUSED" ]; then
  # focused workspace: accent pill
  sketchybar --set "$NAME" \
    background.drawing=on \
    background.color="$ACCENT" \
    label.color="$BAR_BG_SOLID"
elif [[ "$VISIBLE" == *" $SID "* ]]; then
  # visible on its monitor but not focused: subtle pill
  sketchybar --set "$NAME" \
    background.drawing=on \
    background.color="$ITEM_BG" \
    label.color="$LABEL_COLOR"
else
  sketchybar --set "$NAME" \
    background.drawing=off \
    label.color="$MUTED"
fi
