#!/usr/bin/env bash
# Watches the cursor while a bar popup is open and closes all popups as
# soon as the pointer leaves the top strip (bar + popup zone). Started
# by whichever plugin opens a popup; single instance; exits once no
# popup is open. Deterministic replacement for sketchybar's unreliable
# mouse.exited.global event.
#
# Hot loop stays cheap: only cliclick runs per tick; popup state (which
# needs slower query calls) is only re-checked every ~2s to let the
# guard exit after a popup was closed by its own toggle.
export PATH="/opt/homebrew/bin:$PATH"

LOCKDIR="${TMPDIR:-/tmp}/sketchybar-popup-guard.lock"
mkdir "$LOCKDIR" 2>/dev/null || exit 0
trap 'rmdir "$LOCKDIR" 2>/dev/null' EXIT

ZONE=300 # px from the top of the screen that counts as "at the bar"

close_all() {
  sketchybar --set clock popup.drawing=off \
    --set volume popup.drawing=off \
    --set weather popup.drawing=off 2>/dev/null
  sketchybar --remove '/clock.cal\..*/' >/dev/null 2>&1
  sketchybar --remove '/volume\.menu\..*/' >/dev/null 2>&1
  sketchybar --remove volume.slider >/dev/null 2>&1
  sketchybar --remove '/weather\.pop\..*/' >/dev/null 2>&1
}

any_open() {
  for it in clock volume weather; do
    [ "$(sketchybar --query "$it" | jq -r '.popup.drawing' 2>/dev/null)" = "on" ] && return 0
  done
  return 1
}

tick=0
for _ in $(seq 1 400); do # ~60s ceiling
  sleep 0.15
  POS="$(cliclick p 2>/dev/null)"
  Y="${POS#*,}"
  case "$Y" in '' | *[!0-9]*) : ;; *)
    if [ "$Y" -gt "$ZONE" ]; then
      close_all
      exit 0
    fi
  ;; esac
  tick=$((tick + 1))
  if [ $((tick % 12)) -eq 0 ] && ! any_open; then
    exit 0
  fi
done
close_all
