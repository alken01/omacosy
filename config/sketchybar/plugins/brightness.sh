#!/usr/bin/env bash
# Brightness pill (built-in display): icon + %, scroll adjusts, click
# opens a slider popup. Event-driven off sketchybar's brightness_change
# (fires on the keyboard brightness keys) — no polling.
export PATH="/opt/homebrew/bin:$PATH"
source "$HOME/.config/omarchy/current/theme/sketchybar.sh"
PLUGIN_DIR="$(cd "$(dirname "$0")" && pwd)"

DIM="0x99${LABEL_COLOR:4}"

close_popup() {
  sketchybar --set brightness popup.drawing=off 2>/dev/null
  sketchybar --remove brightness.slider >/dev/null 2>&1
}

level_icon() { # 0-100 → glyph
  if [ "$1" -ge 66 ]; then printf '󰃠'; elif [ "$1" -ge 33 ]; then printf '󰃟'; else printf '󰃞'; fi
}

render() {
  B="$("$HOME/.local/bin/omacosy-helper" brightness 2>/dev/null)"
  case "$B" in '' | *[!0-9]*)
    # unreadable (clamshell mode etc.) — hide rather than lie
    sketchybar --set brightness drawing=off
    return
    ;;
  esac
  sketchybar --set brightness drawing=on icon="$(level_icon "$B")" label="${B}%"
}

case "${1:-}" in
  slider)
    "$HOME/.local/bin/omacosy-helper" brightness set "${PERCENTAGE:-50}" >/dev/null 2>&1
    render
    exit 0
    ;;
esac

case "$SENDER" in
  mouse.scrolled)
    B="$("$HOME/.local/bin/omacosy-helper" brightness 2>/dev/null)"
    case "$B" in '' | *[!0-9]*) exit 0 ;; esac
    DELTA="${SCROLL_DELTA:-0}"
    STEP=$((DELTA > 0 ? 5 : -5))
    N=$((B + STEP))
    [ "$N" -lt 0 ] && N=0
    [ "$N" -gt 100 ] && N=100
    "$HOME/.local/bin/omacosy-helper" brightness set "$N" >/dev/null 2>&1
    render
    # keep the open slider honest while scrolling
    sketchybar --set brightness.slider slider.percentage="$N" label="${N}%" 2>/dev/null
    exit 0
    ;;
  mouse.clicked)
    if [ "$(sketchybar --query brightness | jq -r '.popup.drawing' 2>/dev/null)" = "on" ]; then
      close_popup
      exit 0
    fi
    close_popup
    B="$("$HOME/.local/bin/omacosy-helper" brightness 2>/dev/null)"
    case "$B" in '' | *[!0-9]*) exit 0 ;; esac
    sketchybar --add slider brightness.slider popup.brightness 140 \
      --set brightness.slider \
        icon="󰃟" icon.color="$DIM" icon.padding_left=10 icon.padding_right=8 \
        label="${B}%" label.color="$DIM" label.padding_left=8 label.padding_right=10 \
        slider.percentage="$B" \
        slider.highlight_color="$ACCENT" \
        slider.background.height=6 \
        slider.background.corner_radius=3 \
        slider.background.color="$ITEM_BG" \
        script="$PLUGIN_DIR/brightness.sh slider" \
      --subscribe brightness.slider mouse.clicked
    "$PLUGIN_DIR/popup_guard.sh" close_others brightness
    sketchybar --set brightness popup.drawing=on
    ("$PLUGIN_DIR/popup_guard.sh" brightness >/dev/null 2>&1 &)
    exit 0
    ;;
esac

render
