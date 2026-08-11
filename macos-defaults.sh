#!/usr/bin/env bash
# System-level tweaks for the omarchy look. uninstall.sh reverses these.

set -euo pipefail

# One bar, not two: auto-hide the native menu bar (sketchybar takes the top).
# cfprefsd must be killed so the OS re-reads the pref without a logout.
defaults write NSGlobalDomain _HIHideMenuBar -bool true
killall cfprefsd 2>/dev/null || true
sleep 1
killall SystemUIServer 2>/dev/null || true

echo "macos-defaults: menu bar set to auto-hide (log out/in if it doesn't apply immediately)"
