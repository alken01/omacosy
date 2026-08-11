#!/usr/bin/env bash
# Sound menu popup under the volume item: a clickable volume slider plus
# every output device; clicking a device switches to it (switchaudio-osx).
export PATH="/opt/homebrew/bin:$PATH"
source "$HOME/.config/omarchy/current/theme/sketchybar.sh"
PLUGIN_DIR="$(cd "$(dirname "$0")" && pwd)"

close() {
  sketchybar --set volume popup.drawing=off 2>/dev/null
  sketchybar --remove '/volume\.menu\..*/' >/dev/null 2>&1
  sketchybar --remove volume.slider >/dev/null 2>&1
}

case "${1:-toggle}" in
  close)
    close
    exit 0
    ;;
  slider)
    # PERCENTAGE = where on the slider the user clicked
    osascript -e "set volume output volume ${PERCENTAGE:-50}"
    exit 0
    ;;
  select)
    "$HOME/.local/bin/omacosy-helper" audio set "$2" >/dev/null
    close
    exit 0
    ;;
esac

if [ "$(sketchybar --query volume | jq -r '.popup.drawing' 2>/dev/null)" = "on" ]; then
  close
  exit 0
fi
close # clear any leftovers from a previous open

VOL="$(osascript -e 'output volume of (get volume settings)')"
sketchybar --add slider volume.slider popup.volume 140 \
  --set volume.slider \
    slider.percentage="$VOL" \
    slider.highlight_color="$ACCENT" \
    slider.background.height=6 \
    slider.background.corner_radius=3 \
    slider.background.color="$ITEM_BG" \
    script="$PLUGIN_DIR/volume_menu.sh slider" \
  --subscribe volume.slider mouse.clicked

i=0
while IFS=$'\t' read -r marker dev; do
  [ -z "$dev" ] && continue
  if [ "$marker" = "*" ]; then
    ICON="󰄬" COLOR="$ACCENT"
  else
    ICON="·" COLOR="$LABEL_COLOR"
  fi
  sketchybar --add item "volume.menu.$i" popup.volume \
    --set "volume.menu.$i" \
      icon="$ICON" \
      icon.color="$COLOR" \
      label="$dev" \
      label.color="$COLOR" \
      label.padding_right=10 \
      background.drawing=off \
      click_script="$PLUGIN_DIR/volume_menu.sh select \"$dev\""
  i=$((i + 1))
done < <("$HOME/.local/bin/omacosy-helper" audio list)

sketchybar --set volume popup.drawing=on
("$(cd "$(dirname "$0")" && pwd)/popup_guard.sh" volume >/dev/null 2>&1 &)
