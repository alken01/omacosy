#!/usr/bin/env bash
# Spotify media item: renders track + play state; hides itself (and the
# capsule) when Spotify isn't running. Updates on Spotify's own
# PlaybackStateChanged notification plus a slow poll as fallback.
source "$HOME/.config/omarchy/current/theme/sketchybar.sh"

hide() {
  sketchybar --set media.title drawing=off \
    --set media.prev drawing=off \
    --set media.play drawing=off \
    --set media.next drawing=off \
    --set media background.drawing=off
}

if ! pgrep -xq Spotify; then
  hide
  exit 0
fi

STATE="$(osascript -e 'tell application "Spotify" to player state as string' 2>/dev/null)"
TRACK="$(osascript -e 'tell application "Spotify" to name of current track' 2>/dev/null)"
ARTIST="$(osascript -e 'tell application "Spotify" to artist of current track' 2>/dev/null)"

if [ -z "$TRACK" ]; then
  hide
  exit 0
fi

if [ "$STATE" = "playing" ]; then PICON="󰏤"; else PICON="󰐊"; fi

sketchybar --set media.title drawing=on label="$ARTIST — $TRACK" \
  --set media.prev drawing=on \
  --set media.play drawing=on icon="$PICON" \
  --set media.next drawing=on \
  --set media background.drawing=on
# re-pin the order — q stacking drifts (see sketchybarrc)
sketchybar --move media.title before media.prev \
  --move media.next after media.title \
  --move media.play after media.next
