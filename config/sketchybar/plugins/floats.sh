#!/usr/bin/env bash
# floats — how many floating windows the focused workspace is holding.
#
# A float sinks behind tiles as soon as another app takes focus (macOS
# z-orders per app), so it can vanish without leaving a trace anywhere
# else. This pill is that trace: it appears only while floats exist, and
# a click hands one back (omacosy-float, same as Super+S).
export PATH="/opt/homebrew/bin:$PATH"

N="$(aerospace list-windows --workspace focused --format '%{window-layout}' 2>/dev/null |
  grep -c '^floating$')"

# unreadable or none: say nothing rather than sit there claiming zero
if [ "${N:-0}" -lt 1 ]; then
  sketchybar --set floats drawing=off
  exit 0
fi

sketchybar --set floats drawing=on label="$N"
