#!/usr/bin/env bash
# omacosy bootstrap — clone this repo anywhere, run this once.
# Idempotent: safe to re-run after pulling changes.

set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

# --- 0. Manifest: record what THIS machine gains ----------------------------
# uninstall.sh removes only what is recorded here, so tools and settings
# the user had before omacosy are never touched. First run wins for
# recorded prior values; re-runs never duplicate entries.
STATE_DIR="$HOME/.local/state/omacosy"
MANIFEST="$STATE_DIR/manifest"
mkdir -p "$STATE_DIR"
touch "$MANIFEST"
mark() { grep -qxF "$1" "$MANIFEST" || printf '%s\n' "$1" >> "$MANIFEST"; }
export MANIFEST

# --- 1. Homebrew ------------------------------------------------------------
if ! command -v brew >/dev/null 2>&1; then
  log "Installing Homebrew"
  mark "installed-homebrew"
  NONINTERACTIVE=1 /bin/bash -c \
    "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  eval "$(/opt/homebrew/bin/brew shellenv)"
fi

# Homebrew >=6 refuses third-party taps until explicitly trusted
brew trust nikitabobko/tap 2>/dev/null || true
brew trust felixkratz/formulae 2>/dev/null || true

log "Installing packages (brew bundle)"
PRE_FORMULAE="$(brew list --formula 2>/dev/null | sort)"
PRE_CASKS="$(brew list --cask 2>/dev/null | sort)"
brew bundle --file="$REPO_DIR/Brewfile"
# record only packages that brew bundle ACTUALLY added
comm -13 <(printf '%s\n' "$PRE_FORMULAE") <(brew list --formula 2>/dev/null | sort) \
  | while read -r f; do [ -n "$f" ] && mark "brew-formula $f"; done
comm -13 <(printf '%s\n' "$PRE_CASKS") <(brew list --cask 2>/dev/null | sort) \
  | while read -r c; do [ -n "$c" ] && mark "brew-cask $c"; done

# --- 2. Symlinks ------------------------------------------------------------
# Existing non-symlink targets are backed up, never deleted.
link() {
  local src=$1 dst=$2
  mkdir -p "$(dirname "$dst")"
  if [ -e "$dst" ] && [ ! -L "$dst" ]; then
    local bak="$dst.bak.$(date +%Y%m%d%H%M%S)"
    log "Backing up $dst -> $bak"
    mv "$dst" "$bak"
  fi
  ln -sfn "$src" "$dst"
}

# generate aerospace.toml from the template + app choices
source "$REPO_DIR/config/apps.conf"
[ -f "$REPO_DIR/config/apps.local.conf" ] && source "$REPO_DIR/config/apps.local.conf"
sed -e "s|@TERMINAL@|$TERMINAL|g" -e "s|@BROWSER@|$BROWSER|g" \
    -e "s|@MUSIC@|$MUSIC|g" -e "s|@MESSENGER@|$MESSENGER|g" \
  "$REPO_DIR/config/aerospace/aerospace.template.toml" > "$REPO_DIR/config/aerospace/aerospace.toml"

log "Linking configs"
link "$REPO_DIR/zsh/zshrc"           "$HOME/.zshrc"
link "$REPO_DIR/config/starship.toml" "$HOME/.config/starship.toml"
link "$REPO_DIR/config/aerospace"    "$HOME/.config/aerospace"
link "$REPO_DIR/config/sketchybar"   "$HOME/.config/sketchybar"

# Karabiner is COPIED, not symlinked: its background services can't read
# configs living under ~/Documents (TCC folder protection) without Full
# Disk Access. The repo copy is the source of truth on install.
mkdir -p "$HOME/.config/karabiner"
# preserve a pre-omacosy karabiner config once, for uninstall to restore
if [ -f "$HOME/.config/karabiner/karabiner.json" ] \
  && [ ! -f "$HOME/.config/karabiner/karabiner.json.bak.omacosy" ] \
  && ! cmp -s "$REPO_DIR/config/karabiner/karabiner.json" "$HOME/.config/karabiner/karabiner.json"; then
  cp "$HOME/.config/karabiner/karabiner.json" "$HOME/.config/karabiner/karabiner.json.bak.omacosy"
  mark "had-karabiner-config"
fi
cp "$REPO_DIR/config/karabiner/karabiner.json" "$HOME/.config/karabiner/karabiner.json"
launchctl kickstart -k "gui/$(id -u)/org.pqrs.service.agent.karabiner_console_user_server" 2>/dev/null || true
# Karabiner's Menu and NotificationWindow helper apps idle at ~135MB
# combined and serve a menu-bar icon we hide; remapping lives in the
# core service, which stays
for agent in Karabiner-Menu Karabiner-NotificationWindow; do
  launchctl bootout "gui/$(id -u)/org.pqrs.service.agent.$agent" 2>/dev/null || true
  launchctl disable "gui/$(id -u)/org.pqrs.service.agent.$agent" 2>/dev/null || true
done
pkill -f "Karabiner-Menu|Karabiner-NotificationWindow" 2>/dev/null || true

# theme scripts on PATH (aerospace's theme chord calls ~/.local/bin/theme-next)
mkdir -p "$HOME/.local/bin"

# tiny compiled helper (cursor position, wallpaper) — replaces the
# cliclick and desktoppr dependencies; swiftc ships with the CLT that
# Homebrew already requires
if [ ! -x "$HOME/.local/bin/omacosy-helper" ] || [ "$REPO_DIR/helper/main.swift" -nt "$HOME/.local/bin/omacosy-helper" ]; then
  log "Building omacosy-helper"
  swiftc -O -o "$HOME/.local/bin/omacosy-helper" "$REPO_DIR/helper/main.swift"
fi

# workspace overview overlay (4-finger swipe up)
if [ ! -x "$HOME/.local/bin/omacosy-overview" ] || [ "$REPO_DIR/helper/overview.swift" -nt "$HOME/.local/bin/omacosy-overview" ]; then
  log "Building omacosy-overview"
  swiftc -O -F /System/Library/PrivateFrameworks -framework SkyLight -o "$HOME/.local/bin/omacosy-overview" "$REPO_DIR/helper/overview.swift"
fi

# dwindle layout daemon (Hyprland-style spiral splits on AeroSpace)
if [ ! -x "$HOME/.local/bin/omacosy-dwindle" ] || [ "$REPO_DIR/helper/dwindle.swift" -nt "$HOME/.local/bin/omacosy-dwindle" ]; then
  log "Building omacosy-dwindle"
  swiftc -O -F /System/Library/PrivateFrameworks -framework SkyLight -o "$HOME/.local/bin/omacosy-dwindle" "$REPO_DIR/helper/dwindle.swift"
fi

# focus-follows-mouse daemon (own binary so helper rebuilds never
# invalidate its Accessibility grant); runs as a launchd agent
if [ ! -x "$HOME/.local/bin/omacosy-ffm" ] || [ "$REPO_DIR/helper/ffm.swift" -nt "$HOME/.local/bin/omacosy-ffm" ]; then
  log "Building omacosy-ffm (grant Accessibility when prompted)"
  swiftc -O -F /System/Library/PrivateFrameworks -framework SkyLight -o "$HOME/.local/bin/omacosy-ffm" "$REPO_DIR/helper/ffm.swift"
fi

# focused-window border ring (replaces JankyBorders; no permissions;
# SkyLight for the window-server event notifications)
if [ ! -x "$HOME/.local/bin/omacosy-borders" ] || [ "$REPO_DIR/helper/borders.swift" -nt "$HOME/.local/bin/omacosy-borders" ]; then
  log "Building omacosy-borders"
  swiftc -O -F /System/Library/PrivateFrameworks -framework SkyLight -o "$HOME/.local/bin/omacosy-borders" "$REPO_DIR/helper/borders.swift"
fi
# stable code identity so TCC grants survive rebuilds (skipped when no
# signing identity is present — then re-grant after each rebuild)
if security find-identity -p codesigning -v 2>/dev/null | grep -q "Apple Development"; then
  codesign -f -s "Apple Development" --identifier com.omacosy.helper "$HOME/.local/bin/omacosy-helper" 2>/dev/null || true
  codesign -f -s "Apple Development" --identifier com.omacosy.ffm "$HOME/.local/bin/omacosy-ffm" 2>/dev/null || true
  codesign -f -s "Apple Development" --identifier com.omacosy.borders "$HOME/.local/bin/omacosy-borders" 2>/dev/null || true
  # aerospace-swipe too — unsigned, every rebuild invalidated its
  # Accessibility grant and silently killed all trackpad swipes
  codesign -f -s "Apple Development" --identifier com.omacosy.dwindle "$HOME/.local/bin/omacosy-dwindle" 2>/dev/null || true
  codesign -f -s "Apple Development" --identifier com.omacosy.overview "$HOME/.local/bin/omacosy-overview" 2>/dev/null || true
  codesign -f -s "Apple Development" --identifier com.acsandmann.swipe "$HOME/.local/share/aerospace-swipe/AerospaceSwipe.app" 2>/dev/null || true
fi

# hover-ignore list (launchd agents can't read ~/Documents — copied)
mkdir -p "$HOME/.config/omacosy"
cp "$REPO_DIR/config/ffm-ignore" "$HOME/.config/omacosy/ffm-ignore"
cp "$REPO_DIR/config/borders.conf" "$HOME/.config/omacosy/borders.conf"

cat > "$HOME/Library/LaunchAgents/com.omacosy.borders.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.omacosy.borders</string>
  <key>ProgramArguments</key><array><string>$HOME/.local/bin/omacosy-borders</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
</dict>
</plist>
PLIST
launchctl unload "$HOME/Library/LaunchAgents/com.omacosy.borders.plist" 2>/dev/null || true
launchctl load "$HOME/Library/LaunchAgents/com.omacosy.borders.plist"

cat > "$HOME/Library/LaunchAgents/com.omacosy.ffm.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.omacosy.ffm</string>
  <key>ProgramArguments</key><array><string>$HOME/.local/bin/omacosy-ffm</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardErrorPath</key><string>/tmp/omacosy-ffm.err</string>
</dict>
</plist>
PLIST
launchctl unload "$HOME/Library/LaunchAgents/com.omacosy.ffm.plist" 2>/dev/null || true
launchctl load "$HOME/Library/LaunchAgents/com.omacosy.ffm.plist"

cat > "$HOME/Library/LaunchAgents/com.omacosy.dwindle.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.omacosy.dwindle</string>
  <key>ProgramArguments</key><array><string>$HOME/.local/bin/omacosy-dwindle</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardErrorPath</key><string>/tmp/omacosy-dwindle.err</string>
</dict>
</plist>
PLIST
launchctl unload "$HOME/Library/LaunchAgents/com.omacosy.dwindle.plist" 2>/dev/null || true
launchctl load "$HOME/Library/LaunchAgents/com.omacosy.dwindle.plist"
link "$REPO_DIR/bin/theme-set"  "$HOME/.local/bin/theme-set"
link "$REPO_DIR/bin/theme-next" "$HOME/.local/bin/theme-next"
link "$REPO_DIR/bin/omacosy-toggle" "$HOME/.local/bin/omacosy-toggle"

# --- 3. omarchy theme convention -------------------------------------------
# Canonical theme state lives at ~/.config/omarchy/current/theme (what the
# shell tools read). Korren resolves the same dir via macOS config_dir
# (~/Library/Application Support), so bridge it with a symlink.
mkdir -p "$HOME/.config/omarchy/current"
link "$HOME/.config/omarchy" "$HOME/Library/Application Support/omarchy"

if [ ! -e "$HOME/.config/omarchy/current/theme" ]; then
  log "Applying default theme (tokyo-night)"
  "$REPO_DIR/bin/theme-set" tokyo-night
fi

# --- 4. Point Korren at the omarchy theme -----------------------------------
KORREN_CFG="$HOME/Library/Application Support/korren/config.toml"
if [ -f "$KORREN_CFG" ]; then
  if ! grep -q '^name = "omarchy"' "$KORREN_CFG"; then
    # `name =` only occurs under [theme]; Korren live-reloads this file.
    sed -i '' 's/^name = ".*"/name = "omarchy"/' "$KORREN_CFG"
    log "Korren theme set to follow omarchy"
  fi
else
  mkdir -p "$(dirname "$KORREN_CFG")"
  printf '[theme]\nname = "omarchy"\n' > "$KORREN_CFG"
  log "Created Korren config (theme follows omarchy)"
fi

# --- 5. Trackpad workspace swipes (aerospace-swipe) -------------------------
# Built from source; installs a user launch agent. Config is COPIED (same
# TCC constraint as Karabiner: launch agents can't read ~/Documents).
if [ ! -d "$HOME/.local/share/aerospace-swipe" ]; then
  git clone -q https://github.com/acsandmann/aerospace-swipe.git "$HOME/.local/share/aerospace-swipe"
  mark "cloned-aerospace-swipe"
fi
# macOS 26 fix: read raw MultitouchSupport frames on all devices —
# event taps no longer carry multi-touch data on 26.3
if git -C "$HOME/.local/share/aerospace-swipe" apply --check "$REPO_DIR/patches/aerospace-swipe-macos26-raw-multitouch.patch" 2>/dev/null; then
  git -C "$HOME/.local/share/aerospace-swipe" apply "$REPO_DIR/patches/aerospace-swipe-macos26-raw-multitouch.patch"
fi
mkdir -p "$HOME/.config/aerospace-swipe"
cp "$REPO_DIR/config/aerospace-swipe/config.json" "$HOME/.config/aerospace-swipe/config.json"
log "Building aerospace-swipe (grant Accessibility when prompted)"
(cd "$HOME/.local/share/aerospace-swipe" && make install) || \
  echo "aerospace-swipe install failed — run manually: cd ~/.local/share/aerospace-swipe && make install"

# --- 6. macOS look ----------------------------------------------------------
"$REPO_DIR/macos-defaults.sh"

# --- 7. Services ------------------------------------------------------------
log "Starting sketchybar"
brew services restart sketchybar


log "Starting AeroSpace"
open -a AeroSpace

log "Starting Karabiner-Elements (Caps Lock -> Super)"
open -a Karabiner-Elements

cat <<'EOF'

Done. One-time macOS steps if this is a fresh machine:
  1. Grant AeroSpace   System Settings -> Privacy & Security -> Accessibility
  2. Karabiner-Elements: approve its driver extension + Input Monitoring
     when prompted (System Settings -> Privacy & Security)
  3. Korren isn't in the Brewfile — build it from the korren repo:
       ./packaging/macos/build-app.sh --install

Super = hold Caps Lock. Switch themes:  theme-set <name>  or  Super+Shift+T
Back to a normal Mac any time:  ./uninstall.sh
EOF
