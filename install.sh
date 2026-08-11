#!/usr/bin/env bash
# omacosy bootstrap — clone this repo anywhere, run this once.
# Idempotent: safe to re-run after pulling changes.

set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

# --- 1. Homebrew ------------------------------------------------------------
if ! command -v brew >/dev/null 2>&1; then
  log "Installing Homebrew"
  NONINTERACTIVE=1 /bin/bash -c \
    "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  eval "$(/opt/homebrew/bin/brew shellenv)"
fi

# Homebrew >=6 refuses third-party taps until explicitly trusted
brew trust nikitabobko/tap 2>/dev/null || true
brew trust felixkratz/formulae 2>/dev/null || true

log "Installing packages (brew bundle)"
brew bundle --file="$REPO_DIR/Brewfile"

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

log "Linking configs"
link "$REPO_DIR/zsh/zshrc"           "$HOME/.zshrc"
link "$REPO_DIR/config/starship.toml" "$HOME/.config/starship.toml"
link "$REPO_DIR/config/aerospace"    "$HOME/.config/aerospace"
link "$REPO_DIR/config/sketchybar"   "$HOME/.config/sketchybar"
link "$REPO_DIR/config/borders"      "$HOME/.config/borders"

# Karabiner is COPIED, not symlinked: its background services can't read
# configs living under ~/Documents (TCC folder protection) without Full
# Disk Access. The repo copy is the source of truth on install.
mkdir -p "$HOME/.config/karabiner"
cp "$REPO_DIR/config/karabiner/karabiner.json" "$HOME/.config/karabiner/karabiner.json"
launchctl kickstart -k "gui/$(id -u)/org.pqrs.service.agent.karabiner_console_user_server" 2>/dev/null || true

# theme scripts on PATH (aerospace's theme chord calls ~/.local/bin/theme-next)
mkdir -p "$HOME/.local/bin"

# tiny compiled helper (cursor position, wallpaper) — replaces the
# cliclick and desktoppr dependencies; swiftc ships with the CLT that
# Homebrew already requires
if [ ! -x "$HOME/.local/bin/omacosy-helper" ] || [ "$REPO_DIR/helper/main.swift" -nt "$HOME/.local/bin/omacosy-helper" ]; then
  log "Building omacosy-helper"
  swiftc -O -o "$HOME/.local/bin/omacosy-helper" "$REPO_DIR/helper/main.swift"
fi

# focus-follows-mouse daemon (own binary so helper rebuilds never
# invalidate its Accessibility grant); runs as a launchd agent
if [ ! -x "$HOME/.local/bin/omacosy-ffm" ] || [ "$REPO_DIR/helper/ffm.swift" -nt "$HOME/.local/bin/omacosy-ffm" ]; then
  log "Building omacosy-ffm (grant Accessibility when prompted)"
  swiftc -O -F /System/Library/PrivateFrameworks -framework SkyLight -o "$HOME/.local/bin/omacosy-ffm" "$REPO_DIR/helper/ffm.swift"
fi
# stable code identity so TCC grants survive rebuilds (skipped when no
# signing identity is present — then re-grant after each rebuild)
if security find-identity -p codesigning -v 2>/dev/null | grep -q "Apple Development"; then
  codesign -f -s "Apple Development" --identifier com.omacosy.helper "$HOME/.local/bin/omacosy-helper" 2>/dev/null || true
  codesign -f -s "Apple Development" --identifier com.omacosy.ffm "$HOME/.local/bin/omacosy-ffm" 2>/dev/null || true
fi

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
link "$REPO_DIR/bin/theme-set"  "$HOME/.local/bin/theme-set"
link "$REPO_DIR/bin/theme-next" "$HOME/.local/bin/theme-next"

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
log "Starting sketchybar + borders"
brew services restart sketchybar
brew services restart borders


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
