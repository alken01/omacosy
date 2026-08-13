#!/usr/bin/env bash
# Single handler for workspace highlight state. One event = one pass:
# two aerospace queries and ONE sketchybar invocation for all items,
# instead of a script + two queries per workspace item (~35 process
# spawns per switch before, ~4 now).
export PATH="/opt/homebrew/bin:$PATH"
source "$HOME/.config/omarchy/current/theme/sketchybar.sh"

FOCUSED="${FOCUSED_WORKSPACE:-$(aerospace list-workspaces --focused 2>/dev/null)}"
VISIBLE=" $(aerospace list-workspaces --visible --monitor all 2>/dev/null | tr '\n' ' ') "

# Workspaces holding exactly ONE tiled app show that app's icon
# INSTEAD of the number (omarchy-style, and the icon is identity
# enough — a number next to it just spends notch-adjacent width).
# Floating windows don't count: they're transient guests (System
# Settings over the terminal must not strip korren's icon). COUNT
# flips to 2 on the first second distinct app — only "exactly one"
# matters, not the true count.
declare -A APPS COUNT
while IFS='|' read -r ws app layout; do
  [ -z "$ws" ] && continue
  [ "$layout" = "floating" ] && continue
  if [ -z "${APPS[$ws]:-}" ]; then
    APPS[$ws]="$app"
    COUNT[$ws]=1
  elif [ "${APPS[$ws]}" != "$app" ]; then
    COUNT[$ws]=2
  fi
done < <(aerospace list-windows --all --format '%{workspace}|%{app-name}|%{window-layout}' 2>/dev/null)

# One fixed slot width for every workspace item, icon or number, so
# the row's rhythm doesn't shift as apps come and go.
SLOT_W=24

ARGS=()
for sid in $(aerospace list-workspaces --all 2>/dev/null || echo '1 2 3 4 5 6 7 8 9'); do
  if [ "${COUNT[$sid]:-0}" = 1 ]; then
    # empty icon text + fixed width: the app-icon image needs a box to
    # draw in (an empty string alone collapses it to zero), and the
    # icon BACKGROUND component must draw for its image to render —
    # transparent color, so only the image shows. The number label is
    # hidden; the icon carries the slot (keeps the row clear of the
    # notch).
    # SLOT_W keeps icon slots and number slots the same width, and
    # the image centers in the icon's fixed box — uniform pills
    # either way.
    ARGS+=(--set "space.$sid" \
      icon.drawing=on icon="" icon.width="$SLOT_W" icon.padding_left=0 icon.padding_right=0 \
      icon.background.drawing=on icon.background.color=0x00000000 icon.background.height=20 \
      icon.background.image="app.${APPS[$sid]}" \
      icon.background.image.scale=0.5 icon.background.image.drawing=on \
      label.drawing=off label.padding_left=0 label.padding_right=0)
  else
    ARGS+=(--set "space.$sid" icon.drawing=off icon.width=0 \
      icon.background.drawing=off icon.background.image.drawing=off icon.padding_left=0 \
      label.drawing=on label.width="$SLOT_W" label.align=center \
      label.padding_left=0 label.padding_right=0)
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
