#!/usr/bin/env bash
# Toggle a month-calendar popup under the clock. The grid is composed
# here (not `cal`): Monday-first, a real title, the current week
# carried by an accent gutter marker + a subtle pill, and an ISO-week
# footer. Everything monospace so the columns hold.

source "$HOME/.config/omarchy/current/theme/sketchybar.sh"

OPEN="$(sketchybar --query clock | jq -r '.popup.drawing' 2>/dev/null)"

if [ "${1:-toggle}" = "close" ]; then
  if [ "$OPEN" = "on" ]; then
    sketchybar --set clock popup.drawing=off
    sketchybar --remove '/clock.cal\..*/' >/dev/null 2>&1
  fi
  exit 0
fi

if [ "$OPEN" = "on" ]; then
  sketchybar --set clock popup.drawing=off
  sketchybar --remove '/clock.cal\..*/' >/dev/null 2>&1
  exit 0
fi

sketchybar --remove '/clock.cal\..*/' >/dev/null 2>&1

DIM="0x99${LABEL_COLOR:4}"
MONO="JetBrainsMono Nerd Font:Regular:13.0"

Y="$(date +%Y)"
M="$(date +%m)"
TODAY=$((10#$(date +%d)))
FIRST_DOW="$(date -j -f "%Y-%m-%d" "$Y-$M-01" +%u 2>/dev/null)" # 1=Mon
DAYS="$(date -j -f "%Y-%m-%d" -v+1m -v-1d "$Y-$M-01" +%d 2>/dev/null)"
TITLE="$(date '+%B %Y' | tr '[:upper:]' '[:lower:]')"
WEEK=$((10#$(date +%V)))

# compose the week rows, monday-first, 7 × "%2d " cells. Blank cells
# are filled with the adjacent months' days so every row carries the
# full 7 columns — sketchybar measures labels from the first ink and
# collapses any leading whitespace (ASCII, NBSP and figure space all
# render zero-width), which blanked a padded first week entirely.
PREV_LAST=$((10#$(date -j -f "%Y-%m-%d" -v-1d "$Y-$M-01" +%d 2>/dev/null)))
ROWS=()
row=""
for ((p = 1; p < FIRST_DOW; p++)); do
  row+="$(printf '%2d ' $((PREV_LAST - FIRST_DOW + 1 + p)))"
done
NEXT=1
for ((d = 1; d <= DAYS; d++)); do
  row+="$(printf '%2d ' "$d")"
  dow=$(((FIRST_DOW - 1 + d - 1) % 7))
  if [ "$dow" = 6 ]; then
    ROWS+=("${row% }")
    row=""
  elif [ "$d" = "$DAYS" ]; then
    while [ "$dow" -lt 6 ]; do
      row+="$(printf '%2d ' "$NEXT")"
      NEXT=$((NEXT + 1))
      dow=$((dow + 1))
    done
    ROWS+=("${row% }")
    row=""
  fi
done
TODAY_ROW=$(((FIRST_DOW - 1 + TODAY - 1) / 7))

i=0
add_row() { # label  font  color  [today-week]
  local extra=()
  if [ "${4:-}" = today ]; then
    extra=(icon="▸" icon.color="$ACCENT"
      background.drawing=on background.color="$ITEM_BG"
      background.corner_radius=4 background.height=20)
  else
    extra=(icon=" " background.drawing=off)
  fi
  sketchybar --add item "clock.cal.$i" popup.clock \
    --set "clock.cal.$i" \
      icon.drawing=on icon.font="$MONO" icon.width=12 \
      icon.padding_left=6 icon.padding_right=3 icon.color="$ACCENT" \
      label="$1" label.font="$2" label.color="$3" \
      label.padding_left=0 label.padding_right=10 \
      "${extra[@]}"
  i=$((i + 1))
}

add_row "$TITLE" "JetBrainsMono Nerd Font:SemiBold:13.0" "$ACCENT"
add_row "mo tu we th fr sa su" "$MONO" "$DIM"
for r in "${!ROWS[@]}"; do
  if [ "$r" = "$TODAY_ROW" ]; then
    add_row "${ROWS[$r]}" "$MONO" "$LABEL_COLOR" today
  else
    add_row "${ROWS[$r]}" "$MONO" "$LABEL_COLOR"
  fi
done
add_row "week $WEEK" "JetBrainsMono Nerd Font:Regular:12.0" "$DIM"

"$(cd "$(dirname "$0")" && pwd)/popup_guard.sh" close_others clock
sketchybar --set clock popup.drawing=on
("$(cd "$(dirname "$0")" && pwd)/popup_guard.sh" clock >/dev/null 2>&1 &)
