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

# LABEL_COLOR at ~60% alpha for the quiet action rows (weather-popup style)
DIM="0x99${LABEL_COLOR:4}"

# output-device icon from the name — CoreAudio exposes no device class,
# so heuristics it is
dev_icon() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    *macbook*) printf '󰌢' ;;
    *airpods* | *headphone* | *buds* | *momentum* | *wh-1000* | *quietcomfort* | *qc\ *) printf '󰋋' ;;
    *display* | *tv* | *hdmi* | *lg* | *dell* | *benq*) printf '󰍹' ;;
    *airplay* | *homepod*) printf '󰀟' ;;
    *background\ music* | *blackhole* | *loopback* | *soundflower* | *virtual*) printf '󰕾' ;;
    *) printf '󰓃' ;;
  esac
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
sketchybar --add slider volume.slider popup.volume 160 \
  --set volume.slider \
    icon="󰕾" icon.color="$DIM" icon.padding_left=10 icon.padding_right=8 \
    label="${VOL}%" label.color="$DIM" label.padding_left=8 label.padding_right=10 \
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
    ICOL="$ACCENT" COLOR="$ACCENT"
  else
    ICOL="$MUTED" COLOR="$LABEL_COLOR"
  fi
  sketchybar --add item "volume.menu.$i" popup.volume \
    --set "volume.menu.$i" \
      icon="$(dev_icon "$dev")" \
      icon.color="$ICOL" icon.padding_left=10 icon.padding_right=8 \
      label="$dev" \
      label.color="$COLOR" label.padding_left=0 \
      label.padding_right=10 \
      background.drawing=off \
      click_script="$PLUGIN_DIR/volume_menu.sh select \"$dev\""
  i=$((i + 1))
done < <("$HOME/.local/bin/omacosy-helper" audio list)

# quiet action row — small + dimmed, weather-footer style
sketchybar --add item "volume.menu.$i" popup.volume \
  --set "volume.menu.$i" icon.drawing=off \
    label="sound settings…" label.color="$DIM" \
    label.font="JetBrainsMono Nerd Font:Regular:12.0" \
    label.padding_left=10 label.padding_right=10 background.drawing=off \
    click_script="open 'x-apple.systempreferences:com.apple.Sound-Settings.extension'; sketchybar --set volume popup.drawing=off"

"$(cd "$(dirname "$0")" && pwd)/popup_guard.sh" close_others volume
sketchybar --set volume popup.drawing=on
# right-align the % readout: after layout, stretch the slider so its
# row spans the widest device row (measuring rendered rects beats
# guessing font metrics)
(
  sleep 0.15
  MAXW=0
  for it in $(sketchybar --query bar | jq -r '.items[]' | grep '^volume\.menu\.'); do
    W="$(sketchybar --query "$it" 2>/dev/null | jq -r \
      '[.bounding_rects // {} | to_entries[] | select(.value.origin[0] > -9000) | .value.size[0]] | max // 0')"
    W="${W%.*}"
    [ "${W:-0}" -gt "$MAXW" ] && MAXW=$W
  done
  # slider row = icon zone (~33) + slider + label zone (~42)
  [ "$MAXW" -gt 100 ] && sketchybar --set volume.slider slider.width=$((MAXW - 75)) 2>/dev/null
) &
("$(cd "$(dirname "$0")" && pwd)/popup_guard.sh" volume >/dev/null 2>&1 &)
