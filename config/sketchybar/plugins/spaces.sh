#!/usr/bin/env bash
# Single handler for workspace highlight state. One event = one pass:
# two aerospace queries and ONE sketchybar invocation for all items,
# instead of a script + two queries per workspace item (~35 process
# spawns per switch before, ~4 now).
export PATH="/opt/homebrew/bin:$PATH"
source "$HOME/.config/omarchy/current/theme/sketchybar.sh"

FOCUSED="${FOCUSED_WORKSPACE:-$(aerospace list-workspaces --focused 2>/dev/null)}"
VISIBLE=" $(aerospace list-workspaces --visible --monitor all 2>/dev/null | tr '\n' ' ') "

# Workspaces holding exactly ONE app show that app's icon beside the
# number (omarchy-style occupancy hint). COUNT flips to 2 on the first
# second distinct app — only "exactly one" matters, not the true count.
declare -A APPS COUNT
while IFS='|' read -r ws app; do
  [ -z "$ws" ] && continue
  if [ -z "${APPS[$ws]:-}" ]; then
    APPS[$ws]="$app"
    COUNT[$ws]=1
  elif [ "${APPS[$ws]}" != "$app" ]; then
    COUNT[$ws]=2
  fi
done < <(aerospace list-windows --all --format '%{workspace}|%{app-name}' 2>/dev/null)

ARGS=()
for sid in $(aerospace list-workspaces --all 2>/dev/null || echo '1 2 3 4 5 6 7 8 9'); do
  if [ "${COUNT[$sid]:-0}" = 1 ]; then
    # empty icon text + fixed width: the app-icon image needs a box to
    # draw in (an empty string alone collapses it to zero), and the
    # icon BACKGROUND component must draw for its image to render —
    # transparent color, so only the image shows
    ARGS+=(--set "space.$sid" \
      icon.drawing=on icon="" icon.width=22 icon.padding_left=4 icon.padding_right=0 \
      icon.background.drawing=on icon.background.color=0x00000000 icon.background.height=20 \
      icon.background.image="app.${APPS[$sid]}" \
      icon.background.image.scale=0.5 icon.background.image.drawing=on)
  else
    ARGS+=(--set "space.$sid" icon.drawing=off icon.width=0 \
      icon.background.drawing=off icon.background.image.drawing=off icon.padding_left=0)
  fi
  if [ "$sid" = "$FOCUSED" ]; then
    ARGS+=(--set "space.$sid" background.drawing=on background.color="$ACCENT" label.color="$BAR_BG_SOLID")
  elif [[ "$VISIBLE" == *" $sid "* ]]; then
    # visible on its monitor but not focused: bright number, no pill
    ARGS+=(--set "space.$sid" background.drawing=off label.color="$LABEL_COLOR")
  else
    ARGS+=(--set "space.$sid" background.drawing=off label.color="$MUTED")
  fi
done
[ ${#ARGS[@]} -gt 0 ] && sketchybar "${ARGS[@]}"
