#!/usr/bin/env bash
# Weather pill via wttr.in's JSON endpoint (no API key; located by IP).
# One fetch per cycle feeds the pill AND the popup rows; clicking
# renders from the cached rows (instant — no network on click, which
# also avoids the popup racing the mouse-leave close). Hides itself
# while offline. Cache line 1 is the pill text; every other line is
# "role|text" — the role picks font + color at popup build time
# (hero = big accent, body = normal, dim = small footer).
export PATH="/opt/homebrew/bin:$PATH"
source "$HOME/.config/omarchy/current/theme/sketchybar.sh"

CACHE="${TMPDIR:-/tmp}/sketchybar-weather"
# LABEL_COLOR with its alpha dropped to ~60% — same hue, quieter.
DIM="0x99${LABEL_COLOR:4}"

close_popup() {
  sketchybar --set weather popup.drawing=off 2>/dev/null
  sketchybar --remove '/weather\.pop\..*/' >/dev/null 2>&1
}

case "$SENDER" in
  mouse.clicked)
    if [ "$(sketchybar --query weather | jq -r '.popup.drawing' 2>/dev/null)" = "on" ]; then
      close_popup
      exit 0
    fi
    close_popup
    [ -s "$CACHE" ] || exit 0
    i=0
    while IFS='|' read -r role text; do
      [ "$i" -eq 0 ] && { i=1; continue; }  # line 1 is the pill text
      FONT="JetBrainsMono Nerd Font:SemiBold:13.0"
      COLOR="$LABEL_COLOR"
      case "$role" in
        hero) FONT="JetBrainsMono Nerd Font:Bold:16.0" COLOR="$ACCENT" ;;
        dim) FONT="JetBrainsMono Nerd Font:Regular:12.0" COLOR="$DIM" ;;
      esac
      sketchybar --add item "weather.pop.$i" popup.weather \
        --set "weather.pop.$i" \
          icon.drawing=off \
          label="$text" \
          label.font="$FONT" \
          label.color="$COLOR" \
          label.padding_left=10 \
          label.padding_right=10 \
          background.drawing=off
      i=$((i + 1))
    done < "$CACHE"
    "$(cd "$(dirname "$0")" && pwd)/popup_guard.sh" close_others weather
    sketchybar --set weather popup.drawing=on
("$(cd "$(dirname "$0")" && pwd)/popup_guard.sh" weather >/dev/null 2>&1 &)
    exit 0
    ;;
esac

# --- routine render: one JSON fetch covers the pill and every row ----------
J="$(curl -sf --max-time 8 'wttr.in/?format=j1')"
if [ -z "$J" ]; then
  # offline: hide the pill, keep the last cache for when we're back
  sketchybar --set "$NAME" drawing=off
  exit 0
fi

IFS=$'\t' read -r TEMP FEELS DESC CODE WDEG WKMH HUM PRECIP AREA REGION COUNTRY \
  MAXT MINT SUNRISE SUNSET MOON RAINPCT <<EOF
$(jq -r '[
  .current_condition[0].temp_C,
  .current_condition[0].FeelsLikeC,
  (.current_condition[0].weatherDesc[0].value // ""),
  .current_condition[0].weatherCode,
  .current_condition[0].winddirDegree,
  .current_condition[0].windspeedKmph,
  .current_condition[0].humidity,
  .current_condition[0].precipMM,
  (.nearest_area[0].areaName[0].value // ""),
  (.nearest_area[0].region[0].value // ""),
  (.nearest_area[0].country[0].value // ""),
  .weather[0].maxtempC,
  .weather[0].mintempC,
  .weather[0].astronomy[0].sunrise,
  .weather[0].astronomy[0].sunset,
  (.weather[0].astronomy[0].moon_phase // ""),
  ([.weather[0].hourly[].chanceofrain | tonumber] | max)
] | @tsv' <<<"$J" 2>/dev/null)
EOF

# a garbled payload must not paint garbage — treat it like offline
case "$TEMP" in '' | *[!0-9-]*)
  sketchybar --set "$NAME" drawing=off
  exit 0
  ;;
esac

# WWO weather code → condition emoji (clear picks sun/moon by time)
to24() { date -j -f "%I:%M %p" "$1" +%H:%M 2>/dev/null || printf '%s' "$1"; }
SR="$(to24 "$SUNRISE")" SS="$(to24 "$SUNSET")"
NOWHM="$(date +%H:%M)"
DAY=0
[[ $NOWHM > $SR && $NOWHM < $SS ]] && DAY=1
case "$CODE" in
  113) [ "$DAY" = 1 ] && EMOJI="☀️" || EMOJI="🌙" ;;
  116) EMOJI="⛅" ;;
  119 | 122) EMOJI="☁️" ;;
  143 | 248 | 260) EMOJI="🌫" ;;
  176 | 263 | 266 | 281 | 284 | 293 | 296 | 353) EMOJI="🌦" ;;
  299 | 302 | 305 | 308 | 311 | 314 | 356 | 359) EMOJI="🌧" ;;
  317 | 320 | 350 | 362 | 365 | 374 | 377) EMOJI="🌨" ;;
  179 | 182 | 185 | 227 | 230 | 323 | 326 | 329 | 332 | 335 | 338 | 368 | 371 | 395) EMOJI="❄️" ;;
  200 | 386 | 389 | 392) EMOJI="⛈" ;;
  *) EMOJI="🌡" ;;
esac

# wind arrow points where the wind BLOWS TO (wttr's own convention)
ARROWS=(↑ ↗ → ↘ ↓ ↙ ← ↖)
TOWARD=$(((WDEG + 180) % 360))
ARROW="${ARROWS[$((((TOWARD + 22) / 45) % 8))]}"

# moon phase name → the matching glyph
case "$MOON" in
  "New Moon") ME="🌑" ;;
  "Waxing Crescent") ME="🌒" ;;
  "First Quarter") ME="🌓" ;;
  "Waxing Gibbous") ME="🌔" ;;
  "Full Moon") ME="🌕" ;;
  "Waning Gibbous") ME="🌖" ;;
  "Last Quarter" | "Third Quarter") ME="🌗" ;;
  "Waning Crescent") ME="🌘" ;;
  *) ME="🌙" ;;
esac
MOON_LC="$(printf '%s' "$MOON" | tr '[:upper:]' '[:lower:]')"
DESC_LC="$(printf '%s' "$DESC" | tr '[:upper:]' '[:lower:]')"

# location: wttr repeats the city as its region ("Porto, Porto" — or
# "Oporto, Porto" via the English exonym), so drop the region whenever
# one name contains the other, case-insensitively
LOC="$AREA"
A_LC="$(printf '%s' "$AREA" | tr '[:upper:]' '[:lower:]')"
R_LC="$(printf '%s' "$REGION" | tr '[:upper:]' '[:lower:]')"
if [ -n "$REGION" ] && [[ $A_LC != *"$R_LC"* && $R_LC != *"$A_LC"* ]]; then
  LOC="$LOC, $REGION"
fi
[ -n "$COUNTRY" ] && LOC="$LOC, $COUNTRY"

# feels-like earns a mention only when it differs from the real temp
TODAY="today ${MINT}° → ${MAXT}°C"
[ "$FEELS" != "$TEMP" ] && TODAY="feels ${FEELS}°C · $TODAY"

# rain row only when there is actual signal (falling now, or likely today)
RAIN=""
FALLING=$(awk -v p="$PRECIP" 'BEGIN{print (p > 0) ? 1 : 0}')
if [ "$FALLING" = 1 ]; then
  RAIN="☔ ${PRECIP}mm now"
  [ "${RAINPCT:-0}" -ge 30 ] && RAIN="$RAIN · rain ${RAINPCT}% today"
elif [ "${RAINPCT:-0}" -ge 30 ]; then
  RAIN="☔ rain ${RAINPCT}% today"
fi

# atomic: a click can read the cache mid-write; tmp+mv means it sees
# either the old rows or the new, never a truncated file
{
  printf '%s\n' "$EMOJI ${TEMP}°C"
  printf 'hero|%s\n' "$EMOJI ${TEMP}°C $DESC_LC"
  printf 'body|%s\n' "$TODAY"
  printf 'body|%s\n' "wind $ARROW ${WKMH} km/h · humidity ${HUM}%"
  [ -n "$RAIN" ] && printf 'body|%s\n' "$RAIN"
  printf 'body|%s\n' "sun $SR → $SS · $ME $MOON_LC"
  printf 'dim|%s\n' "$LOC"
} >"$CACHE.tmp" && mv "$CACHE.tmp" "$CACHE"
sketchybar --set "$NAME" drawing=on icon.drawing=off label="$(head -1 "$CACHE")"
