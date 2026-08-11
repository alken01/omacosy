#!/usr/bin/env bash
# Renders the volume item and handles interaction:
#   scroll = adjust, left click = toggle mute, right click = Sound settings

case "$SENDER" in
  mouse.scrolled)
    DELTA="${SCROLL_DELTA:-0}"
    STEP=$(( DELTA > 0 ? 5 : -5 ))
    osascript -e "set volume output volume ((output volume of (get volume settings)) + $STEP)"
    exit 0  # volume_change fires and re-renders
    ;;
  mouse.clicked)
    if [ "$BUTTON" = "right" ]; then
      open 'x-apple.systempreferences:com.apple.Sound-Settings.extension'
    else
      osascript -e 'set volume output muted (not output muted of (get volume settings))'
    fi
    # fall through to re-render (mute doesn't fire volume_change)
    ;;
esac

MUTED="$(osascript -e 'output muted of (get volume settings)')"
if [ "$SENDER" = "volume_change" ]; then
  VOLUME="$INFO"
else
  VOLUME="$(osascript -e 'output volume of (get volume settings)')"
fi

if [ "$MUTED" = "true" ]; then
  ICON="󰝟"
  LABEL="mute"
else
  case "$VOLUME" in
    [7-9][0-9]|100) ICON="󰕾" ;;
    [3-6][0-9])     ICON="󰖀" ;;
    [1-9]|[1-2][0-9]) ICON="󰕿" ;;
    *)              ICON="󰝟" ;;
  esac
  LABEL="${VOLUME}%"
fi

sketchybar --set "$NAME" icon="$ICON" label="$LABEL"
