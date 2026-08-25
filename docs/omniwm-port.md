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

## To port

1. **Full keybinding parity.** Map the rest of the omarchy scheme into
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
