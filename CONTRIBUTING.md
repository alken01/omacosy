# Contributing to omacosy

Small repo, strong opinions. PRs are welcome when they keep these.

## The doctrines

- **Events over polling — always ask "who publishes this?" first.**
  Window changes come from SkyLight notifications, network state from
  SCDynamicStore, bluetooth from IOBluetooth notifications, power from
  IOPS, app lifecycle from NSWorkspace. A timer is acceptable only as
  a guarded safety net that never acts as the primary path, or where
  no publisher exists at all (the weather fetch, the clock).
- **The bar derives, it does not enumerate.** Pill spacing sweeps
  "every right-positioned item"; popup cleanup works off the naming
  convention below. If your change needs a hardcoded name list, find
  the derived form instead — every list here has rotted.
- **Repaint the bar, don't rebuild it.** A theme switch changes ten
  colour values and nothing structural, so `theme-set` re-sets them on
  the live items in one message (`omacosy-bar-repaint`) instead of
  reloading. `sketchybar --reload` is for structural change only —
  display add/remove — because it re-runs the whole config in front of
  the user and opens the window below.
- **`--default` is a convenience, never a guarantee.** It is global
  daemon state: a reload arriving mid-pass resets it, and every item
  added after that point is born with sketchybar's built-ins — Hack
  Nerd Font (not installed, so text lands in a system fallback face),
  white, auto-height pills. The closing sweep in `sketchybarrc` stamps
  the real font, colour and pill height back over anything still
  wearing a value the theme never issued; extend the sweep, not a list.
- **Popup naming convention (load-bearing):** an anchor's popup
  children are ALL named `<anchor>.<something>` (`clock.cal.3`,
  `volume.slider`, `bluetooth.pop.1`), and nothing outside its popup
  may use that prefix. `popup_guard.sh` cleans up by this rule. A new
  popup anchor needs exactly one registration: the `ANCHORS` list in
  `popup_guard.sh`.
- **Popup design language:** accent hero row, plain body rows, dimmed
  12pt action footer. Click paths never touch the network — fetch to
  a cache, render from it (see `weather.sh`).
- **Hide, don't lie.** A pill whose data source fails hides itself
  rather than rendering garbage.
- **Shell is /bin/bash 3.2.** No `declare -A`, no `${var,,}`, no
  bash-4isms — a fresh Mac has no Homebrew bash. Every plugin exports
  `PATH="/opt/homebrew/bin:$PATH"` (sketchybar's environment does not
  guarantee it). Quote everything; device names and SSIDs contain
  spaces.
- **Daemons are single-file swiftc builds.** No SPM, no Xcode
  projects. Private APIs are declared with `@_silgen_name` and the
  framework linked explicitly in install.sh's build line. Blocking
  work (CLI spawns, AX calls) stays off the event/main thread, and AX
  calls carry a messaging timeout.
- **install.sh is idempotent and manifest-honest.** Anything it adds
  to the machine is recorded in `~/.local/state/omacosy/manifest`;
  uninstall.sh removes exactly that and nothing the user had before.
  Backups are never deleted, displaced symlinks are recorded and
  restored.
- **Signing identity is sacred.** Helpers are codesigned with a
  stable "Apple Development" identity so TCC grants survive rebuilds.
  Never re-sign ad-hoc after the identity signing (that ordering bug
  has bitten before — see install.sh section 5).

## Practical notes

- Test on stock bash: `bash -n` is the floor, `/bin/bash script.sh`
  is the truth.
- The debug story is `/tmp/omacosy-*.log` — daemons `tlog` there.
  Keep it that way; it is what bug reports run on.
- Theme packs are the easiest contribution: copy a directory under
  `themes/`, provide `colors.toml`, `sketchybar.sh`, `borders.sh`,
  `backgrounds/`. Palettes compatible with omarchy's 22-color scheme
  drop straight in.
- One change per PR, and say what you tested on (macOS version,
  displays, trackpads).
