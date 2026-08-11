#!/usr/bin/env bash
# popup_guard.sh <anchor-item> — closes the anchor's popup when the
# cursor leaves the measured item+popup rectangle (plus margin).
# Started by whichever plugin opens a popup; one instance per anchor;
# exits when the popup is gone. Deterministic replacement for
# sketchybar's unreliable mouse.exited.global event.
export PATH="/opt/homebrew/bin:$PATH"

ANCHOR="${1:-}"
case "$ANCHOR" in
  clock) CHILD_RE='^clock\.cal\.' ;;
  volume) CHILD_RE='^volume\.(menu\.|slider)' ;;
  weather) CHILD_RE='^weather\.pop\.' ;;
  wifi) CHILD_RE='^wifi\.pop\.' ;;
  bluetooth) CHILD_RE='^bt\.pop\.' ;;
  *) exit 0 ;;
esac

LOCKDIR="${TMPDIR:-/tmp}/sketchybar-popup-guard-$ANCHOR.lock"
mkdir "$LOCKDIR" 2>/dev/null || exit 0
trap 'rmdir "$LOCKDIR" 2>/dev/null' EXIT

close_popup() {
  sketchybar --set "$ANCHOR" popup.drawing=off 2>/dev/null
  case "$ANCHOR" in
    clock) sketchybar --remove '/clock\.cal\..*/' >/dev/null 2>&1 ;;
    volume)
      sketchybar --remove '/volume\.menu\..*/' >/dev/null 2>&1
      sketchybar --remove volume.slider >/dev/null 2>&1
      ;;
    weather) sketchybar --remove '/weather\.pop\..*/' >/dev/null 2>&1 ;;
    wifi) sketchybar --remove '/wifi\.pop\..*/' >/dev/null 2>&1 ;;
    bluetooth) sketchybar --remove '/bt\.pop\..*/' >/dev/null 2>&1 ;;
  esac
}

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

tick=0
for _ in $(seq 1 500); do # ~75s ceiling
  sleep 0.12
  POS="$(cliclick p 2>/dev/null)"
  X="${POS%,*}"
  Y="${POS#*,}"
  case "$X$Y" in '' | *[!0-9-]*) continue ;; esac
  if [ "$X" -lt "$X0" ] || [ "$X" -gt "$X1" ] || [ "$Y" -lt "$Y0" ] || [ "$Y" -gt "$Y1" ]; then
    close_popup
    exit 0
  fi
  tick=$((tick + 1))
  if [ $((tick % 15)) -eq 0 ] &&
    [ "$(sketchybar --query "$ANCHOR" | jq -r '.popup.drawing' 2>/dev/null)" != "on" ]; then
    exit 0
  fi
done
close_popup
