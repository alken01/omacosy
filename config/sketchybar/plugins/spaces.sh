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

# One fixed content-box width for every workspace item, icon or
# number (item padding 2/2 completes the slot), so the row's rhythm
# doesn't shift as apps come and go. 20 = the icon image size (32px
# canvas at scale 0.625); the number label uses the same box.
BOX_W=20

ARGS=()
for sid in $(aerospace list-workspaces --all 2>/dev/null || echo '1 2 3 4 5 6 7 8 9'); do
  if [ "${COUNT[$sid]:-0}" = 1 ]; then
    # empty icon text + fixed width: the app-icon image needs a box to
    # draw in (an empty string alone collapses it to zero), and the
    # icon BACKGROUND component must draw for its image to render —
    # transparent color, so only the image shows. The number label is
    # hidden; the icon carries the slot (keeps the row clear of the
    # notch). The image is LEFT-ALIGNED in the icon's box (measured:
    # ink sat (box-image)/2 left of every slot center), so centering
    # means box == image: BOX_W box, 32px icon canvas at scale
    # 0.625 = 20px. (Paddings on an empty icon are ignored — also
    # measured — so the box IS the footprint; item padding spaces it.)
    ARGS+=(--set "space.$sid" \
      icon.drawing=on icon="" icon.width="$BOX_W" \
      icon.padding_left=0 icon.padding_right=0 \
      icon.background.drawing=on icon.background.color=0x00000000 icon.background.height=20 \
      icon.background.image="app.${APPS[$sid]}" \
      icon.background.image.scale=0.625 icon.background.image.drawing=on \
      label.drawing=off label.width=0 label.padding_left=0 label.padding_right=0)
  else
    # icon.padding_right=0 matters: the bar-wide --default gives every
    # item icon.padding_right=4, which survives icon.drawing=off and
    # shoved the digits ~4px right of slot center
    ARGS+=(--set "space.$sid" icon.drawing=off icon.width=0 \
      icon.background.drawing=off icon.background.image.drawing=off \
      icon.padding_left=0 icon.padding_right=0 \
      label.drawing=on label.width="$BOX_W" label.align=center \
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
