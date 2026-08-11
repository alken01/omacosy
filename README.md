# omacosy

omakase + macOS + cosy. An [omarchy](https://omarchy.org)-style setup for
macOS: tiling window management, a fully interactive themed status bar,
trackpad workspace swipes, active-window borders, unified theme switching
down to the wallpaper — all bootstrapped from this one repo.

## Fresh Mac

```sh
git clone git@github.com:paulsp94/omacosy.git ~/Documents/paul/repos/omacosy
~/Documents/paul/repos/omacosy/install.sh
```

The installer is idempotent — re-run it after pulling changes. It installs
Homebrew if missing, runs `brew bundle`, compiles the helper binary and
aerospace-swipe, symlinks configs (backing up anything it would replace),
hides the native menu bar, applies the default theme, and starts services.

One-time permission grants on a new machine (System Settings →
Privacy & Security):

1. **Accessibility**: AeroSpace, AerospaceSwipe (each prompts), and
   `omacosy-ffm` (add `~/.local/bin/omacosy-ffm` manually). Binaries are
   codesigned with your Apple Development identity when present, so
   rebuilds keep their grants.
2. **Input Monitoring**: Karabiner (prompts) and AerospaceSwipe
   (add manually: `~/.local/share/aerospace-swipe/AerospaceSwipe.app`).
3. **Bluetooth**: sketchybar
   (add manually: `/opt/homebrew/opt/sketchybar/bin/sketchybar`),
   for the bar's bluetooth menu.
4. Karabiner-Elements: approve its driver extension when prompted.
5. Korren isn't in the Brewfile — build it from its repo:
   `./packaging/macos/build-app.sh --install`.

## What's inside

| Piece | Tool | Config |
|---|---|---|
| Tiling WM | [AeroSpace](https://github.com/nikitabobko/AeroSpace) | `config/aerospace/aerospace.toml` |
| Super key | [Karabiner](https://karabiner-elements.pqrs.org) (Caps Lock → cmd+ctrl+alt) | `config/karabiner/` (copied, not symlinked — TCC) |
| Status bar | [sketchybar](https://github.com/FelixKratz/SketchyBar) | `config/sketchybar/` |
| Window borders | [JankyBorders](https://github.com/FelixKratz/JankyBorders) | `config/borders/bordersrc` |
| Trackpad swipes | [aerospace-swipe](https://github.com/acsandmann/aerospace-swipe) + our patch | `config/aerospace-swipe/config.json`, `patches/` |
| System glue | `omacosy-helper` (self-compiled, 64KB) | `helper/main.swift` |
| Focus follows mouse | `omacosy-ffm` (self-compiled launchd agent) | `helper/ffm.swift` |
| Terminal | [Korren](https://github.com/paulsp94/korren) (built from source) | follows the theme switcher |
| Prompt | starship | `config/starship.toml` |
| Shell | zsh + oh-my-zsh | `zsh/zshrc` |
| CLI stack | fzf, eza, zoxide, ripgrep, bat, lazygit, btop | wired in `zsh/zshrc` |

`omacosy-ffm` provides focus-follows-mouse (AutoRaise is broken on
macOS 26 — cooperative activation; and AX focus attributes silently
no-op for Chromium apps like Arc, so it focuses via the same private
SkyLight calls AeroSpace uses). `omacosy-helper` replaces four
would-be dependencies (cliclick, desktoppr,
switchaudio-osx, blueutil): cursor position for popup auto-close,
NSWorkspace wallpaper setting, CoreAudio output switching, IOBluetooth
control. `install.sh` builds it with the swiftc that ships alongside
Homebrew's required CLT.

## The bar

Transparent bar, everything a flat radius-4 pill. Every popup closes
itself when the cursor leaves it.

- ** menu** — About, System Settings, Lock, Sleep, Restart, Shut Down,
  Next Theme, Reload Bar (the menu the hidden native bar took away).
- **Workspaces** — one segmented capsule per monitor showing only that
  monitor's workspaces; accent pill on the focused one; click to jump.
- **Spotify** (center) — prev / play-pause / next + live track title;
  hidden when Spotify isn't running.
- **Bluetooth** — state + connected count; menu lists devices
  (click to connect/disconnect), power toggle, settings.
- **WiFi** — state icon (macOS 26 hides SSIDs from CLI tools); menu shows
  connection + IP, power toggle, settings.
- **Weather** — wttr.in condition + temp; click for a cached details popup.
- **Volume** — scroll adjusts, click opens slider + output-device menu,
  right-click mutes.
- **Battery** — click opens Battery settings.
- **Clock** — click drops a month calendar.

## Trackpad swipes

4-finger swipes switch workspaces on **the display under the cursor**
(native-Spaces semantics), wrap-around, any trackpad. Ships with a patch
for macOS 26 where the upstream event-tap detection is broken (gesture
events carry at most one touch) — replaced with raw MultitouchSupport
frames on every device. Upstreamed as
[acsandmann/aerospace-swipe#29](https://github.com/acsandmann/aerospace-swipe/pull/29)
and [#30](https://github.com/acsandmann/aerospace-swipe/pull/30); once
merged, the patch step disappears.

## Themes

`theme-set <name>` switches everything at once — Korren, sketchybar,
borders, and the wallpaper on every display. It swaps the
`~/.config/omarchy/current/theme` symlink (omarchy's own convention);
Korren watches that directory and repaints live. `Super+Shift+T` cycles.

Themes: `tokyo-night`, `catppuccin`, `gruvbox`, `osaka-jade`. Each
`themes/<name>/` holds:

- `colors.toml` — the 22-variable omarchy palette (read by Korren; names
  matching a Korren built-in use its hand-tuned version instead)
- `sketchybar.sh` / `borders.sh` — bar and border colors
- `backgrounds/` — wallpaper (from omarchy's theme packs)

To add a theme, copy a directory and adjust.

## Keybindings — Super = hold Caps Lock

Karabiner remaps Caps Lock to `cmd+ctrl+alt` (a combo macOS never uses),
so the omarchy scheme works letter-for-letter without breaking typing or
app shortcuts. Caps Lock tapped alone is Escape.

| Chord | Action |
|---|---|
| `Super+enter` | new Korren window |
| `Super+shift+enter` | browser (Arc) |
| `Super+space` | launcher (Raycast) |
| `Super+w` | close window |
| `Super+arrows` | focus window |
| `Super+shift+arrows` | move window |
| `Super+1..9` | switch workspace |
| `Super+shift+1..9` | move window to workspace |
| `Super+tab` | previous workspace |
| `Super+shift+tab` | throw workspace to other monitor |
| `Super+f` | fullscreen (tiling-friendly) |
| `Super+n` | native macOS fullscreen (claims the notch strip) |
| `Super+t` | toggle floating |
| `Super+j` | toggle split direction |
| `Super+-` / `Super+=` | resize |
| `Super+shift+f/m/s` | Finder / Spotify / Slack |
| `Super+shift+t` | next theme |
| `Super+r` | resize mode (`h/j/k/l`, `-`/`=`, `esc`) |
| `Super+shift+;` | service mode (`esc` reload, `r` flatten, `⌫` close others) |

Workspaces 1–6 pin to the **main** display, 7–9 to the **secondary**
(roles, not hardware — a single display gets everything; messengers
auto-land on 8, music on 9 via window rules).

## Back to a normal Mac

```sh
./uninstall.sh
```

Stops AeroSpace/sketchybar/borders/Karabiner/aerospace-swipe, restores
the native menu bar and any backed-up configs, removes the helper.
Homebrew packages stay installed (removal command printed at the end).
