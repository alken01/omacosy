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

## Trial findings (2026-08-26, first live day)

- **Switch flow works** after two script fixes: gates read /dev/tty,
  and OmniWM is re-poked after AeroSpace dies (it refuses to start
  alongside another WM and its conflict dialog never re-checks).
- **Dwindle ignores outer gaps** — DwindleSettings carries only
  innerGap; [gaps.outer] is Niri-only. Verified empirically (top=42
  and bottom=60 both no-ops after forced relayout; innerGap
  live-reloads fine). So the bar gets no reserved strip and lives in
  hover-reveal mode. Gap values stay in settings.toml for the day
  upstream honors them. UPSTREAM ISSUE CANDIDATE.
- **Gestures need the grant before launch** — the multitouch reader
  initializes at startup, so Input Monitoring granted mid-session
  needs an OmniWM restart to take. Cost us an hour of GUI archaeology;
  the settings file had been right all along.
- **Swipe feel**: one-switch-per-swipe by design, less smooth than
  aerospace-swipe's feel. Trial con.
- **No vertical swipe**: workspaceSwipeAxis is a single axis, so
  swipe-up-for-overview is structurally gone; Super+O substitutes.
  Possible hybrid later: aerospace-swipe kept only for the vertical
  gesture, firing OmniWM's overview via IPC.
- **Phantom-bar workaround FAILED** — their workspace bar's
  reserveLayoutSpace does reserve under dwindle (measured, windows
  y=32->78), but the bar cannot be made invisible (app icons and
  workspace chips render regardless of backgroundOpacity/showLabels)
  and the reservation did not survive an OmniWM restart. Removed;
  omacosy-bar stays hover-reveal until upstream honors [gaps.outer]
  for dwindle. That upstream issue is now the ONLY path to a
  permanently visible bar.
- **Overview verdict (user)**: OmniWM's is search-and-scroll — the
  search is liked, but the old omacosy overview LAYOUT (wallpaper-zoom
  workspace cards) is preferred over their concept. Open decision:
  port our overview to an omniwmctl data source, or upstream-feature
  request a card layout, or live with theirs.
- **Menu-bar apps are awkward under omacosy**: OmniWM is menu-bar-only
  and our bar covers/hides the native bar; even _HIHideMenuBar=false +
  Dock restart did not bring it back while our bar ran. Reaching their
  GUI means parking omacosy-bar. Their GUI toggle for swipes did not
  actually persist to settings.toml in our attempt — TOML remained the
  authority.

## Capability audit (2026-08-26, four docs)

Full reference: omniwm-capabilities-{config,features,ipc,layout}.md in
this directory. Version-critical reconciliation:

- Installed 0.6.2; **0.6.3 released 2026-08-25** and audited at its
  commit (33b748b). Two findings of ours were 0.6.2-only:
  - "dwindle ignores outer gaps" — FIXED in 0.6.3: outer gaps are
    struts on the workingFrame for BOTH engines (WMController
    .layoutFrames). The bar gets its strip by upgrading. No upstream
    issue needed.
  - fullscreen-uses-outer-gaps and other keys exist only from 0.6.3.
- **0.6.3 UPGRADE TRAP**: its decoder is strict (every table complete,
  every hotkey catalog id present exactly once) and cold start
  silently moves a rejected file to settings.toml.corrupt and writes
  defaults. Our file is sparse. REQUIRED ORDER:
    1. brew upgrade omniwm (restarts the WM; expect our config to be
       rejected -> defaults, exec chords still work via Karabiner)
    2. let 0.6.3 write its full canonical defaults file
    3. patch our keys INTO that file (script the patch; comments are
       lost on GUI rewrites anyway)
    4. verify hotkeys + [gaps.outer] top -> bar strip
- Overview: theirs is hardcoded layout (zoom + 4 colors only); cannot
  be themed toward our wallpaper-card concept. Options: fork (GPL,
  cleanly layered) or external overview on IPC (feasible: queries +
  focus/switch commands exist; missing thumbnails-by-IPC means own
  ScreenCaptureKit, which omacosy-overview already does).
- IPC: bar + gesture daemon fully served; no exec, no config access,
  no close-window (Karabiner Cmd+W stays). Docs' alias section is
  unimplemented — worth reporting upstream.
- Undock: workspaces keep numbers and re-resolve home on redock
  natively; our fold-into-1-9 has no equivalent (may not be needed).
- Undocumented gem: system-wide window corner radius via
  NSConvolutionOverride defaults.

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
