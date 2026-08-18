# omacosy

omakase + macOS + cosy. An [omarchy](https://omarchy.org)-style setup for
macOS: tiling window management with a real Super key and Hyprland's
dwindle layout, a themed status bar written for it (bar, popups,
sliders and screen dimming in one process),
focus-follows-mouse, trackpad workspace swipes with a Mission-Control-
style workspace overview (live previews included), focused-window
border rings, and unified theme switching down to the wallpaper —
bootstrapped from this one repo.

![The omacosy desktop — themed bar over the osaka-jade wallpaper](docs/screenshots/desktop.jpg)

The whole desktop environment idles at about **155MB** of physical
footprint — what Activity Monitor calls Memory — across WM, bar, four
background daemons, the swipe daemon and Karabiner. Resident set size
reads ~325MB, but RSS counts each process's share of the same shared
system frameworks, so footprint is the honest figure. Measured on this
machine, largest first:

| | footprint | RSS |
|---|---|---|
| AeroSpace | 37MB | 76MB |
| `omacosy-overview` | 37MB | 37MB |
| Karabiner (3 services) | 25MB+ | 71MB |
| `omacosy-bar` | 27MB | 54MB |
| `omacosy-borders` | 11MB | 30MB |
| `omacosy-ffm` | 9MB | 24MB |
| aerospace-swipe | 8MB | 24MB |
| `omacosy-dwindle` | 4MB | 9MB |

It is mostly self-built: six small signed Swift binaries replace what
would otherwise be a pile of dependencies (several of which are broken
on macOS 26 — see below).

> **Posture**: built for macOS 26 (Tahoe) on one desk — a MacBook Pro
> plus one external display. It generalizes deliberately (roles instead
> of hardware names, per-display notch detection), but "works for me"
> is the honest tier. The permission setup is real work. Issues and PRs
> welcome; support promises are not made.

## Fresh Mac

```sh
git clone https://github.com/paulsp94/omacosy.git ~/.local/share/omacosy &&
cd ~/.local/share/omacosy && ./install.sh
```

The clone location matters: configs are symlinked into the repo, and
macOS privacy (TCC) blocks launchd services from reading
`~/Documents`, `~/Desktop` and `~/Downloads` — a clone there makes
the installer fall back to copying configs (still works; edits then
need an `install.sh` re-run to apply).

Idempotent — re-run after pulling changes. Installs Homebrew if
missing, runs `brew bundle`, compiles the helper binaries, generates
the AeroSpace config from your app choices, symlinks configs (backing
up anything it would replace), hides the native menu bar, applies the
default theme, and starts services.

See [Permissions](#permissions) for the grants this asks of you, what
each one buys, and what breaks without it. Karabiner-Elements also asks
you to approve its driver extension.

## Permissions

A window manager is an intrusive thing to install, so here is the whole
list — every grant, which binary asks, what it is used for, and what
you lose by refusing it. Everything here is refusable; the parts that
depend on a grant hide themselves rather than half-work.

| Grant | Who asks | What it does | Without it |
|---|---|---|---|
| **Accessibility** | AeroSpace, AerospaceSwipe, `omacosy-ffm` | Move, resize and focus other apps' windows. This is the tiling itself, and it is the broadest permission here. | Nothing tiles. Not optional in practice. |
| **Input Monitoring** | Karabiner-Elements, AerospaceSwipe | Karabiner reads keys to remap Caps Lock; AerospaceSwipe reads raw trackpad contacts, because macOS 26 stopped carrying touch data in normal events. | No Super key, no swipe gestures. |
| **Screen Recording** | `omacosy-overview` | Captures a thumbnail per window for the overview cards — including windows AeroSpace has stashed offscreen, which is why it needs the real thing and not a screenshot of the visible screen. | Cards fall back to app icons and titles. |
| **Bluetooth** | `omacosy-bar` | Reads adapter power and the paired-device list for the bluetooth pill and its menu. | The pill hides itself. |
| **Automation** | `omacosy-bar`, `theme-set` | Apple Events to **Spotify** (what is playing; play/pause/next from the media pill) and to **System Events** (sleep, lock and restart from the Apple menu; setting the wallpaper). | The media pill hides; those menu rows do nothing. |
| **Files and Folders** | `omacosy-bar` | Only if your clone lives in `~/Documents`, `~/Desktop` or `~/Downloads` — the bar reads its palette from the theme directory inside the repo, and macOS walls launchd agents off from those folders. | The bar **hangs at startup** waiting on the prompt. Clone to `~/.local/share/omacosy` and this never comes up. |

### What it does not do

- **No Location.** macOS classes the wi-fi network's name as location
  data, so the wi-fi pill shows a signal icon and no name. Asking for
  the grant does not fix it: measured on macOS 26.3, an unbundled
  binary reads `nil` from CoreWLAN even with Location authorized and
  updates running, and `ipconfig` prints `SSID : <redacted>` for the
  same reason. Shipping the bar as an `.app` might lift it; that is not
  worth a location prompt, so the bar does not ask.
- **No telemetry, no analytics, no crash reporting.** Nothing is sent
  anywhere about you or this machine.
- **One network call**, ever: `https://wttr.in/?format=j1` on a long
  timer, for the weather pill. wttr.in infers your city from the IP the
  request arrives on — no coordinates are gathered or sent, and the bar
  holds no location API. Delete the weather pill and nothing leaves the
  machine.
- **omacosy's own binaries never run as root.** `install.sh` uses no
  sudo, installs no LaunchDaemon, and every helper it builds runs as
  you, in your login session.
- **Karabiner-Elements does, and you should know that before
  installing.** It is a Homebrew dependency here, purely to turn Caps
  Lock into Super — and it ships a DriverKit system extension plus
  daemons that run as **root** (`Karabiner-VirtualHIDDevice-Daemon`,
  `Karabiner-Core-Service`). That is what the driver-extension approval
  during install is. It is the single most privileged thing this repo
  puts on your Mac, and it is third-party. Skip it if that trade is
  wrong for you; you lose the Super key and keep everything else.
- **Nothing here reads your keystrokes.** No omacosy binary opens a
  keyboard event tap — only Karabiner sees keys, which is inherent to
  remapping one. AerospaceSwipe's event tap is gesture-only and
  listen-only (`1 << NSEventTypeGesture`,
  `kCGEventTapOptionListenOnly`), so it cannot see or alter a
  keystroke. Debug logs (`/tmp/omacosy-*.log`) carry window titles,
  app names and workspace numbers — never input.

Grants are tied to a binary's code signature. With an Apple Development
identity present, `install.sh` signs every helper with a stable
identifier so rebuilds keep their grants; without one, macOS treats
each rebuild as a new app and you re-grant after every install.

## App choices

Keybindings launch apps defined in `config/apps.conf` — defaults are
Ghostty, Safari, Spotify, Slack (terminal, browser, music, messenger).
Override any of them in `config/apps.local.conf` (gitignored), then
re-run `install.sh`:

```sh
# config/apps.local.conf — your picks win over apps.conf
TERMINAL=Korren
BROWSER=Arc
```

Your personal shell config belongs in `~/.zshrc.local` — the repo's
`zshrc` wires the CLI stack and sources it.

## What's inside

| Piece | Tool | Config |
|---|---|---|
| Tiling WM | [AeroSpace](https://github.com/nikitabobko/AeroSpace) | `config/aerospace/aerospace.template.toml` |
| Super key | [Karabiner](https://karabiner-elements.pqrs.org) (Caps Lock → cmd+ctrl+alt) | `config/karabiner/` (copied, not symlinked — TCC) |
| Status bar, popups, shade | `omacosy-bar` (self-compiled launchd agent — one process draws all of it) | `helper/bar.swift` |
| Window borders + fullscreen shroud | `omacosy-borders` (self-compiled launchd agent) | `helper/borders.swift`, `config/borders.conf` |
| Focus follows mouse | `omacosy-ffm` (self-compiled launchd agent) | `helper/ffm.swift`, `config/ffm-ignore` |
| Trackpad swipes | [aerospace-swipe](https://github.com/acsandmann/aerospace-swipe) + our patch | `config/aerospace-swipe/config.json`, `patches/` |
| Workspace overview | `omacosy-overview` (self-compiled resident daemon) | `helper/overview.swift` |
| Dwindle layout | `omacosy-dwindle` (self-compiled launchd agent) | `helper/dwindle.swift` |
| Workspace / window navigation | `omacosy-ws`, `omacosy-cycle`, `omacosy-float` | `bin/` |
| Park/restore the stack | `omacosy-toggle` | `bin/omacosy-toggle` |
| System glue | `omacosy-helper` (self-compiled) | `helper/main.swift` |
| Prompt | starship | `config/starship.toml` |
| Shell | zsh | `zsh/zshrc` + your `~/.zshrc.local` |
| CLI stack | fzf, eza, zoxide, ripgrep, bat, lazygit, btop | wired in `zsh/zshrc` |

Why self-built: on macOS 26, cooperative activation broke AutoRaise
(focus-follows-mouse), CGEvent taps stopped carrying multi-touch data
(breaking aerospace-swipe upstream — fix PRed as
[#29](https://github.com/acsandmann/aerospace-swipe/pull/29)/[#30](https://github.com/acsandmann/aerospace-swipe/pull/30)),
and JankyBorders' per-window bitmaps cost hundreds of MB.
`omacosy-ffm` focuses via the same SkyLight calls AeroSpace uses;
`omacosy-borders` strokes one CAShapeLayer the WindowServer rasterizes,
driven by the window server's own event stream (SkyLight notifications
for focus, move and resize — no polling, the ring glides with drags);
`omacosy-helper` covers wallpaper (System Events scripting half-broke
in macOS 14+), CoreAudio output switching, IOBluetooth control, cursor
position, and per-display notch detection. `omacosy-overview` and
`omacosy-dwindle` exist because neither a workspace overview nor a
dwindle layout can be had any other way — Mission Control can't see
virtual workspaces, and bsp is AeroSpace's most-requested missing
layout. `omacosy-bar` is the status bar itself: one process holding the window
model in memory and reading its own publishers — SkyLight for window
churn, IOBluetooth for connects, SCDynamicStore for the network, IOPS
for battery, CoreAudio for volume, DisplayServices for brightness,
Spotify's own broadcast for the track — so it polls for nothing macOS
announces. Its only timers are the weather fetch and the clock. A
workspace switch repaints in about 2 ms because it asks no one
anything; the shell bar it replaced took 165 ms to answer the same
event.

## The bar

One process draws all of it: bar, popups and sliders are surfaces of
`helper/bar.swift`. Transparent bar, everything a flat radius-4 pill.
A popup stays open while the pointer is anywhere in the bar OR the
popup, and closes when it is in neither. The bar hides itself when a
window takes the whole display — and comes back if you put the pointer
on the very top edge, the way the menu bar does, so brightness and
volume stay reachable mid-film without leaving fullscreen. While
revealed it climbs above the fullscreen window and drops back down
behind everything when the pointer leaves.

- **Apple menu** — About, System Settings, Lock, Sleep, Restart, Shut
  Down, Next Theme (the menu the hidden native bar took away).
- **Workspaces** — one segmented capsule per monitor showing only that
  monitor's workspaces; accent pill on the focused one; click to jump.
- **Media** — prev / play-pause / next + track title (Spotify); centered
  on flat displays, left cluster on notched ones (real per-display
  notch detection via `NSScreen.safeAreaInsets`), hidden
  when Spotify isn't running.
- **Bluetooth** — device menu (click to connect/disconnect), power
  toggle. **WiFi** — ip and router, signal with a verdict, link rate and
  security generation, channel with its band and width. No network name:
  macOS classes the SSID as location data and will not hand it to an
  unbundled binary at all (see [Permissions](#permissions)).
  **Weather** — wttr.in, cached details popup.
  **Volume** — scroll adjusts, click opens slider + output-device menu,
  right-click mutes. **Brightness** — scroll adjusts, click opens a slider
  (DisplayServices, no deps). Scrolling past 0 keeps going: a **shade**
  dims the display below its hardware minimum by scaling gamma, so there
  is no overlay window in the z-order and screenshots come out normal.
  It reaches external displays too, which have no backlight API. Gamma
  is reset when the setting process exits, so a crash or an uninstall
  restores the screen by itself.
  **Battery** / **Clock** (calendar popup) /
  **Activity** (floating btop) / **Floats** — appears only while the
  workspace holds floating windows; click surfaces the next one.

## Keybindings — Super = hold Caps Lock

Karabiner remaps Caps Lock to `cmd+ctrl+alt` (a combo macOS never
uses), so omarchy's scheme works letter-for-letter without breaking
typing or app shortcuts. Caps Lock tapped alone is Escape.

| Chord | Action |
|---|---|
| **Navigation** | |
| `Super+1..9` | switch to this display's workspace N |
| `Super+tab` / `Super+shift+tab` | next / previous workspace, within this display's set |
| `Super+b` | back and forth between the last two workspaces |
| `Alt+tab` / `Alt+shift+tab` | cycle windows **on this workspace**, floats included |
| `Ctrl+Alt+tab` | cycle focus between displays |
| `Super+arrows` | focus the window in that direction |
| `Super+s` | surface the next floating window (and bring the cursor) |
| **Moving windows** | |
| `Super+shift+arrows` | move the window in that direction |
| `Super+shift+1..9` | move the window to workspace N and follow it |
| `Super+shift+o` | throw the window to the same slot on the other display |
| `Super+shift+space` | throw the WHOLE workspace to the other display |
| **Layout** | |
| `Super+w` | close window |
| `Super+t` | toggle floating |
| `Super+j` | toggle split direction |
| `Super+-` / `Super+=` | resize |
| `Super+f` | fullscreen — on notched displays the camera strip is blacked out so it reads as true fullscreen, while the window stays in its workspace (swipes still reach it) |
| `Super+n` | native macOS fullscreen (a separate Space — outside the workspace model, avoid unless an app needs it) |
| `Super+r` | resize mode (`h/j/k/l`, `-`/`=`, `esc`) |
| `Super+shift+;` | service mode (`esc` reload, `r` flatten, `⌫` close others) |
| **Apps and system** | |
| `Super+enter` / `Super+shift+enter` | terminal / browser |
| `Super+space` | launcher (Raycast) |
| `Super+shift+f` / `+m` / `+g` | files / music / messenger (set in `apps.conf`) |
| `Super+shift+t` | next theme |
| `Super+shift+l` | lock the screen |

Screenshots, clipboard and app switching stay macOS's own (`Cmd+Shift+3/4/5`,
`Cmd+C/V`, `Cmd+Tab`) — `Alt+Tab` above is the *window*-scoped switcher
macOS lacks.

**On the modifier space.** omarchy layers `Super+Ctrl` and `Super+Alt` on
top of `Super`. This setup cannot: Super IS `cmd+ctrl+alt`, so those
modifiers are already spent and **Shift is the only layer left** — two
against omarchy's four. Bindings that would collide are re-homed by
mnemonic (lock is `Super+Shift+L`, not `Super+Ctrl+L`), and the overflow
lives in binding modes instead.

Each display owns an independent set of NINE workspaces, omarchy
style: main holds 1–9, secondary holds 11–19 — same last digit = same
slot, and the bar and overview render only the slot digit. `Super+N`
switches the focused monitor's slot N (via `omacosy-ws`);
`Super+Shift+N` moves the window to that slot; `Super+Shift+O`
throws the window to the same slot on the other monitor. On a single
display the secondary set falls back to main and sits empty. Windows
open on the workspace you're on; nothing is auto-assigned by app.

## Themes

`theme-set <name>` switches everything at once — bar, borders,
wallpaper on every display, and any terminal that follows omarchy's
`~/.config/omarchy/current/theme` convention (the author's does).
`Super+Shift+T` cycles.

Themes: `tokyo-night`, `catppuccin`, `gruvbox`, `osaka-jade`. Each
`themes/<name>/` holds `colors.toml` (omarchy's 22-color palette),
`sketchybar.sh` / `borders.sh` (bar and ring colors — the file keeps
its omarchy name and format; the ring uses the
theme accent, omarchy's own convention), and `backgrounds/` (wallpapers
from omarchy's MIT-licensed theme packs). Copy a directory to add one.

## Tiling: dwindle

![Two windows tiled side by side, accent border ring on the focused one](docs/screenshots/tiling.jpg)

AeroSpace natively inserts new windows as equal siblings (three
windows = three columns). `omacosy-dwindle` grafts Hyprland's dwindle
on top: each new tiled window splits the focused window's own slot,
alternating direction — the omarchy spiral, automatic. It touches a
window exactly once (at birth), stands down for floats and while the
overview is open, and `touch ~/.config/omacosy/no-dwindle` disables it
live. Manual control (Super+J flips, resize, float) works unchanged.

Floats get a rescue path, because macOS will not keep them on top:
z-order is per *app*, not per window, so a float sinks behind whichever
app you focus next, and pinning it would mean rewriting the window's
level through a private call with SIP off. Instead the bar grows a pill
whenever the focused workspace is holding floats, and **Super+S** — or
a click on that pill — surfaces the next one and brings the cursor with
it, so a float is never lost behind a tile and never retrieved by
aiming at something you cannot see.

## Focus follows mouse & swipes

`omacosy-ffm`: hover focuses (no raise over floating windows — floats
stay in front), event-driven off mouse *movement* so a parked cursor
never steals focus from a launching window, never during drags,
per-app opt-out in `config/ffm-ignore` (omarchy's JetBrains-style
exception). 4-finger swipes left/right switch workspaces on **the
display under the cursor** (native-Spaces semantics), wrap-around, any
trackpad. The system's own 4-finger gestures are disabled by
`macos-defaults.sh` so Mission Control never fights the daemon
(`uninstall.sh` restores them).

## Workspace overview

![Workspace overview — live preview cards over the zoomed-out wallpaper, chips for empty workspaces](docs/screenshots/overview.jpg)

4-finger **swipe up**: the wallpaper breathes in behind a dim wash and
every non-empty workspace OF THE CURSOR'S MONITOR gets a card (per-
display Mission Control semantics) — live window previews
(ScreenCaptureKit, composed into the tile layout), app icons, the
focused workspace accent-ringed. Click a card or press its digit to
jump; empty workspaces show as small chips (digits work for them too —
straight to a clean screen). **Swipe down**, Esc, or a backdrop click
dismisses. Resident daemon, so it opens instantly.

**Drag a card** to reorganize: the row makes room as you move, and the
drop slides everything between the old and new position over by one.
AeroSpace workspaces cannot be renamed or resequenced — the name IS the
position — so what actually moves is their windows, which means a
split layout inside a moved workspace comes back as a flat row.
Dropping a card on an empty chip moves that workspace there instead.

## Parking the setup

`omacosy-toggle off` returns to a vanilla Mac in one command (AeroSpace
stops managing, all daemons and the bar stop) without uninstalling;
`omacosy-toggle on` brings everything back. No argument flips.

## Back to a normal Mac

```sh
./uninstall.sh
```

Manifest-driven: `install.sh` records what THIS machine actually
gained (Homebrew packages that weren't already present, cloned repos,
every `defaults` key's prior value), and `uninstall.sh` removes and
restores exactly that — tools and settings you had before omacosy are
never touched. Pre-manifest installs fall back to a conservative
teardown that leaves all Homebrew packages in place.

## License & credits

MIT (see `LICENSE`). Standing on: [omarchy](https://omarchy.org)
(the whole idea, plus MIT-licensed theme palettes and wallpapers),
[AeroSpace](https://github.com/nikitabobko/AeroSpace),
[Karabiner-Elements](https://karabiner-elements.pqrs.org),
[aerospace-swipe](https://github.com/acsandmann/aerospace-swipe) (MIT;
patched here for macOS 26, fixes offered upstream).
