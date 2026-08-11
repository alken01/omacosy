#!/usr/bin/env bash
# Single handler for workspace highlight state. One event = one pass:
# two aerospace queries and ONE sketchybar invocation for all items,
# instead of a script + two queries per workspace item (~35 process
# spawns per switch before, ~4 now).
export PATH="/opt/homebrew/bin:$PATH"
source "$HOME/.config/omarchy/current/theme/sketchybar.sh"

FOCUSED="${FOCUSED_WORKSPACE:-$(aerospace list-workspaces --focused 2>/dev/null)}"
VISIBLE=" $(aerospace list-workspaces --visible --monitor all 2>/dev/null | tr '\n' ' ') "

ARGS=()
for sid in $(aerospace list-workspaces --all 2>/dev/null || echo '1 2 3 4 5 6 7 8 9'); do
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
