#!/usr/bin/env bash
export PATH="/opt/homebrew/bin:$PATH"
# Renders the volume item and handles interaction:
#   scroll = adjust, left click = sound menu popup, right click = mute

case "$SENDER" in
  mouse.scrolled)
    DELTA="${SCROLL_DELTA:-0}"
    STEP=$(( DELTA > 0 ? 5 : -5 ))
    osascript -e "set volume output volume ((output volume of (get volume settings)) + $STEP)"
    exit 0  # volume_change fires and re-renders
    ;;
  mouse.clicked)
    if [ "$BUTTON" = "right" ]; then
      osascript -e 'set volume output muted (not output muted of (get volume settings))'
      # fall through to re-render (mute doesn't fire volume_change)
    else
      "$CONFIG_DIR/plugins/volume_menu.sh" toggle
      exit 0
    fi
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
# keep the popup slider in sync if it's open
sketchybar --set volume.slider slider.percentage="$VOLUME" >/dev/null 2>&1 || true
