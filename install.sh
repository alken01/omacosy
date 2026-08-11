#!/usr/bin/env bash
# omarchy-mac bootstrap — clone this repo anywhere, run this once.
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

# --- 5. Services ------------------------------------------------------------
log "Starting sketchybar + borders"
brew services restart sketchybar
brew services restart borders

log "Starting AeroSpace"
open -a AeroSpace

cat <<'EOF'

Done. Two one-time macOS steps if this is a fresh machine:
  1. Grant AeroSpace  System Settings -> Privacy & Security -> Accessibility
  2. Korren isn't in the Brewfile — build it from the korren repo:
       ./packaging/macos/build-app.sh --install

Switch themes any time:  theme-set <tokyo-night|catppuccin|gruvbox>
EOF
