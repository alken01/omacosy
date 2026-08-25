# OmniWM port — task list (branch: omniwm)

The rule of the branch: `main` stays the AeroSpace world; nothing here
switches the live WM except `omacosy-wm-switch omniwm`, which is
grant-first, snapshot-backed and auto-reverting.

## Done

- [x] Brewfile + tap trust, settings.toml skeleton, config symlink
- [x] `omacosy-wm-switch` — snapshot, grant-first handover, 90s
      dead-man revert (install.sh never switches on its own)
- [x] Core hotkeys: workspaces 1-9, move+follow, back-and-forth,
      focus arrows (binding format verified against OmniWM's parser)

## Done (agents, 2026-08-25)

- [x] Full keybinding parity — 35 bindings, every id verified against
      ActionCatalog.swift; gaps documented in settings.toml comments
      (OmniWM has NO close-window command; no "other monitor" throw,
      only directional). [[workspaces]] block added: 1-9 main, 14-17
      secondary (their built-in default is only 7 workspaces!), plus
      appRules pinning Signal/WhatsApp/Discord/Spotify to 14-17.
- [x] Bar workspace feed — WM detected per use; omniwmctl query
      workspaces/windows/displays + a persistent `watch
      active-workspace --exec /bin/cat` stream for instant focus;
      click-to-jump via `workspace focus-name`. Aerospace path
      untouched.
- [x] Cheatsheet — parses [[hotkeys]] from settings.toml under OmniWM,
      comment blocks become group headings, Control+Option+Command
      renders as Super.
- [x] WM-aware plumbing — omacosy-ws routes through omniwmctl
      (per-monitor natively, no twin math); collapse/cycle/float/
      focus-guard/spawn stand down cleanly; toggle records and
      restarts the right WM; uninstall tears OmniWM down.

## To verify on the next guarded switch

1. **Settings load.** OmniWM's TOML decoder is strict and silently
   replaces an unparseable file with defaults — the likeliest cause of
   trial #1's stranding. Watch whether the hotkeys survive first load.
2. **IPC socket** must be enabled once from OmniWM's status-bar menu
   before omniwmctl works (socket:
   ~/Library/Caches/com.barut.OmniWM/ipc.sock).
3. Bar under OmniWM (payload shapes taken from source, never probed
   live), borders, spawn behaviour, monitor routing vs 11-19.

## Remaining

1. **Verification pass.** Map the rest of the omarchy scheme into
   `[[hotkeys]]`: resize, fullscreen, float toggle, split toggle,
   window throws between monitors, workspace throw. Needs the complete
   hotkey id list from `Sources/OmniWM/Core/Input/DefaultHotkeyBindings.swift`.
   Also `[[appRules]]` seeding: messengers/media to the secondary-set
   workspaces so the "apps per screen" survive restarts.
2. **Bar workspace feed.** `helper/bar.swift` shells `aerospace` for
   workspaces and focus. Add an OmniWM source (omniwmctl query or its
   IPC subscriptions) selected by which WM is running; pills and
   click-to-jump must work in both worlds.
3. **Cheatsheet.** `Super+K` renders bindings parsed from
   aerospace.toml; teach it to read `[[hotkeys]]` from settings.toml
   when OmniWM is active.
4. **WM-aware plumbing.** `omacosy-toggle`, `uninstall.sh`, the
   focus-guard, `omacosy-ws`/`-collapse`/`-cycle`/`-float`/`-spawn`:
   each either gains an OmniWM path, stands down under OmniWM, or is
   retired by a native OmniWM feature (ffm, swipes are native; the
   overview may be next).
5. **Verification pass.** Borders under OmniWM (SkyLight events should
   flow regardless), spawn-flicker behaviour vs our serialized spawn,
   multi-monitor workspace model mapping (11-19 convention vs OmniWM's
   monitor routing), Ghostty titlebar interplay.

## Open questions

- OmniWM's workspace model vs our per-display 1-9/11-19 convention:
  adopt theirs or emulate ours via named workspaces?
- Retire omacosy-overview for OmniWM's, or keep ours for the themed
  look? (Theirs has search and drag; ours matches the wallpaper zoom.)
