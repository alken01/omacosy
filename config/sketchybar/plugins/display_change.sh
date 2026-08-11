#!/usr/bin/env bash
# Reload the bar only when the number of displays actually changed —
# display_change also fires during reloads, which would loop forever.
export PATH="/opt/homebrew/bin:$PATH"
STATE="${TMPDIR:-/tmp}/omacosy-monitor-count"
COUNT="$(aerospace list-monitors 2>/dev/null | wc -l | tr -d ' ')"
[ -z "$COUNT" ] || [ "$COUNT" = "0" ] && exit 0
PREV="$(cat "$STATE" 2>/dev/null)"
echo "$COUNT" > "$STATE"
[ -n "$PREV" ] && [ "$COUNT" != "$PREV" ] && sketchybar --reload
exit 0
