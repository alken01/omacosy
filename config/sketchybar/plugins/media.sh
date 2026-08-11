#!/usr/bin/env bash
# Spotify media item: renders track + play state; hides itself (and the
# capsule) when Spotify isn't running. Updates on Spotify's own
# PlaybackStateChanged notification plus a slow poll as fallback.
source "$HOME/.config/omarchy/current/theme/sketchybar.sh"

hide() {
  for S in media media2; do
    sketchybar --set "$S.title" drawing=off \
      --set "$S.prev" drawing=off \
      --set "$S.play" drawing=off \
      --set "$S.next" drawing=off \
      --set "$S" background.drawing=off 2>/dev/null
  done
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

for S in media media2; do
  sketchybar --set "$S.title" drawing=on label="$ARTIST — $TRACK" \
    --set "$S.prev" drawing=on \
    --set "$S.play" drawing=on icon="$PICON" \
    --set "$S.next" drawing=on \
    --set "$S" background.drawing=on 2>/dev/null
done
