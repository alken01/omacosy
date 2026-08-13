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

# The 4-finger swipes belong to aerospace-swipe (workspaces + the
# omacosy overview). Left enabled, the SYSTEM also fires Mission
# Control / Spaces on the same gesture — MC opens on top of the
# overview and eats every click and keystroke (and SCK captures catch
# windows mid-MC-zoom). Trackpad -> More Gestures equivalents: off.
defaults write com.apple.AppleMultitouchTrackpad TrackpadFourFingerVertSwipeGesture -int 0
defaults write com.apple.AppleMultitouchTrackpad TrackpadFourFingerHorizSwipeGesture -int 0
defaults write com.apple.driver.AppleBluetoothMultitouch.trackpad TrackpadFourFingerVertSwipeGesture -int 0 2>/dev/null || true
defaults write com.apple.driver.AppleBluetoothMultitouch.trackpad TrackpadFourFingerHorizSwipeGesture -int 0 2>/dev/null || true
defaults write com.apple.dock showMissionControlGestureEnabled -bool false
echo "macos-defaults: 4-finger swipes released to aerospace-swipe (Dock restart applies)"
