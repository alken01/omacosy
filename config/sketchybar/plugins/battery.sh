#!/usr/bin/env bash
export PATH="/opt/homebrew/bin:$PATH"
source "$HOME/.config/omarchy/current/theme/sketchybar.sh"

PERCENTAGE="$(pmset -g batt | grep -Eo '\d+%' | cut -d% -f1)"
CHARGING="$(pmset -g batt | grep 'AC Power')"

if [ -z "$PERCENTAGE" ]; then
  exit 0
fi

case "$PERCENTAGE" in
  9[0-9]|100) ICON="󰁹" COLOR="$GREEN" ;;
  [6-8][0-9]) ICON="󰂀" COLOR="$LABEL_COLOR" ;;
  [3-5][0-9]) ICON="󰁾" COLOR="$LABEL_COLOR" ;;
  [1-2][0-9]) ICON="󰁻" COLOR="$YELLOW" ;;
  *)          ICON="󰂃" COLOR="$RED" ;;
esac

if [ -n "$CHARGING" ]; then
  ICON="󰂄" COLOR="$GREEN"
fi

sketchybar --set "$NAME" icon="$ICON" icon.color="$COLOR" label="${PERCENTAGE}%"
