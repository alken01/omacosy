#!/usr/bin/env bash
# Back to a normal Mac. Best-effort teardown: stops the tiling stack,
# restores the native menu bar, unlinks configs (restoring backups
# where install.sh made them). Homebrew packages are left installed.

set -uo pipefail

log() { printf '\033[1;33m==>\033[0m %s\n' "$*"; }

# --- 1. Stop the stack ------------------------------------------------------
# Quitting AeroSpace restores windows it was managing.
log "Stopping AeroSpace, sketchybar, borders"
osascript -e 'quit app "AeroSpace"' 2>/dev/null || true
osascript -e 'quit app "Karabiner-Elements"' 2>/dev/null || true
brew services stop sketchybar 2>/dev/null || true
brew services stop borders 2>/dev/null || true
launchctl unload "$HOME/Library/LaunchAgents/com.omacosy.ffm.plist" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/com.omacosy.ffm.plist" "$HOME/.local/bin/omacosy-ffm"

# aerospace-swipe: unload its launch agent and remove config
if [ -d "$HOME/.local/share/aerospace-swipe" ]; then
  (cd "$HOME/.local/share/aerospace-swipe" && make uninstall) 2>/dev/null || true
fi
rm -rf "$HOME/.config/aerospace-swipe"

# --- 2. Native menu bar back ------------------------------------------------
defaults delete NSGlobalDomain _HIHideMenuBar 2>/dev/null || true
killall SystemUIServer 2>/dev/null || true

# --- 3. Unlink configs, restore backups -------------------------------------
restore() {
  local dst=$1
  [ -L "$dst" ] && rm "$dst"
  local bak
  bak="$(ls -d "$dst".bak.* 2>/dev/null | sort | tail -1 || true)"
  if [ -n "$bak" ]; then
    log "Restoring $bak -> $dst"
    mv "$bak" "$dst"
  fi
}

restore "$HOME/.zshrc"
restore "$HOME/.config/starship.toml"
restore "$HOME/.config/aerospace"
restore "$HOME/.config/sketchybar"
restore "$HOME/.config/borders"

# Karabiner's config is a copied real file (its daemons can't read
# ~/Documents), so remove our copy rather than a symlink.
rm -f "$HOME/.config/karabiner/karabiner.json"
rmdir "$HOME/.config/karabiner" 2>/dev/null || true

# Pre-omacosy, ~/.zshrc pointed at the old dotbot repo — relink if
# nothing else restored it and that repo is still around.
if [ ! -e "$HOME/.zshrc" ] && [ -f "$HOME/Documents/config/.dotfiles/zshrc" ]; then
  log "Relinking ~/.zshrc to the legacy dotfiles repo"
  ln -s "$HOME/Documents/config/.dotfiles/zshrc" "$HOME/.zshrc"
fi

# theme-set / theme-next out of ~/.local/bin
rm -f "$HOME/.local/bin/theme-set" "$HOME/.local/bin/theme-next" "$HOME/.local/bin/omacosy-helper"

# omarchy theme convention dirs
[ -L "$HOME/Library/Application Support/omarchy" ] && rm "$HOME/Library/Application Support/omarchy"
rm -f "$HOME/.config/omarchy/current/theme"
rmdir "$HOME/.config/omarchy/current" "$HOME/.config/omarchy" 2>/dev/null || true

# --- 4. Korren back to its built-in default theme ---------------------------
KORREN_CFG="$HOME/Library/Application Support/korren/config.toml"
if [ -f "$KORREN_CFG" ]; then
  sed -i '' 's/^name = "omarchy"/name = "default"/' "$KORREN_CFG"
fi

cat <<'EOF'

Done. Left in place on purpose:
  - Homebrew packages (remove with: brew uninstall sketchybar borders && brew uninstall --cask aerospace karabiner-elements)
  - Karabiner's Caps Lock remap stops once the app is quit/uninstalled.
  - The menu bar returns fully after logging out and back in.
  - Claude desktop's caps-lock dictation shortcut was removed during setup;
    re-enable it in Claude's settings if you used it.
  - If AeroSpace still appears in System Settings -> General -> Login Items, remove it there.
  - The repo itself and your shell tools (fzf, eza, zoxide, ...) are untouched.
EOF
