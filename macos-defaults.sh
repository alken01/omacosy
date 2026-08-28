#!/usr/bin/env bash
# System-level tweaks for the omarchy look. uninstall.sh reverses these.

set -euo pipefail

# Record each key's PRE-omacosy value (type + value, ABSENT if unset)
# into the install manifest, once — uninstall.sh restores exactly that
# instead of guessing Apple's defaults.
MANIFEST="${MANIFEST:-$HOME/.local/state/omacosy/manifest}"
mkdir -p "$(dirname "$MANIFEST")"
touch "$MANIFEST"
record_default() { # domain key
  grep -q "^default $1 $2 " "$MANIFEST" && return 0
  local t v
  if v="$(defaults read "$1" "$2" 2>/dev/null)"; then
    t="$(defaults read-type "$1" "$2" 2>/dev/null | awk '{print $3}')"
    printf 'default %s %s %s %s\n' "$1" "$2" "${t:-string}" "$v" >> "$MANIFEST"
  else
    printf 'default %s %s ABSENT ABSENT\n' "$1" "$2" >> "$MANIFEST"
  fi
}
record_default NSGlobalDomain _HIHideMenuBar
record_default NSGlobalDomain AppleMenuBarVisibleInFullscreen
record_default com.apple.AppleMultitouchTrackpad TrackpadFourFingerVertSwipeGesture
record_default com.apple.AppleMultitouchTrackpad TrackpadFourFingerHorizSwipeGesture
record_default com.apple.driver.AppleBluetoothMultitouch.trackpad TrackpadFourFingerVertSwipeGesture
record_default com.apple.driver.AppleBluetoothMultitouch.trackpad TrackpadFourFingerHorizSwipeGesture
record_default com.apple.dock showMissionControlGestureEnabled

# Hide the native menu bar only when the OmaCosy bar replaces it. The lean
# profile keeps macOS's own bar and avoids running another status process.
if [ "${OMACOSY_STATUS_BAR:-1}" = 1 ]; then
  defaults write NSGlobalDomain _HIHideMenuBar -bool true
  defaults write NSGlobalDomain AppleMenuBarVisibleInFullscreen -bool false
  menu_bar_message="menu bar set to auto-hide"
else
  defaults write NSGlobalDomain _HIHideMenuBar -bool false
  defaults write NSGlobalDomain AppleMenuBarVisibleInFullscreen -bool true
  menu_bar_message="native menu bar restored"
fi
killall cfprefsd 2>/dev/null || true
sleep 1
killall SystemUIServer 2>/dev/null || true

echo "macos-defaults: $menu_bar_message (log out/in if it doesn't apply immediately)"

# The 4-finger swipes belong to omacosy-gesture (workspaces + the
# omacosy overview). Left enabled, the SYSTEM also fires Mission
# Control / Spaces on the same gesture — MC opens on top of the
# overview and eats every click and keystroke (and SCK captures catch
# windows mid-MC-zoom). Trackpad -> More Gestures equivalents: off.
if [ "${OMACOSY_GESTURES:-1}" = 1 ]; then
  defaults write com.apple.AppleMultitouchTrackpad TrackpadFourFingerVertSwipeGesture -int 0
  defaults write com.apple.AppleMultitouchTrackpad TrackpadFourFingerHorizSwipeGesture -int 0
  defaults write com.apple.driver.AppleBluetoothMultitouch.trackpad TrackpadFourFingerVertSwipeGesture -int 0 2>/dev/null || true
  defaults write com.apple.driver.AppleBluetoothMultitouch.trackpad TrackpadFourFingerHorizSwipeGesture -int 0 2>/dev/null || true
  defaults write com.apple.dock showMissionControlGestureEnabled -bool false
  echo "macos-defaults: 4-finger swipes released to omacosy-gesture (Dock restart applies)"
else
  defaults write com.apple.AppleMultitouchTrackpad TrackpadFourFingerVertSwipeGesture -int 2
  defaults write com.apple.AppleMultitouchTrackpad TrackpadFourFingerHorizSwipeGesture -int 2
  defaults write com.apple.driver.AppleBluetoothMultitouch.trackpad TrackpadFourFingerVertSwipeGesture -int 2 2>/dev/null || true
  defaults write com.apple.driver.AppleBluetoothMultitouch.trackpad TrackpadFourFingerHorizSwipeGesture -int 2 2>/dev/null || true
  defaults delete com.apple.dock showMissionControlGestureEnabled 2>/dev/null || true
  killall Dock 2>/dev/null || true
  echo "macos-defaults: native four-finger gestures restored"
fi
