#!/usr/bin/env bash
# popup_guard.sh <anchor-item>          — close the anchor's popup once the
#   cursor is outside BOTH the bar strip and the item+popup hull (plus
#   margin), so sliding along the bar keeps the popup open.
# popup_guard.sh close_others <anchor>  — close every other anchor's popup
#   (popups are exclusive: opening one dismisses the rest).
# Started by whichever plugin opens a popup; one instance per anchor;
# exits when the popup is gone. Sole owner of popup dismissal — the
# plugins no longer listen to sketchybar's unreliable mouse.exited.global.
export PATH="/opt/homebrew/bin:$PATH"

# The ONLY per-anchor registry. Everything else is derived from the
# naming convention: an anchor's popup children are ALL named
# "<anchor>.<something>" (clock.cal.3, volume.slider, bluetooth.pop.1)
# and nothing outside its popup may use that prefix.
ANCHORS="clock volume brightness weather wifi bluetooth apple"

close_one() {
  sketchybar --set "$1" popup.drawing=off 2>/dev/null
  # sketchybar's regex has no `+`; the mandatory dot spares the anchor
  sketchybar --remove "/$1\..*/" >/dev/null 2>&1
}

if [ "${1:-}" = "close_others" ]; then
  for a in $ANCHORS; do
    [ "$a" != "${2:-}" ] && close_one "$a"
  done
  exit 0
fi

ANCHOR="${1:-}"
[ -n "$ANCHOR" ] || exit 0
case " $ANCHORS " in
  *" $ANCHOR "*) ;;
  *) exit 0 ;;
esac
CHILD_RE="^$ANCHOR\."

LOCKDIR="${TMPDIR:-/tmp}/sketchybar-popup-guard-$ANCHOR.lock"
mkdir "$LOCKDIR" 2>/dev/null || exit 0
trap 'rmdir "$LOCKDIR" 2>/dev/null' EXIT

sleep 0.25 # let the popup lay out before measuring

# Hull over the anchor and its popup items (screens the item isn't on
# report origin -9999; filter those out).
ITEMS="$ANCHOR $(sketchybar --query bar | jq -r '.items[]' | grep -E "$CHILD_RE")"
HULL="$(for it in $ITEMS; do
  sketchybar --query "$it" 2>/dev/null |
    jq -c '.bounding_rects // {} | to_entries[] | select(.value.origin[0] > -9000) | .value'
done | jq -s 'if length == 0 then empty else
  {x0: (map(.origin[0]) | min), y0: (map(.origin[1]) | min),
   x1: (map(.origin[0] + .size[0]) | max), y1: (map(.origin[1] + .size[1]) | max)}
end')"

if [ -z "$HULL" ]; then
  X0=0 Y0=0 X1=99999 Y1=300 # fallback: generous top strip
else
  X0="$(jq -r '.x0 - 25 | floor' <<<"$HULL")"
  Y0="$(jq -r '.y0 - 25 | floor' <<<"$HULL")"
  X1="$(jq -r '.x1 + 25 | ceil' <<<"$HULL")"
  Y1="$(jq -r '.y1 + 25 | ceil' <<<"$HULL")"
fi

# The bar strips (one per display, from the anchor's own rects): while
# the cursor rides anywhere along the bar the popup stays open.
BAR_H="$(sketchybar --query bar | jq -r '.height // 34')"
STRIPS="$(sketchybar --query "$ANCHOR" 2>/dev/null | jq -r --argjson h "$BAR_H" '
  .bounding_rects // {} | to_entries[]
  | select(.value.origin[0] > -9000)
  | "\(.value.origin[1] - 2 | floor) \(.value.origin[1] + $h + 2 | ceil)"')"

tick=0
for _ in $(seq 1 500); do # ~75s ceiling
  sleep 0.12
  POS="$($HOME/.local/bin/omacosy-helper cursor 2>/dev/null)"
  X="${POS%,*}"
  Y="${POS#*,}"
  case "$X$Y" in '' | *[!0-9-]*) continue ;; esac
  INSIDE=0
  if [ "$X" -ge "$X0" ] && [ "$X" -le "$X1" ] && [ "$Y" -ge "$Y0" ] && [ "$Y" -le "$Y1" ]; then
    INSIDE=1
  else
    while read -r S0 S1; do
      [ -n "$S0" ] && [ "$Y" -ge "$S0" ] && [ "$Y" -le "$S1" ] && INSIDE=1 && break
    done <<<"$STRIPS"
  fi
  if [ "$INSIDE" = 0 ]; then
    close_one "$ANCHOR"
    exit 0
  fi
  tick=$((tick + 1))
  if [ $((tick % 15)) -eq 0 ] &&
    [ "$(sketchybar --query "$ANCHOR" | jq -r '.popup.drawing' 2>/dev/null)" != "on" ]; then
    exit 0
  fi
done
close_one "$ANCHOR"
