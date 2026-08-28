# Alken's lean OmaCosy profile

This fork keeps OmaCosy's useful core and makes the cosmetic/background
components optional. Edit `config/features.conf`, then run `./install.sh`.

## What is enabled

- **AeroSpace:** automatic tiling, keyboard focus/move/resize, floating and
  fullscreen modes, and nine workspaces per display.
- **Native AeroSpace layout:** new windows become left/right columns on the
  landscape displays; the upstream top/bottom dwindle hook is disabled.
- **Caps Lock Super:** Karabiner maps held Caps Lock to Command+Control+Option
  and tapped Caps Lock to Escape.
- **App shortcuts:** terminal, browser, Raycast, Finder, music, and messenger.
- **Themes:** Ghostty/wallpaper theme switching remains available.

## What is disabled

- **Custom status bar:** restores the native macOS menu bar and removes the
  always-running bar process.
- **Window borders:** removes the border process and its animation artifacts.
- **Focus follows mouse:** keyboard/click focus only.
- **Custom trackpad gestures and overview:** native macOS gestures are restored.

Disabled helpers remain in the source tree so they can be re-enabled with one
feature flag. The border configuration is also retained at a thinner 2 px for
future testing.

## Main shortcuts

`Super` means hold Caps Lock.

| Shortcut | Action |
| --- | --- |
| Super + Enter | Open Ghostty |
| Super + Shift + Enter | Open Zen Browser |
| Super + Space | Open Raycast |
| Super + Arrow | Focus a window |
| Super + Shift + Arrow | Move a window |
| Super + 1…9 | Switch workspace |
| Super + Shift + 1…9 | Move window to workspace |
| Super + Tab / Super + Shift + Tab | Next / previous workspace |
| Option + Tab / Option + Shift + Tab | Next / previous window |
| Super + W | Close window |
| Super + T | Toggle floating/tiling |
| Super + F | Fullscreen |
| Super + J | Toggle split direction |
| Super + - / = | Resize |
| Super + Shift + F | Finder |
| Super + Shift + M | Music |
| Super + Shift + G | Messenger |
| Super + Shift + T | Next theme |

## Component map

| Component | Role | Profile choice |
| --- | --- | --- |
| AeroSpace | Tiling and spaces | Keep |
| `omacosy-helper` | Lock and wallpaper utilities | Keep |
| `omacosy-ws` | Monitor-aware workspaces | Keep |
| Karabiner | Caps Lock Super | Keep for now |
| OmaCosy bar | Status, workspace labels, system widgets | Disable |
| Borders | Focus ring | Disable |
| FFM | Focus follows pointer | Disable |
| Gesture daemon | Trackpad workspace switching | Disable |
| Overview | Custom workspace overview | Disable |
| OmniWM | Experimental alternate window manager | Do not use |
