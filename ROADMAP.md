# Roadmap

Direction, not promises. Ordered roughly by pull.

## Known gaps (honest list)

- **External display brightness (DDC).** The brightness pill controls
  the built-in panel via DisplayServices; external monitors need a
  DDC/I²C stack (what MonitorControl does). Deliberately out of
  scope so far.
- **Re-dwindle for moved windows.** The dwindle daemon tiles windows
  at creation; windows *moved* into a workspace (throws, the
  undock collapse) land as flat siblings. Hyprland re-tiles them
  binarily; we don't yet.
- **Focus guard vs. typing.** An app that yanks focus while you are
  actively typing (input < 2s old) is indistinguishable from a
  user-driven switch and slips through. A denylist for known
  offenders (messengers on non-visible workspaces) is the likely
  escalation.
- **Sub-minimum screen dimming** (QuickShade-style gamma overlay).
- **macOS support matrix.** Built and tested on macOS 26 (Tahoe),
  Apple Silicon, one external display. Sequoia and Intel are
  unknown territory — reports welcome.

## Wants

- **omarchy's scrolling layout** (`Super+L`, per-workspace) — the
  second layout omarchy ships; AeroSpace has no native equivalent,
  so this would be another daemon-grafted behavior.
- **More themes.** `themes/<name>/` is copy-a-directory; omarchy's
  MIT-licensed palettes drop in. The easiest PR in the repo.
- **Upstreaming.** The aerospace-swipe macOS 26 fixes are offered
  upstream (acsandmann/aerospace-swipe #29/#30); an AeroSpace
  window-created hook would delete our SkyLight dependency for the
  bar's window events.
