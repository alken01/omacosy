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

## Native shell (measured experiment, not yet a direction)

`helper/bar.swift` is a deliberate slice, not part of the install: a bar
surface drawn by one Swift process — workspace chips and the front-app
pill — on the built-in display, stacked under sketchybar's own bar so
both can be watched at once. Build and run it by hand:

```
swiftc -O -F /System/Library/PrivateFrameworks -framework SkyLight \
  -o /tmp/omacosy-bar helper/bar.swift && /tmp/omacosy-bar &
```

It exists to price one question: how much of the bar's latency is the
work, and how much is the process boundaries? Measured on this machine,
same event, from signal received to pixels drawn:

| path | mean | max |
|---|---|---|
| sketchybar (`spaces.sh`, excluding its fork and trigger IPC) | 164.79 ms | 191.71 ms |
| native, model held in memory | 2.50 ms | 3.65 ms |

The difference is not language. It is that `spaces.sh` spawns five
`aerospace` CLI calls (~23 ms each) to ask what just happened, while the
native process already holds the window model — fed by the same SkyLight
notifications three daemons are separately subscribed to today. The slow
path (which windows exist, where) costs ~65 ms and runs off the main
queue on window create/destroy only, never on a switch.

Two findings worth keeping even if this goes no further:

- Asking for a font family and **verifying you got it** makes the
  Hiragino class of bug unrepresentable; sketchybar's `--default` failed
  silently for months.
- Running the CLI calls inline on the main queue blocked rendering for
  7.6 s under contention. The architecture only pays if subprocess work
  never sits on the path a frame travels — the same discipline, applied
  one level in.
- **AeroSpace monitor ids are not stable across a hotplug.** Undock and
  the built-in stops being monitor 2 and becomes monitor 1; a cached id
  then answers `Invalid monitor ID`, the snapshot returns empty, and the
  bar keeps rendering the last set it knew — stale, with no error. Found
  within an hour of first running it, by unplugging. The id is now
  re-resolved by display NAME on every screen-parameters change, which is
  the same trap `borders.swift` hit with a stale CG-to-Cocoa flip.

Not decided: whether to grow this into the whole shell (bar, popups,
OSD, overview, borders in one process) or leave sketchybar alone. The
scope that would make sense is those five surfaces — never a lock screen
(`loginwindow` is protected) or a Notification Center replacement.

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
