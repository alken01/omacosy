# omacosy

omakase + macOS + cosy. An [omarchy](https://omarchy.org)-style setup for
macOS: tiling window management with a real Super key, a fully
interactive themed status bar, focus-follows-mouse, trackpad workspace
swipes, focused-window border rings, and unified theme switching down to
the wallpaper — bootstrapped from this one repo.

The whole desktop environment idles around **280MB** and is mostly
self-built: four small signed Swift binaries replace what would
otherwise be seven dependencies (several of which are broken on
macOS 26 — see below).

> **Posture**: built for macOS 26 (Tahoe) on one desk — a MacBook Pro
> plus one external display. It generalizes deliberately (roles instead
> of hardware names, per-display notch detection), but "works for me"
> is the honest tier. The permission setup is real work. Issues and PRs
> welcome; support promises are not made.

## Fresh Mac

```sh
git clone https://github.com/paulsp94/omacosy.git
cd omacosy && ./install.sh
```

Idempotent — re-run after pulling changes. Installs Homebrew if
missing, runs `brew bundle`, compiles the helper binaries, generates
the AeroSpace config from your app choices, symlinks configs (backing
up anything it would replace), hides the native menu bar, applies the
default theme, and starts services.

One-time permission grants (System Settings → Privacy & Security):

1. **Accessibility**: AeroSpace, AerospaceSwipe (each prompts), and
   `omacosy-ffm` (add `~/.local/bin/omacosy-ffm` manually). With an
   Apple Development signing identity present, binaries are codesigned
   so rebuilds keep their grants; without one, re-grant after rebuilds.
2. **Input Monitoring**: Karabiner (prompts) and AerospaceSwipe
   (add manually: `~/.local/share/aerospace-swipe/AerospaceSwipe.app`).
3. **Bluetooth**: sketchybar
   (add manually: `/opt/homebrew/opt/sketchybar/bin/sketchybar`),
   for the bar's bluetooth menu.
4. Karabiner-Elements: approve its driver extension when prompted.

## App choices

Keybindings launch apps defined in `config/apps.conf` (terminal,
browser, music, messenger). Override any of them in
`config/apps.local.conf` (gitignored), then re-run `install.sh`:

```sh
# config/apps.local.conf
TERMINAL=kitty
BROWSER=Arc
```

Your personal shell config belongs in `~/.zshrc.local` — the repo's
`zshrc` wires the CLI stack and sources it.

## What's inside

| Piece | Tool | Config |
|---|---|---|
| Tiling WM | [AeroSpace](https://github.com/nikitabobko/AeroSpace) | `config/aerospace/aerospace.template.toml` |
| Super key | [Karabiner](https://karabiner-elements.pqrs.org) (Caps Lock → cmd+ctrl+alt) | `config/karabiner/` (copied, not symlinked — TCC) |
| Status bar | [sketchybar](https://github.com/FelixKratz/SketchyBar) | `config/sketchybar/` |
| Window borders | `omacosy-borders` (self-compiled launchd agent) | `helper/borders.swift`, `config/borders.conf` |
| Focus follows mouse | `omacosy-ffm` (self-compiled launchd agent) | `helper/ffm.swift`, `config/ffm-ignore` |
| Trackpad swipes | [aerospace-swipe](https://github.com/acsandmann/aerospace-swipe) + our patch | `config/aerospace-swipe/config.json`, `patches/` |
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
`omacosy-borders` strokes one CAShapeLayer the WindowServer rasterizes;
`omacosy-helper` covers wallpaper (System Events scripting half-broke
in macOS 14+), CoreAudio output switching, IOBluetooth control, cursor
position, and per-display notch detection.

## The bar

Transparent bar, everything a flat radius-4 pill, one `GAP` constant
for spacing. Every popup closes when the cursor leaves it.

- ** menu** — About, System Settings, Lock, Sleep, Restart, Shut Down,
  Next Theme, Reload Bar (the menu the hidden native bar took away).
- **Workspaces** — one segmented capsule per monitor showing only that
  monitor's workspaces; accent pill on the focused one; click to jump.
- **Media** — prev / play-pause / next + track title (Spotify); centered
  on flat displays, left cluster on notched ones (real per-display
  notch detection — sketchybar's `q` position is unreliable), hidden
  when Spotify isn't running.
- **Bluetooth** — device menu (click to connect/disconnect), power
  toggle. **WiFi** — status, IP, power toggle (macOS 26 hides SSIDs
  from CLI tools). **Weather** — wttr.in, cached details popup.
  **Volume** — scroll adjusts, click opens slider + output-device menu,
  right-click mutes. **Battery** / **Clock** (calendar popup) /
  **Activity** (floating btop).

## Keybindings — Super = hold Caps Lock

Karabiner remaps Caps Lock to `cmd+ctrl+alt` (a combo macOS never
uses), so omarchy's scheme works letter-for-letter without breaking
typing or app shortcuts. Caps Lock tapped alone is Escape.

| Chord | Action |
|---|---|
| `Super+enter` | new terminal window |
| `Super+shift+enter` | browser |
| `Super+space` | launcher (Raycast) |
| `Super+w` | close window |
| `Super+arrows` | focus window |
| `Super+shift+arrows` | move window |
| `Super+1..9` | switch workspace |
| `Super+shift+1..9` | move window to workspace (and follow) |
| `Super+s` / `Super+shift+s` | scratchpad workspace (toggle / send window) |
| `Super+tab` | previous workspace |
| `Super+shift+tab` | throw workspace to other monitor |
| `Super+f` | fullscreen (tiling-friendly) |
| `Super+n` | native macOS fullscreen (claims the notch strip) |
| `Super+t` | toggle floating |
| `Super+j` | toggle split direction |
| `Super+-` / `Super+=` | resize |
| `Super+shift+f/m/g` | files / music / messenger |
| `Super+shift+b` | btop (floating) |
| `Super+shift+t` | next theme |
| `Super+l` | lock screen |
| `Super+esc` |  system menu |
| `Super+r` | resize mode (`h/j/k/l`, `-`/`=`, `esc`) |
| `Super+shift+;` | service mode (`esc` reload, `r` flatten, `⌫` close others) |

Workspaces 1–6 pin to the **main** display, 7–9 to the **secondary**
(roles, not hardware — a single display gets everything; messengers
auto-land on 8, music on 9 via window rules).

## Themes

`theme-set <name>` switches everything at once — bar, borders,
wallpaper on every display, and any terminal that follows omarchy's
`~/.config/omarchy/current/theme` convention (the author's does).
`Super+Shift+T` cycles.

Themes: `tokyo-night`, `catppuccin`, `gruvbox`, `osaka-jade`. Each
`themes/<name>/` holds `colors.toml` (omarchy's 22-color palette),
`sketchybar.sh` / `borders.sh` (bar and ring colors — the ring uses the
theme accent, omarchy's own convention), and `backgrounds/` (wallpapers
from omarchy's MIT-licensed theme packs). Copy a directory to add one.

## Focus follows mouse & swipes

`omacosy-ffm`: hover focuses (no raise — nothing overlaps in tiling),
~200ms feel, never during drags, per-app opt-out in `config/ffm-ignore`
(omarchy's JetBrains-style exception). 4-finger swipes switch
workspaces on **the display under the cursor** (native-Spaces
semantics), wrap-around, any trackpad.

## Back to a normal Mac

```sh
./uninstall.sh
```

Stops everything, restores the native menu bar and any backed-up
configs, removes the omacosy agents and binaries. Homebrew packages
stay installed (removal command printed at the end).

## License & credits

MIT (see `LICENSE`). Standing on: [omarchy](https://omarchy.org)
(the whole idea, plus MIT-licensed theme palettes and wallpapers),
[AeroSpace](https://github.com/nikitabobko/AeroSpace),
[sketchybar](https://github.com/FelixKratz/SketchyBar),
[Karabiner-Elements](https://karabiner-elements.pqrs.org),
[aerospace-swipe](https://github.com/acsandmann/aerospace-swipe) (MIT;
patched here for macOS 26, fixes offered upstream).
