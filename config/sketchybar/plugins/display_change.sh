#!/usr/bin/env bash
# Reload the bar only when the number of displays actually changed —
# display_change also fires during reloads, which would loop forever.
export PATH="/opt/homebrew/bin:$PATH"
STATE="${TMPDIR:-/tmp}/omacosy-monitor-count"
COUNT="$(aerospace list-monitors 2>/dev/null | wc -l | tr -d ' ')"
[ -z "$COUNT" ] || [ "$COUNT" = "0" ] && exit 0
PREV="$(cat "$STATE" 2>/dev/null)"
echo "$COUNT" > "$STATE"
if [ -n "$PREV" ] && [ "$COUNT" != "$PREV" ]; then
  # fold the lost display's workspaces into empty 1-9 slots / unfold
  # them on replug — BEFORE the reload so the bar paints the result
  if [ "$COUNT" -lt "$PREV" ]; then
    "$HOME/.local/bin/omacosy-ws-collapse" collapse
  else
    "$HOME/.local/bin/omacosy-ws-collapse" restore
  fi
  sketchybar --reload
fi
exit 0
